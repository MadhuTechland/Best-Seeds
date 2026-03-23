import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'tracking_database.dart';
import 'tracking_work_manager.dart';

// --- Constants (duplicated here because this file must be self-contained
//     for the background isolate; it cannot import Flutter-widget-dependent files) ---
// const String _baseUrl =
//     'http://192.168.0.104:8000/api/';
// const String _baseUrl =
//     'http://192.168.29.111:8000/api/';
const String _baseUrl =
    'https://bestseed.in/api/';
const String _locationUpdateEndpoint = 'driver/location/update';
const String _trackingAlertEndpoint = 'driver/tracking-alert';
const String _googleApiKey = 'AIzaSyDLVwCSkXWOjo49WNNwx7o0DSwomoFvbP0';
const String _tokenKey = 'driver_token';
const String _serviceRunningKey = 'bg_location_service_running';

// Notification channel constants — silent foreground service notification
const String _notificationChannelId = 'bestseeds_location_channel';
const String _notificationChannelName = 'Location Tracking';
const int _notificationId = 888;

// Alert notification channel — loud custom sound for GPS/internet errors
// Using v2 channel ID because Android caches channel settings; changing the ID
// forces Android to create a fresh channel with the new sound + volume settings.
const String _alertChannelId = 'bestseeds_alert_v4';
const String _alertChannelName = 'Tracking Alerts';
const int _alertNotificationId = 889;

// Watchdog constants
const Duration _watchdogInterval = Duration(minutes: 3);
const Duration _streamTimeout = Duration(minutes: 5);
const Duration _fallbackPollInterval = Duration(minutes: 2);
const Duration _connectivityCheckInterval = Duration(seconds: 30);
const Duration _maxStalePositionAge = Duration(minutes: 10);
const Duration _dbCleanupInterval = Duration(hours: 1);

class BackgroundLocationService {
  static final FlutterBackgroundService _service = FlutterBackgroundService();

  /// Initialize the background service. Call once at app startup (in main()).
  static Future<void> initialize() async {
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    // Channel 1: Silent foreground service notification
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _notificationChannelId,
      _notificationChannelName,
      description: 'Shows notification while tracking delivery location',
      importance: Importance.defaultImportance,
      showBadge: true,
      enableVibration: false,
      playSound: false,
    );

    // Channel 2: Loud alert notification for GPS/internet errors
    // Uses default notification sound with FLAG_INSISTENT to loop for 15 seconds.
    const AndroidNotificationChannel alertChannel = AndroidNotificationChannel(
      _alertChannelId,
      _alertChannelName,
      description: 'Alerts when GPS or internet is off during delivery',
      importance: Importance.max,
      showBadge: true,
      enableVibration: true,
      playSound: true,
    );

    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(channel);
    await androidPlugin?.createNotificationChannel(alertChannel);

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        autoStartOnBoot: true,
        isForegroundMode: true,
        foregroundServiceNotificationId: _notificationId,
        initialNotificationTitle: 'Bestseed',
        initialNotificationContent: 'Tracking your delivery journey...',
        notificationChannelId: _notificationChannelId,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  /// Start the background location service + WorkManager guardian.
  static Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceRunningKey, true);

    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
    }

    // Register WorkManager guardian — OS-guaranteed periodic task
    // that will restart the foreground service if OEM kills it.
    await registerGuardianTask();
  }

  /// Stop the background location service + cancel WorkManager guardian.
  static Future<void> stop() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceRunningKey, false);

    final isRunning = await _service.isRunning();
    if (isRunning) {
      _service.invoke('stop');
    }

    // Cancel the guardian since journey is over
    await cancelGuardianTask();

    // Clear the SQLite queue
    await TrackingDatabase.clearAll();
  }

  /// Check if the service is currently running.
  static Future<bool> isRunning() async {
    return await _service.isRunning();
  }

  /// Check if the service SHOULD be running (flag was set but service died).
  /// Call this on app startup to auto-restart after app kill/crash.
  static Future<bool> shouldBeRunning() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(_serviceRunningKey) ?? false;
  }

  /// Restart the service if it should be running but was killed.
  /// Call this from splash screen or driver home screen on app startup.
  static Future<void> restartIfNeeded() async {
    final shouldRun = await shouldBeRunning();
    final running = await isRunning();
    if (shouldRun && !running) {
      print('BackgroundLocationService: Service was killed, restarting...');
      await _service.startService();
      // Verify it actually started
      await Future.delayed(const Duration(seconds: 2));
      final nowRunning = await isRunning();
      if (!nowRunning) {
        print('BackgroundLocationService: Restart failed, retrying...');
        await _service.startService();
      }

      // Re-register WorkManager guardian in case it was lost
      await registerGuardianTask();
    }
  }
}

// =============================================================================
// BACKGROUND ISOLATE ENTRY POINT
// Everything below runs in a SEPARATE Dart isolate on Android.
// It has NO access to the main isolate's memory, widgets, or global variables.
// =============================================================================

@pragma('vm:entry-point')
Future<void> _onStart(ServiceInstance service) async {
  // Required for plugins to work in background isolate
  DartPluginRegistrant.ensureInitialized();

  bool shouldStop = false;
  StreamSubscription<Position>? positionSub;
  Timer? watchdogTimer;
  Timer? fallbackTimer;
  Timer? connectivityCheckTimer;
  Timer? dbCleanupTimer;

  // Track when the last position was received from the stream
  DateTime lastStreamPositionTime = DateTime.now();
  int streamRestartCount = 0;

  // Track alert state — use timestamp cooldown so alerts repeat every 3 minutes
  DateTime? lastAlertTime;

  // Connectivity & retry state
  bool isOnline = true;
  int consecutiveFailures = 0;

  // Connectivity check helper
  Future<bool> hasInternetConnectivity() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // Initialize the local notifications plugin for alert sounds
  final FlutterLocalNotificationsPlugin alertNotifications =
      FlutterLocalNotificationsPlugin();
  await alertNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  // Create the alert notification channel in the background isolate too.
  // The main isolate creates it in initialize(), but the background isolate
  // needs its own reference to ensure the channel exists with correct settings.
  final androidPlugin = alertNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      _alertChannelId,
      _alertChannelName,
      description: 'Alerts when GPS or internet is off during delivery',
      importance: Importance.max,
      showBadge: true,
      enableVibration: true,
      playSound: true,
    ),
  );

  // Listen for stop command from UI isolate
  service.on('stop').listen((_) {
    print('BackgroundLocationService: Received stop command.');
    shouldStop = true;
    positionSub?.cancel();
    watchdogTimer?.cancel();
    fallbackTimer?.cancel();
    connectivityCheckTimer?.cancel();
    dbCleanupTimer?.cancel();
    // Dismiss any active alert when stopping
    alertNotifications.cancel(_alertNotificationId);
    service.stopSelf();
  });

  // ---------- Helper: update the foreground notification ----------
  void updateNotification(String content) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Bestseed - Delivering',
        content: content,
      );
    }
  }

  // ---------- Helper: send tracking alert to backend (notifies vendor + admin) ----------
  Future<void> sendTrackingAlert(String issueType) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
      if (token == null || token.isEmpty) return;

      await http.post(
        Uri.parse('$_baseUrl$_trackingAlertEndpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'issue_type': issueType}),
      ).timeout(const Duration(seconds: 10));

      print('BackgroundLocationService: Tracking alert sent -> $issueType');
    } catch (e) {
      print('BackgroundLocationService: Failed to send tracking alert: $e');
    }
  }

  // ---------- Helper: show a loud alert notification ----------
  // Uses a 3-minute cooldown so alerts repeat periodically while GPS/internet
  // stays off, instead of firing only once.
  Future<void> showErrorAlert({
    required String title,
    required String body,
  }) async {
    if (shouldStop) return;

    // Allow alert if: first time, OR 3+ minutes since last alert
    if (lastAlertTime != null) {
      final sinceLastAlert = DateTime.now().difference(lastAlertTime!);
      if (sinceLastAlert < const Duration(minutes: 3)) {
        print('BackgroundLocationService: Alert cooldown — '
            '${sinceLastAlert.inSeconds}s since last alert, skipping.');
        return;
      }
    }

    lastAlertTime = DateTime.now();
    print('BackgroundLocationService: ALERT — $title: $body');

    // Determine issue type from title and notify vendor + admin via backend
    final issueType = title.contains('GPS') ? 'gps_off' : 'internet_off';
    sendTrackingAlert(issueType); // fire-and-forget, don't await

    // FLAG_INSISTENT (4) makes the default notification sound loop continuously
    // until dismissed. Auto-cancel after 15 seconds.
    await alertNotifications.show(
      _alertNotificationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _alertChannelId,
          _alertChannelName,
          channelDescription: 'Alerts when GPS or internet is off during delivery',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          ongoing: false,
          autoCancel: true,
          additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT
          ticker: 'Location tracking issue!',
        ),
      ),
    );

    // Stop the looping alert sound after 15 seconds
    Timer(const Duration(seconds: 15), () {
      alertNotifications.cancel(_alertNotificationId);
    });
  }

  // ---------- Helper: dismiss the alert when issue is resolved ----------
  Future<void> dismissErrorAlert() async {
    if (lastAlertTime == null) return;
    lastAlertTime = null;
    await alertNotifications.cancel(_alertNotificationId);
    print('BackgroundLocationService: Alert dismissed — issue resolved.');
  }

  // ---------- Helper: Queue a failed position to SQLite ----------
  Future<void> queuePosition(Position position, {String? locationName}) async {
    try {
      await TrackingDatabase.insert(
        lat: position.latitude,
        lng: position.longitude,
        locationName: locationName,
      );
      final count = await TrackingDatabase.getUnsentCount();
      print('BackgroundLocationService: Queued position to SQLite '
          '($count unsent in queue)');
    } catch (e) {
      print('BackgroundLocationService: SQLite queue failed: $e');
    }
  }

  // ---------- Helper: Flush queued positions from SQLite ----------
  Future<void> flushLocationQueue() async {
    try {
      final count = await TrackingDatabase.getUnsentCount();
      if (count == 0) return;

      print('BackgroundLocationService: Flushing $count queued positions...');

      // Send only the most recent queued position (backend only needs latest)
      final latest = await TrackingDatabase.getLatestUnsent();
      if (latest == null) return;

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
      if (token == null || token.isEmpty) return;

      final response = await http.post(
        Uri.parse('$_baseUrl$_locationUpdateEndpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'lat': latest['lat'],
          'lng': latest['lng'],
          'location_name': latest['location_name'] ?? 'Reconnected - live location',
        }),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await TrackingDatabase.markAllSent();
        consecutiveFailures = 0;
        print('BackgroundLocationService: Queue flushed successfully.');
      }
    } catch (e) {
      print('BackgroundLocationService: Queue flush failed: $e');
    }
  }

  // ---------- Send a single position to the backend ----------
  // Returns true  → keep running
  // Returns false → stop the service (journey ended / no token / flag off)
  Future<bool> sendPosition(Position position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final shouldRun = prefs.getBool(_serviceRunningKey) ?? false;
    if (!shouldRun) {
      print('BackgroundLocationService: Service flag is false, stopping.');
      return false;
    }

    final token = prefs.getString(_tokenKey);
    if (token == null || token.isEmpty) {
      print('BackgroundLocationService: No token found, stopping.');
      await prefs.setBool(_serviceRunningKey, false);
      return false;
    }

    print('BackgroundLocationService: Position -> '
        'lat=${position.latitude}, lng=${position.longitude}');

    // Reverse geocode (non-critical — OK if it fails)
    String? locationName;
    try {
      locationName = await _reverseGeocodeHttp(
        position.latitude,
        position.longitude,
      );
    } catch (_) {}

    // Always save to SQLite first (crash-proof)
    await queuePosition(position, locationName: locationName);

    // POST to backend API
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl$_locationUpdateEndpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'lat': position.latitude,
          'lng': position.longitude,
          'location_name': locationName ?? 'Live vehicle location',
        }),
      ).timeout(const Duration(seconds: 30));

      print('BackgroundLocationService: API Response ${response.statusCode}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);

        if (data['status'] == false) {
          print(
              'BackgroundLocationService: Journey ended, stopping service.');
          await prefs.setBool(_serviceRunningKey, false);
          return false;
        }

        // Success! Reset backoff, mark queue as sent
        consecutiveFailures = 0;
        isOnline = true;
        await TrackingDatabase.markAllSent();
        await dismissErrorAlert();

        updateNotification(
            'Location: ${locationName ?? 'Tracking active...'}');

        service.invoke('locationUpdate', {
          'lat': position.latitude,
          'lng': position.longitude,
          'location_name': locationName,
          'timestamp': DateTime.now().toIso8601String(),
        });

        print('BackgroundLocationService: Location sent successfully.');
      } else {
        print(
            'BackgroundLocationService: API error ${response.statusCode}');
        consecutiveFailures++;
        updateNotification('Server error, retrying...');
      }
    } on TimeoutException {
      print('BackgroundLocationService: API call timed out, will retry.');
      consecutiveFailures++;
      updateNotification('Slow network - retrying...');
      // Only show alert after 3+ consecutive failures to avoid false alarms
      if (consecutiveFailures >= 3) {
        isOnline = false;
        await showErrorAlert(
          title: 'Internet Issue!',
          body: 'Please check your internet connection. Location updates are failing.',
        );
      }
    } catch (e) {
      print('BackgroundLocationService: Network error: $e');
      consecutiveFailures++;
      updateNotification('Network issue - retrying...');
      // Only show alert after 3+ consecutive failures to avoid false alarms
      if (consecutiveFailures >= 3) {
        isOnline = false;
        await showErrorAlert(
          title: 'Internet Issue!',
          body: 'Please check your internet connection. Location updates are failing.',
        );
      }
    }

    return true;
  }

  // ==========================================================================
  // Helper: Start (or restart) the Geolocator position stream.
  // Extracted so the watchdog can call it when the stream dies.
  // ==========================================================================
  Future<void> startPositionStream() async {
    // Cancel any existing subscription first
    await positionSub?.cancel();
    positionSub = null;

    if (shouldStop) return;

    streamRestartCount++;
    print('BackgroundLocationService: Starting position stream '
        '(attempt #$streamRestartCount)');

    positionSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        intervalDuration: const Duration(minutes: 2),
        distanceFilter: 0,
        // On stream restart attempts > 2, try the platform LocationManager
        // instead of Fused Location Provider. Some OEMs (OnePlus, Realme)
        // kill the FLP but leave the platform LocationManager alive.
        forceLocationManager: streamRestartCount > 2,
      ),
    ).listen(
      (position) async {
        if (shouldStop) return;
        lastStreamPositionTime = DateTime.now();
        try {
          final keepRunning = await sendPosition(position);
          if (!keepRunning) {
            shouldStop = true;
            positionSub?.cancel();
            watchdogTimer?.cancel();
            fallbackTimer?.cancel();
            dbCleanupTimer?.cancel();
            service.stopSelf();
          }
        } catch (e, stack) {
          print('BackgroundLocationService UNEXPECTED: $e');
          print('$stack');
        }
      },
      onError: (e) {
        print('BackgroundLocationService: Stream error: $e');
        updateNotification('GPS is OFF - Please turn on location!');
        showErrorAlert(
          title: 'GPS is OFF!',
          body: 'Please turn on your location/GPS. Delivery tracking has stopped.',
        );
      },
      cancelOnError: false,
    );
  }

  // ==========================================================================
  // Helper: Fallback polling using getCurrentPosition.
  // Only fires when the position stream hasn't delivered a position recently
  // (i.e., stream is dead/stalled). Prevents duplicate API calls.
  // ==========================================================================
  Future<void> fallbackPoll() async {
    if (shouldStop) return;

    // Skip if the stream delivered a position recently (within 3 minutes)
    final timeSinceLastStream =
        DateTime.now().difference(lastStreamPositionTime);
    if (timeSinceLastStream < const Duration(minutes: 3)) {
      print('BackgroundLocationService: Fallback skipped — stream is alive '
          '(last ${timeSinceLastStream.inSeconds}s ago)');
      return;
    }

    print('BackgroundLocationService: Fallback poll firing — stream silent for '
        '${timeSinceLastStream.inMinutes}m ${timeSinceLastStream.inSeconds % 60}s');

    try {
      // First check if location service is enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('BackgroundLocationService: GPS is disabled!');
        updateNotification('GPS is OFF - Please turn on location!');
        await showErrorAlert(
          title: 'GPS is OFF!',
          body: 'Please turn on your location/GPS. Delivery tracking has stopped.',
        );
        return;
      }

      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
        // Reject stale positions older than 10 minutes
        if (pos != null && pos.timestamp != null) {
          final age = DateTime.now().difference(pos.timestamp!);
          if (age > _maxStalePositionAge) {
            print('BackgroundLocationService: Stale position '
                '(${age.inMinutes}m old), discarding.');
            pos = null;
          }
        }
      }

      if (pos != null && !shouldStop) {
        final keepRunning = await sendPosition(pos);
        if (!keepRunning) {
          shouldStop = true;
          positionSub?.cancel();
          watchdogTimer?.cancel();
          fallbackTimer?.cancel();
          dbCleanupTimer?.cancel();
          service.stopSelf();
        }
      }
    } catch (e) {
      print('BackgroundLocationService: Fallback poll error: $e');
    }
  }

  // ==========================================================================
  // 1. Send first position immediately
  // ==========================================================================
  try {
    Position? firstPos;
    try {
      firstPos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
    } catch (_) {
      firstPos = await Geolocator.getLastKnownPosition();
      if (firstPos != null && firstPos.timestamp != null) {
        final age = DateTime.now().difference(firstPos.timestamp!);
        if (age > _maxStalePositionAge) {
          print('BackgroundLocationService: Initial position stale '
              '(${age.inMinutes}m old), discarding.');
          firstPos = null;
        }
      }
    }
    if (firstPos != null && !shouldStop) {
      final keepRunning = await sendPosition(firstPos);
      if (!keepRunning) {
        service.stopSelf();
        return;
      }
    }
  } catch (e) {
    print('BackgroundLocationService: Initial send failed: $e');
  }

  // ==========================================================================
  // 2. Start the position stream
  // ==========================================================================
  await startPositionStream();

  // ==========================================================================
  // 3. WATCHDOG TIMER — detects if the position stream dies silently.
  //
  //    OEMs like OnePlus (OxygenOS) and Realme (ColorOS) can kill the
  //    Fused Location Provider stream after 10 minutes without any error
  //    callback. The watchdog checks every 3 minutes: if no position was
  //    received in the last 5 minutes, it restarts the stream.
  // ==========================================================================
  watchdogTimer = Timer.periodic(_watchdogInterval, (timer) async {
    if (shouldStop) {
      timer.cancel();
      return;
    }

    // Check if service should still be running
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final shouldRun = prefs.getBool(_serviceRunningKey) ?? false;
      if (!shouldRun) {
        print('BackgroundLocationService: Watchdog detected service flag off.');
        shouldStop = true;
        positionSub?.cancel();
        fallbackTimer?.cancel();
        connectivityCheckTimer?.cancel();
        dbCleanupTimer?.cancel();
        timer.cancel();
        await alertNotifications.cancel(_alertNotificationId);
        service.stopSelf();
        return;
      }
    } catch (_) {}

    // Check GPS status and alert if off
    try {
      final gpsEnabled = await Geolocator.isLocationServiceEnabled();
      if (!gpsEnabled) {
        updateNotification('GPS is OFF - Please turn on location!');
        await showErrorAlert(
          title: 'GPS is OFF!',
          body: 'Please turn on your location/GPS. Delivery tracking has stopped.',
        );
      }
    } catch (_) {}

    final timeSinceLastPosition =
        DateTime.now().difference(lastStreamPositionTime);

    if (timeSinceLastPosition > _streamTimeout) {
      print('BackgroundLocationService: WATCHDOG — No position received for '
          '${timeSinceLastPosition.inMinutes} minutes. Restarting stream...');
      updateNotification('Reconnecting GPS...');

      await startPositionStream();
      // Reset the timer
      lastStreamPositionTime = DateTime.now();
    } else {
      print('BackgroundLocationService: Watchdog OK — last position '
          '${timeSinceLastPosition.inSeconds}s ago.');
    }
  });

  // ==========================================================================
  // 4. FALLBACK POLL TIMER — independent of the stream.
  //
  //    Even if the position stream AND the watchdog both fail (extreme OEM
  //    kill), this timer uses getCurrentPosition() as a last resort.
  //    It runs every 2 minutes. If Dart timers stop (CPU sleep), the
  //    watchdog or stream restart on next wake will catch up.
  // ==========================================================================
  fallbackTimer = Timer.periodic(_fallbackPollInterval, (timer) async {
    if (shouldStop) {
      timer.cancel();
      return;
    }
    await fallbackPoll();
  });

  // ==========================================================================
  // 5. CONNECTIVITY CHECK TIMER — detects when internet returns.
  //
  //    Checks every 30 seconds. When connectivity is restored after being
  //    offline, immediately flushes the SQLite queue and triggers a
  //    fresh location send. This ensures minimal delay when reconnecting.
  // ==========================================================================
  connectivityCheckTimer =
      Timer.periodic(_connectivityCheckInterval, (timer) async {
    if (shouldStop) {
      timer.cancel();
      return;
    }

    final nowOnline = await hasInternetConnectivity();

    if (nowOnline && !isOnline) {
      // Connectivity just restored!
      print('BackgroundLocationService: Connectivity restored!');
      isOnline = true;
      consecutiveFailures = 0;
      await dismissErrorAlert();
      updateNotification('Reconnected - tracking active...');

      // Flush queued positions from SQLite
      await flushLocationQueue();

      // Trigger immediate fresh position
      await fallbackPoll();
    } else if (!nowOnline && isOnline && consecutiveFailures >= 3) {
      // Only mark offline if API calls are also failing (consecutiveFailures >= 3)
      // DNS lookup can fail even when API works fine on some networks
      print('BackgroundLocationService: Connectivity lost (confirmed by failures).');
      isOnline = false;
    }
  });

  // ==========================================================================
  // 6. PERIODIC SQLITE CLEANUP — delete old sent records every hour
  // ==========================================================================
  dbCleanupTimer = Timer.periodic(_dbCleanupInterval, (timer) async {
    if (shouldStop) {
      timer.cancel();
      return;
    }
    try {
      await TrackingDatabase.cleanup();
      print('BackgroundLocationService: SQLite cleanup done.');
    } catch (e) {
      print('BackgroundLocationService: SQLite cleanup error: $e');
    }
  });
}

/// iOS background handler
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final token = prefs.getString(_tokenKey);
    if (token == null) return false;

    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
    } catch (_) {
      position = await Geolocator.getLastKnownPosition();
    }
    if (position == null) return true; // No position, retry next time

    // Save to SQLite first
    await TrackingDatabase.insert(
      lat: position.latitude,
      lng: position.longitude,
    );

    final locationName = await _reverseGeocodeHttp(
      position.latitude,
      position.longitude,
    );

    final response = await http
        .post(
          Uri.parse('$_baseUrl$_locationUpdateEndpoint'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'lat': position.latitude,
            'lng': position.longitude,
            'location_name': locationName ?? 'Live vehicle location',
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body);
      await TrackingDatabase.markAllSent();
      if (data['status'] == false) {
        await prefs.setBool(_serviceRunningKey, false);
        service.stopSelf();
        return false;
      }
    }
    return true;
  } catch (e) {
    print('iOS background error: $e');
    return false;
  }
}

/// HTTP-based reverse geocoding that works in background isolate.
Future<String?> _reverseGeocodeHttp(double lat, double lng) async {
  try {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json'
      '?latlng=$lat,$lng'
      '&result_type=sublocality|locality|administrative_area_level_1'
      '&language=en'
      '&key=$_googleApiKey',
    );

    final response = await http.get(url).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body);
    if (data['status'] != 'OK') return null;

    final results = data['results'] as List;
    if (results.isEmpty) return null;

    String? subLocality;
    String? locality;
    String? adminArea;

    for (var component in results[0]['address_components']) {
      final types = (component['types'] as List).cast<String>();
      if (types.contains('sublocality') ||
          types.contains('sublocality_level_1')) {
        subLocality = component['long_name'];
      }
      if (types.contains('locality')) {
        locality = component['long_name'];
      }
      if (types.contains('administrative_area_level_1')) {
        adminArea = component['long_name'];
      }
    }

    return [subLocality, locality, adminArea]
        .where((e) => e != null && e.isNotEmpty)
        .join(', ');
  } catch (e) {
    print('Background reverse geocoding failed: $e');
    return null;
  }
}
