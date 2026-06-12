import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ios_location_service.dart';
import 'tracking_database.dart';
import 'tracking_logger.dart';
import 'tracking_work_manager.dart';

// --- Constants (duplicated here because this file must be self-contained
//     for the background isolate; it cannot import Flutter-widget-dependent files) ---
// const String _baseUrl =
//     'http://192.168.0.104:8000/api/';
// const String _baseUrl =
//     'http://192.168.29.111:8000/api/';
const String _baseUrl =
    'https://staging.bestseed.in/api/';
const String _locationUpdateEndpoint = 'driver/location/update';
const String _trackingAlertEndpoint = 'driver/tracking-alert';
const String _googleApiKey = 'AIzaSyA111b89Exrm83RRWF-2hP1EPeUxvos87I';
const String _tokenKey = 'driver_token';
const String _serviceRunningKey = 'bg_location_service_running';

// Notification channel constants — silent foreground service notification
const String _notificationChannelId = 'bestseeds_location_v2';
const String _notificationChannelName = 'Location Tracking';
const int _notificationId = 888;

// Alert notification channel — loud custom sound for GPS/internet errors
// Using v2 channel ID because Android caches channel settings; changing the ID
// forces Android to create a fresh channel with the new sound + volume settings.
const String _alertChannelId = 'bestseeds_alert_v4';
const String _alertChannelName = 'Tracking Alerts';
const int _alertNotificationId = 889;

// Watchdog constants
// _streamTimeout: how long the stream must be silent before watchdog restarts it.
//   Reduced 3 min → 90 s so OEM-throttled streams are caught within one watchdog tick.
// _fallbackPollInterval: how often the fallback timer fires.
//   Reduced 2 min → 60 s so there is always a position attempt every ~60 s.
// _fallbackGuard: fallback skips if the stream delivered a position within this window.
//   Reduced from the old inline 3-min to 90 s so fallback kicks in sooner.
// Together these reduce the worst-case gap from ~6 min to ~90 s.
const Duration _watchdogInterval = Duration(minutes: 1);
const Duration _streamTimeout = Duration(seconds: 90);
const Duration _fallbackPollInterval = Duration(seconds: 60);
const Duration _fallbackGuard = Duration(seconds: 90);   // replaces old inline 3-min guard
const Duration _connectivityCheckInterval = Duration(seconds: 30);
const Duration _maxStalePositionAge = Duration(minutes: 10);
const Duration _dbCleanupInterval = Duration(hours: 1);
const Duration _movingUpdateInterval = Duration(seconds: 10);
const Duration _stoppedHeartbeatInterval = Duration(seconds: 15);
const Duration _reverseGeocodeRefreshInterval = Duration(minutes: 3);  // was 5 min
const double _minMovementMetersForSend = 10;
const double _significantMovementMetersForSend = 150;
const double _reverseGeocodeRefreshMeters = 300;  // was 400 m — refresh after 300 m

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
    TrackingLogger.log('▶ service.start() requested');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceRunningKey, true);

    if (Platform.isIOS) {
      // On iOS flutter_background_service creates a secondary FlutterEngine
      // whose CLLocationManager does NOT receive background callbacks from
      // iOS Core Location. Run the stream directly in the main isolate instead.
      await IosLocationService.start();
      return;
    }

    await _prepareAndroidBackgroundExecution();

    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
    }

    await registerGuardianTask();
    await registerActiveCaptureTask();
  }

  /// Stop the background location service + cancel WorkManager guardian.
  static Future<void> stop() async {
    TrackingLogger.log('■ service.stop() requested');
    await TrackingLogger.flush();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceRunningKey, false);

    if (Platform.isIOS) {
      await IosLocationService.stop();
      await TrackingDatabase.clearAll();
      return;
    }

    final isRunning = await _service.isRunning();
    if (isRunning) {
      _service.invoke('stop');
    }

    await cancelGuardianTask();
    await cancelActiveCaptureTask();
    await TrackingDatabase.clearAll();
  }

  /// Check if the service is currently running.
  static Future<bool> isRunning() async {
    if (Platform.isIOS) return IosLocationService.isActive;
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
  /// Also detects "zombie" state: service process alive but Dart isolate
  /// dead (e.g. after hot restart) — no location sent in 90s despite
  /// isRunning()=true means the isolate is dead.
  static Future<void> restartIfNeeded() async {
    final shouldRun = await shouldBeRunning();
    if (!shouldRun) {
      print('📍 [RESTART] shouldRun=false — no active journey, skipping');
      return;
    }

    final running = await isRunning();
    print('📍 [RESTART] shouldRun=true, isRunning=$running');

    if (running) {
      // Service reports "running" — but is it ACTUALLY sending?
      // After hot restart, Android service process stays alive but the
      // Dart isolate (stream, timers, watchdog) is dead. Detect this
      // zombie state by checking last_location_sent_at timestamp.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final lastSentMs = prefs.getInt('last_location_sent_at') ?? 0;
      final lastSentAge = DateTime.now().millisecondsSinceEpoch - lastSentMs;
      final lastSentAgeSec = lastSentAge ~/ 1000;

      if (lastSentMs > 0 && lastSentAgeSec < 90) {
        // Location was sent recently — service is genuinely alive
        print('📍 [RESTART] Service alive — last sent ${lastSentAgeSec}s ago, OK');
        return;
      }

      // Service "running" but no recent send — zombie state.
      // Force stop + restart to get a fresh Dart isolate.
      print('📍 [RESTART] ⚠️ ZOMBIE detected — service "running" but last sent ${lastSentAgeSec}s ago. Force restarting...');
      TrackingLogger.log('⚠ zombie service detected — last sent ${lastSentAgeSec}s ago, force restarting');

      if (Platform.isIOS) {
        await IosLocationService.stop();
        await Future.delayed(const Duration(milliseconds: 500));
        await IosLocationService.start();
        print('📍 [RESTART] iOS service force-restarted');
        return;
      }

      // Android: stop the zombie service, wait, then start fresh
      try {
        _service.invoke('stopService');
        await Future.delayed(const Duration(seconds: 2));
      } catch (_) {}
    }

    // Service is NOT running (or was just stopped) — start it
    if (Platform.isIOS) {
      print('📍 [RESTART] Starting iOS location stream...');
      await IosLocationService.start();
      return;
    }

    print('📍 [RESTART] Starting Android foreground service...');
    await _prepareAndroidBackgroundExecution();
    await _service.startService();
    await Future.delayed(const Duration(seconds: 2));
    final nowRunning = await isRunning();
    if (!nowRunning) {
      print('📍 [RESTART] First start failed, retrying...');
      await _service.startService();
    }
    await registerGuardianTask();
    await registerActiveCaptureTask();
    print('📍 [RESTART] ✅ Service + WorkManager tasks started');
  }

  static Future<void> _prepareAndroidBackgroundExecution() async {
    if (!Platform.isAndroid) return;
    // Battery optimization exemption is requested in _ensureBatteryOptimizationExemption()
    // before the journey starts (in the UI layer). Calling request() here would
    // show the system dialog a second time after the API already succeeded.
    // We only check status — if not granted the service still runs, just with
    // potentially more aggressive battery management on some OEMs.
    try {
      final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
      if (!batteryStatus.isGranted) {
        print('BackgroundLocationService: Battery optimization not exempted — '
            'service may be killed on aggressive OEM ROMs.');
      }
    } catch (e) {
      print('BackgroundLocationService: Battery status check failed: $e');
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
  try {
    await WakelockPlus.enable();
    print('BackgroundLocationService: Wake lock enabled.');
  } catch (e) {
    print('BackgroundLocationService: Failed to enable wake lock: $e');
  }

  // Initialise file logger — creates/appends to
  // <externalStorage>/tracking_YYYY-MM-DD.log
  // Pull after a journey: adb pull <path printed below>
  await TrackingLogger.init();
  TrackingLogger.log('▶ _onStart isolate started — log file: ${TrackingLogger.logFilePath}');

  // Re-register WorkManager tasks immediately on every service start.
  //
  // Why: three paths can start this isolate without going through the
  // public BackgroundLocationService.start() method which normally
  // registers tasks:
  //   (a) autoStartOnBoot: true — BootReceiver fires after phone reboot,
  //       WorkManager DB may have been wiped by aggressive OEM optimizer.
  //   (b) restartIfNeeded() previously only re-registered the guardian,
  //       not the active-capture chain (now fixed, but defence-in-depth).
  //   (c) Second-attempt restart in WorkManager guardian task itself.
  //
  // registerActiveCaptureTask / registerGuardianTask use
  // ExistingWorkPolicy.replace so calling them when tasks already exist
  // is safe — it just resets their delay counters.
  try {
    final startPrefs = await SharedPreferences.getInstance();
    await startPrefs.reload();
    if (startPrefs.getBool(_serviceRunningKey) ?? false) {
      await registerGuardianTask();
      await registerActiveCaptureTask();
      print('BackgroundLocationService: WorkManager tasks re-registered on _onStart');
    }
  } catch (e) {
    print('BackgroundLocationService: WorkManager re-register failed: $e');
  }

  bool shouldStop = false;
  StreamSubscription<Position>? positionSub;
  StreamSubscription<List<ConnectivityResult>>? connectivitySub;
  Timer? watchdogTimer;
  Timer? fallbackTimer;
  Timer? connectivityCheckTimer;
  Timer? dbCleanupTimer;

  Future<void> releaseWakeLock() async {
    try {
      await WakelockPlus.disable();
      print('BackgroundLocationService: Wake lock disabled.');
    } catch (e) {
      print('BackgroundLocationService: Failed to disable wake lock: $e');
    }
  }

  // Track when the last FRESH position was received from the stream.
  // Only updated when the position moves > 2m — frozen/identical positions
  // do NOT reset this, so the watchdog can detect a stale stream.
  DateTime lastStreamPositionTime = DateTime.now();
  int streamRestartCount = 0;

  // Watchdog tick counter — used to re-register WorkManager active-capture
  // chain every 30 minutes. The chain is self-maintaining (each run
  // re-registers the next), but on aggressive OEMs it can be coalesced or
  // dropped silently during multi-day journeys. Re-registering from the
  // watchdog ensures the 2-min backup is never dead for more than 30 min.
  int watchdogTicks = 0;

  // Frozen-stream detection.
  // OEM phones (Xiaomi, Realme, Vivo) sometimes keep the Geolocator stream
  // "alive" but return the same cached lat/lng on every tick.  The watchdog
  // sees lastStreamPositionTime updating and thinks the stream is healthy —
  // worst kind of bug because tracking appears OK but the driver never moves.
  //
  // Fix: only update lastStreamPositionTime on genuinely fresh coordinates
  // (> 2 m from the previous reading).  Count identical readings; after
  // 9 consecutive same positions (~90 s at 10 s intervals) force a restart.
  Position? lastRawStreamPosition;
  int consecutiveSameStreamPositions = 0;
  const int frozenStreamRestartThreshold = 9;        // ~90 s at 10 s intervals
  const double frozenPositionThresholdMeters = 2.0;  // metres — real GPS noise < this

  // Per-issue-type cooldowns so a GPS alert does not block an internet alert
  // and vice versa. Key = issue_type string, value = time it was last fired.
  final Map<String, DateTime> alertCooldowns = {};
  // Keep legacy reference so dismissErrorAlert can clear all cooldowns at once.
  DateTime? lastAlertTime; // only used for backward-compat dismiss logic below

  // Connectivity & retry state
  bool isOnline = true;
  int consecutiveFailures = 0;
  // Set by sendPosition() when consecutive failures indicate the
  // Geolocator stream may have silently died. The watchdog (which runs
  // every 1 minute) picks this up and calls startPositionStream() —
  // we can't restart the stream from inside sendPosition() directly
  // because startPositionStream is declared later in the same lexical
  // scope of _onStart and Dart forbids forward local references.
  bool streamRestartRequested = false;
  Position? lastSentPosition;
  DateTime? lastSentAt;
  Position? lastReverseGeocodedPosition;
  DateTime? lastReverseGeocodedAt;
  String? lastResolvedLocationName;

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
    connectivitySub?.cancel();
    watchdogTimer?.cancel();
    fallbackTimer?.cancel();
    connectivityCheckTimer?.cancel();
    dbCleanupTimer?.cancel();
    // Dismiss any active alert when stopping
    alertNotifications.cancel(_alertNotificationId);
    releaseWakeLock();
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
    // Re-post via FlutterLocalNotificationsPlugin with the same notification ID.
    // setForegroundNotificationInfo() updates the service notification internally,
    // but Android can keep showing a stale snapshot on the lock screen.
    // Re-posting with NotificationVisibility.public forces the lock screen to
    // refresh and show the new location text even while the screen is locked.
    alertNotifications.show(
      _notificationId,
      'Bestseed - Delivering',
      content,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _notificationChannelId,
          _notificationChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          visibility: NotificationVisibility.public,
          enableVibration: false,
          playSound: false,
        ),
      ),
    );
  }

  String _gpsAgeText() {
    if (lastSentAt == null) return 'waiting for GPS';
    final age = DateTime.now().difference(lastSentAt!);
    if (age.inSeconds < 90) return 'GPS just now';
    if (age.inMinutes < 60) return 'GPS ${age.inMinutes}m ago';
    return 'GPS ${age.inHours}h ago';
  }

  String trackingNotificationContent() {
    final locationPart = lastResolvedLocationName != null &&
            lastResolvedLocationName!.trim().isNotEmpty
        ? lastResolvedLocationName!
        : 'Tracking active';
    return '$locationPart • ${_gpsAgeText()}';
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
      ).timeout(const Duration(seconds: 8));

      print('BackgroundLocationService: Tracking alert sent -> $issueType');
    } catch (e) {
      print('BackgroundLocationService: Failed to send tracking alert: $e');
    }
  }

  // ---------- Helper: show a loud alert notification ----------
  // Each issue type has its own 3-minute cooldown so a GPS alert never
  // blocks an internet or battery alert from firing at the same time.
  Future<void> showErrorAlert({
    required String title,
    required String body,
    String? alertType,
  }) async {
    if (shouldStop) return;

    // Derive the canonical issue type used as the cooldown key and for the
    // backend alert. Caller can pass alertType explicitly; otherwise we infer
    // from the title (preserves backward compatibility with existing call sites).
    final issueType = alertType ??
        (title.contains('GPS')
            ? 'gps_off'
            : title.contains('Battery')
                ? 'battery_low'
                : title.contains('Location Not')
                    ? 'location_not_sending'
                    : 'internet_off');

    // Driver app: show only ONE alert per issue type (no repeats).
    // Cooldown is cleared when the issue resolves (GPS/internet back on).
    // Vendor/Admin notifications continue via sendTrackingAlert (unaffected).
    final lastFired = alertCooldowns[issueType];
    if (lastFired != null) {
      print('BackgroundLocationService: Alert already shown ($issueType), skipping repeat.');
      // Still send to backend so vendor/admin get continuous updates
      sendTrackingAlert(issueType);
      return;
    }

    alertCooldowns[issueType] = DateTime.now();
    lastAlertTime = DateTime.now();
    print('BackgroundLocationService: ALERT [$issueType] — $title: $body');

    sendTrackingAlert(issueType); // vendor/admin get notified

    // Single notification — no FLAG_INSISTENT (no looping sound)
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
          ticker: 'Location tracking issue!',
        ),
      ),
    );

    // Auto-dismiss after 10 seconds
    Timer(const Duration(seconds: 10), () {
      alertNotifications.cancel(_alertNotificationId);
    });
  }

  // ---------- Helper: dismiss connectivity/GPS alerts when issue is resolved ----------
  // Only clears the internet_off and gps_off cooldowns so battery_low and
  // location_not_sending alerts can still fire independently.
  Future<void> dismissErrorAlert() async {
    if (lastAlertTime == null) return;
    lastAlertTime = null;
    alertCooldowns.remove('internet_off');
    alertCooldowns.remove('gps_off');
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
      TrackingLogger.log(
          'queue   lat=${position.latitude.toStringAsFixed(6)} '
          'lng=${position.longitude.toStringAsFixed(6)} '
          'acc=${position.accuracy.toStringAsFixed(0)}m '
          'pending=$count');
      print('BackgroundLocationService: Queued position to SQLite '
          '($count unsent in queue)');
    } catch (e) {
      TrackingLogger.log('✗ queue  error: $e');
      print('BackgroundLocationService: SQLite queue failed: $e');
    }
  }

  // ---------- Helper: Flush queued positions from SQLite ----------
  //
  // Sends ALL unsent points (up to 200 — the SQLite queue cap) as a
  // single batch request to /api/driver/location/batch-update.
  //
  // Why batch instead of one-by-one:
  //  • One HTTP request vs up to 200 — reconnect is fast.
  //  • Each point carries its original GPS timestamp (the 'timestamp'
  //    column stored at capture time). The batch endpoint uses these
  //    for reached_at and spike-detection, so the backend timeline
  //    stays in the correct chronological order even after a 30-min
  //    offline gap.
  //  • No race condition: markAllSent() is called only after the
  //    entire batch succeeds, so if the request fails the points
  //    stay queued for the next connectivity-restored event.
  Future<void> flushLocationQueue() async {
    try {
      final unsent = await TrackingDatabase.getAllUnsent();
      if (unsent.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
      if (token == null || token.isEmpty) return;

      print('BackgroundLocationService: Flushing ${unsent.length} queued points via batch...');
      TrackingLogger.log('↑ flush  ${unsent.length} queued points → batch endpoint');

      final points = unsent.map((row) => {
        'lat': row['lat'],
        'lng': row['lng'],
        'location_name': row['location_name'] ?? 'Offline location',
        // 'timestamp' is the ISO-8601 string stored at GPS capture time.
        // The batch endpoint uses it as reached_at.
        'gps_timestamp': row['timestamp'],
      }).toList();

      final response = await http.post(
        Uri.parse('${_baseUrl}driver/location/batch-update'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'points': points}),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await TrackingDatabase.markAllSent();
        consecutiveFailures = 0;
        TrackingLogger.log('✓ flush  ${unsent.length} points accepted by server');
        print('BackgroundLocationService: Batch flush successful (${unsent.length} points).');
      } else {
        TrackingLogger.log('✗ flush  http=${response.statusCode} pending=${unsent.length}');
        print('BackgroundLocationService: Batch flush failed: ${response.statusCode}');
      }
    } catch (e) {
      TrackingLogger.log('✗ flush  error: $e');
      print('BackgroundLocationService: Batch flush error: $e');
    }
  }

  double distanceBetweenPositions(Position a, Position b) {
    return Geolocator.distanceBetween(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
  }

  bool shouldSendPosition(Position position) {
    final now = DateTime.now();
    final sinceLastSend = lastSentAt == null
        ? const Duration(days: 1)
        : now.difference(lastSentAt!);

    // ── Reject low-accuracy positions (cell tower / WiFi triangulation) ──
    // Real GPS accuracy: 5-30m. Cell tower: 300-2000m. WiFi: 50-200m.
    // Positions with accuracy > 100m are NOT real GPS — they cause ghost
    // locations (e.g. phone shows Madhapur but driver is at Borabanda).
    if (position.accuracy > 100) {
      final allowDegradedAccuracy =
          sinceLastSend >= const Duration(seconds: 60) &&
              position.accuracy <= 500;
      if (allowDegradedAccuracy) {
        TrackingLogger.log(
            'coarse  acc=${position.accuracy.toStringAsFixed(0)}m '
            'silent=${sinceLastSend.inSeconds}s -> allow');
        print('BackgroundLocationService: Allowing degraded-accuracy position '
            '(accuracy=${position.accuracy.toStringAsFixed(0)}m, '
            'silentFor=${sinceLastSend.inSeconds}s)');
      } else {
        TrackingLogger.log(
            'coarse  acc=${position.accuracy.toStringAsFixed(0)}m '
            'silent=${sinceLastSend.inSeconds}s -> reject');
        print('BackgroundLocationService: Rejected low-accuracy position '
            '(accuracy=${position.accuracy.toStringAsFixed(0)}m) - '
            'likely cell tower/WiFi, not real GPS');
        if (lastResolvedLocationName != null) {
          updateNotification('Tracking active... ($lastResolvedLocationName)');
        } else {
          updateNotification('Tracking active... (poor GPS signal)');
        }
        return false;
      }
    }


    if (lastSentAt == null || lastSentPosition == null) {
      return true;
    }

    final movedMeters = distanceBetweenPositions(lastSentPosition!, position);

    // ── Reject sudden jumps from cached/stale positions ──
    // If accuracy was good but position jumped >500m from last sent position
    // in under 5 seconds, it's likely a stale/cached position being replayed.
    if (movedMeters > 500 && sinceLastSend.inSeconds < 5) {
      print('BackgroundLocationService: Rejected position jump '
          '(${movedMeters.toStringAsFixed(0)}m in ${sinceLastSend.inSeconds}s)');
      return false;
    }

    if (movedMeters >= _significantMovementMetersForSend) {
      return true;
    }

    if (movedMeters >= _minMovementMetersForSend &&
        sinceLastSend >= _movingUpdateInterval) {
      return true;
    }

    if (sinceLastSend >= _stoppedHeartbeatInterval) {
      return true;
    }

    // ── Safety valve: long-journey / hotspot gap ──
    // If more than 60s have passed since the last successful send (e.g. the
    // driver was offline while switching to hotspot and no send got through),
    // force the next position through unconditionally. Prevents indefinite
    // silence when the movement/heartbeat gates both missed due to a gap.
    if (sinceLastSend >= const Duration(seconds: 60)) {
      return true;
    }

    return false;
  }

  Future<String?> resolveLocationName(Position position) async {
    final now = DateTime.now();

    if (lastResolvedLocationName != null &&
        lastReverseGeocodedPosition != null &&
        lastReverseGeocodedAt != null) {
      final movedSinceLastLookup = distanceBetweenPositions(
        lastReverseGeocodedPosition!,
        position,
      );
      final isLookupFresh =
          now.difference(lastReverseGeocodedAt!) < _reverseGeocodeRefreshInterval;

      if (movedSinceLastLookup < _reverseGeocodeRefreshMeters && isLookupFresh) {
        return lastResolvedLocationName;
      }
    }

    // How far the driver has moved since the last successful geocode.
    // Used below to decide whether to clear the stale name on failure.
    final distFromAnchor = lastReverseGeocodedPosition == null
        ? double.infinity
        : distanceBetweenPositions(lastReverseGeocodedPosition!, position);

    try {
      final resolved = await reverseGeocodeHttp(
        position.latitude,
        position.longitude,
      );
      if (resolved != null && resolved.isNotEmpty) {
        lastResolvedLocationName = resolved;
        // Only advance the cache anchor when geocoding actually succeeded.
        // If we always advance on failure, the next call sees "moved < 300m
        // from failed-geocode position AND fresh < 3min" → returns the OLD
        // city name instead of retrying.
        lastReverseGeocodedPosition = position;
        lastReverseGeocodedAt = now;
      } else if (distFromAnchor > 1000) {
        // Geocode returned no result AND driver moved > 1 km from the last
        // successful geocode — the cached name is stale. Clear it so the
        // notification shows "Tracking active" instead of the wrong city.
        lastResolvedLocationName = null;
      }
    } catch (_) {
      // Geocode failed — if driver has moved significantly, clear stale name.
      if (distFromAnchor > 1000) {
        lastResolvedLocationName = null;
      }
    }

    return lastResolvedLocationName;
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

    // Reload prefs to pick up latest token written by main isolate
    await prefs.reload();
    final token = prefs.getString(_tokenKey);
    if (token == null || token.isEmpty) {
      print('BackgroundLocationService: No token found, stopping.');
      await prefs.setBool(_serviceRunningKey, false);
      return false;
    }
    print('📍 [LOC-TOKEN] Using token: ${token.substring(0, token.length > 20 ? 20 : token.length)}...');

    if (!shouldSendPosition(position)) {
      // Position didn't meet the send-throttle gate (too close to the
      // last sent point, or too soon). Log anyway so we can see the
      // stream is alive even when individual fixes are being filtered.
      TrackingLogger.log(
          'filter  lat=${position.latitude.toStringAsFixed(6)} '
          'lng=${position.longitude.toStringAsFixed(6)} '
          'acc=${position.accuracy.toStringAsFixed(0)}m '
          'silent=${lastSentAt == null ? 'first' : DateTime.now().difference(lastSentAt!).inSeconds}s '
          '(throttled)');

      // ── Poor-GPS geocode refresh (the 6-min stale notification fix) ──
      // When accuracy > 100m (cell tower / WiFi position), shouldSendPosition
      // rejects the position for backend sends and shows the notification with
      // the OLD lastResolvedLocationName. If the driver has been in poor-GPS
      // conditions for minutes (tunnel, building, city overpass), that name can
      // be from far behind their current position.
      //
      // Fix: attempt a fresh geocode every 1 minute using the medium-accuracy
      // cell-tower position. Cell towers give ~100-500m accuracy — good enough
      // for city-level display in the notification. Backend location update is
      // still skipped (accuracy > 100m guard above stays in place).
      if (position.accuracy > 100) {
        final now = DateTime.now();
        final timeSinceLastGeocode = lastReverseGeocodedAt == null
            ? const Duration(hours: 1)
            : now.difference(lastReverseGeocodedAt!);
        if (timeSinceLastGeocode >= const Duration(minutes: 1)) {
          try {
            final name =
                await reverseGeocodeHttp(position.latitude, position.longitude);
            if (name != null && name.isNotEmpty) {
              lastResolvedLocationName = name;
              lastReverseGeocodedPosition = position;
              lastReverseGeocodedAt = now;
              updateNotification('Tracking active… ($name)');
              TrackingLogger.log('📍 poor-gps geocode → $name '
                  '(acc=${position.accuracy.toStringAsFixed(0)}m)');
            }
          } catch (_) {}
        }
      }

      return true;
    }

    final sendStart = DateTime.now();
    final sinceLastSent = lastSentAt == null
        ? 'first'
        : '${sendStart.difference(lastSentAt!).inSeconds}s';
    TrackingLogger.log(
        '→ send   lat=${position.latitude.toStringAsFixed(6)} '
        'lng=${position.longitude.toStringAsFixed(6)} '
        'acc=${position.accuracy.toStringAsFixed(0)}m '
        'since=$sinceLastSent queue-before-send');
    print('BackgroundLocationService: Position -> '
        'lat=${position.latitude}, lng=${position.longitude}');

    // Reverse geocode (non-critical — OK if it fails)
    final locationName = await resolveLocationName(position);

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
          'accuracy': position.accuracy,
        }),
      ).timeout(const Duration(seconds: 12));

      // Parse saved_to_db from response to show if point was saved or filtered
      String dbStatus = '';
      try {
        final respData = jsonDecode(response.body);
        final saved = respData['saved_to_db'] == true;
        dbStatus = saved ? '💾 DB_SAVED' : '⏭ DB_FILTERED';
      } catch (_) {
        dbStatus = '❓ DB_UNKNOWN';
      }
      print('📍 [LOC-SEND] $dbStatus status=${response.statusCode} lat=${position.latitude} lng=${position.longitude} acc=${position.accuracy.toStringAsFixed(1)}m');

      final elapsedMs = DateTime.now().difference(sendStart).inMilliseconds;

      // 401 = token revoked (driver logged in on another device)
      // Stop sending GPS but DON'T delete the token — the API client
      // handles force-logout and navigates to login screen.
      // Deleting the token here caused "Session expired" on home screen
      // before the user could even see the logout prompt.
      if (response.statusCode == 401) {
        TrackingLogger.log('✗ 401    token revoked, stopping service');
        print('BackgroundLocationService: 401 Unauthorized — stopping GPS service.');
        await prefs.setBool(_serviceRunningKey, false);
        return false;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);

        if (data['status'] == false) {
          TrackingLogger.log('✗ stop   journey ended by backend');
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
        await prefs.setInt(
            'last_location_sent_at', DateTime.now().millisecondsSinceEpoch);
        TrackingLogger.log(
            '✓ sent   lat=${position.latitude.toStringAsFixed(6)} '
            'lng=${position.longitude.toStringAsFixed(6)} '
            'acc=${position.accuracy.toStringAsFixed(0)}m http=${response.statusCode} in ${elapsedMs}ms');

        // Show location name when geocode is for the current area.
        // resolveLocationName() returns lastResolvedLocationName on failure
        // (the cached old city). If the geocode anchor is > 300m away from
        // the current position the name is stale, so we show "Tracking
        // active..." instead of the wrong city name.
        //
        // NOTE: fixAge (DateTime.now() - position.timestamp) was removed.
        // On Android, position.timestamp reflects when the GPS hardware locked
        // the satellite signal, which can be 30–120 s behind DateTime.now()
        // even on a live stream. The old fixAge <= 30s guard was causing the
        // location name to never appear in the notification because almost
        // every fix failed the freshness check. isGeocodeForCurrentArea
        // already provides the same "don't show stale city" safety.
        lastSentPosition = position;
        lastSentAt = DateTime.now();
        // trackingNotificationContent() uses lastResolvedLocationName (which
        // resolveLocationName() already cleared if geocode failed + moved > 1km)
        // and appends the GPS age so the driver can see how fresh the fix is.
        updateNotification(trackingNotificationContent());

        service.invoke('locationUpdate', {
          'lat': position.latitude,
          'lng': position.longitude,
          'location_name': locationName,
          'timestamp': DateTime.now().toIso8601String(),
        });

        print('BackgroundLocationService: Location sent successfully.');
      } else {
        TrackingLogger.log(
            '✗ http=${response.statusCode} fails=$consecutiveFailures '
            'acc=${position.accuracy.toStringAsFixed(0)}m in ${elapsedMs}ms');
        print(
            'BackgroundLocationService: API error ${response.statusCode}');
        consecutiveFailures++;
        updateNotification('Server error, retrying...');
      }
    } on TimeoutException {
      TrackingLogger.log(
          '✗ timeout fails=${consecutiveFailures + 1} acc=${position.accuracy.toStringAsFixed(0)}m (12s http timeout)');
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
        // Flag for the watchdog (runs every 1 min) to restart the
        // position stream. Can't call startPositionStream directly from
        // here because it's declared later in _onStart's lexical scope.
        streamRestartRequested = true;
      }
    } catch (e) {
      TrackingLogger.log(
          '✗ neterr fails=${consecutiveFailures + 1} acc=${position.accuracy.toStringAsFixed(0)}m $e');
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
        // Same stream-restart flag as the timeout path — see above.
        streamRestartRequested = true;
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
    TrackingLogger.log('◉ stream start (attempt #$streamRestartCount)');
    print('BackgroundLocationService: Starting position stream '
        '(attempt #$streamRestartCount)');

    // Reset frozen-stream counters on every (re)start so a fresh stream
    // doesn't inherit stale counts from the previous subscription.
    lastRawStreamPosition = null;
    consecutiveSameStreamPositions = 0;

    // iOS REQUIRES AppleSettings with allowBackgroundLocationUpdates: true,
    // otherwise Core Location kills the stream the moment the screen locks
    // (or the app backgrounds). With it set, iOS keeps the stream alive in
    // background indefinitely as long as updates keep flowing — this is the
    // standard pattern used by every navigation app (Google Maps, Waze, etc).
    final LocationSettings locationSettings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.best,
            activityType: ActivityType.automotiveNavigation,
            distanceFilter: 0,
            // Critical: prevent iOS from auto-pausing the stream when it
            // thinks the user has stopped (red light, parking). Without
            // this, iOS silently pauses and never resumes.
            pauseLocationUpdatesAutomatically: false,
            // Critical: keeps the stream alive in background. Requires
            // `location` in UIBackgroundModes (Info.plist already has it)
            // and "Always Allow" location permission.
            allowBackgroundLocationUpdates: true,
            // Apple's required transparency: shows the blue status bar
            // while tracking in background. Hiding it can lead to App
            // Store rejection.
            showBackgroundLocationIndicator: true,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.best,
            intervalDuration: _movingUpdateInterval,
            distanceFilter: 0,
            // Do NOT use forceLocationManager here.
            //
            // forceLocationManager: true bypasses Google's FusedLocationProvider
            // (FLP) and forces Android's raw LocationManager. The difference matters
            // critically when the screen is locked:
            //
            //   • FLP runs inside Google Play Services, which holds a privileged
            //     PARTIAL_WAKE_LOCK and has Doze exemptions. A foreground service
            //     using FLP continues to receive location callbacks during Doze.
            //
            //   • Android LocationManager has NO such exemptions. When Doze deep
            //     mode kicks in (~30-40 min after screen lock + phone idle), the OS
            //     defers LocationManager requests entirely — the stream goes silent
            //     exactly matching the symptom the driver reported.
            //
            // Ghost-location protection (cell tower / WiFi jumps) is still provided
            // by the accuracy > 100m guard in shouldSendPosition(). FLP with
            // LocationAccuracy.best prefers GPS when available; non-GPS positions
            // (accuracy > 100m) are rejected before being sent to the backend.
          );

    positionSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) async {
        if (shouldStop) return;

        // ── Frozen-stream detection ──
        // Only mark the stream "alive" when the position is genuinely fresh
        // (moved > 2 m from the previous reading). OEM phones (Xiaomi, Realme,
        // Vivo) can keep the stream running but replay the same cached lat/lng
        // on every tick. If lastStreamPositionTime updated on every tick, the
        // watchdog would never fire — the stream looks healthy but is useless.
        final distFromLast = lastRawStreamPosition == null
            ? double.infinity
            : Geolocator.distanceBetween(
                lastRawStreamPosition!.latitude,
                lastRawStreamPosition!.longitude,
                position.latitude,
                position.longitude,
              );

        if (distFromLast > frozenPositionThresholdMeters) {
          // Fresh position — update watchdog timer and reset frozen counter
          lastStreamPositionTime = DateTime.now();
          consecutiveSameStreamPositions = 0;
        } else {
          // Same position as last tick
          consecutiveSameStreamPositions++;
          TrackingLogger.log(
              '⚠ same pos streak=$consecutiveSameStreamPositions '
              '(dist=${distFromLast.toStringAsFixed(1)}m)');

          if (consecutiveSameStreamPositions >= frozenStreamRestartThreshold) {
            // Stream is frozen — flag for watchdog to restart it.
            // Don't restart here directly (can't call startPositionStream
            // from inside its own listener without a forward-reference hack).
            TrackingLogger.log(
                '🔴 frozen stream detected after '
                '$consecutiveSameStreamPositions identical positions — '
                'requesting restart');
            print('BackgroundLocationService: FROZEN STREAM — '
                '$consecutiveSameStreamPositions identical positions, '
                'requesting stream restart');
            streamRestartRequested = true;
            consecutiveSameStreamPositions = 0;
          }
        }
        lastRawStreamPosition = position;

        try {
          final keepRunning = await sendPosition(position);
          if (!keepRunning) {
            shouldStop = true;
            positionSub?.cancel();
            watchdogTimer?.cancel();
            fallbackTimer?.cancel();
            dbCleanupTimer?.cancel();
            await releaseWakeLock();
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

    // Skip if the stream delivered a position recently (within _fallbackGuard = 90 s).
    // Reduced from the old 3-min guard so fallback fires within ~90 s of stream death
    // instead of waiting up to 3 min — this is the main fix for the 5-min gap.
    final timeSinceLastStream =
        DateTime.now().difference(lastStreamPositionTime);
    if (timeSinceLastStream < _fallbackGuard) {
      print('BackgroundLocationService: Fallback skipped — stream is alive '
          '(last ${timeSinceLastStream.inSeconds}s ago)');
      return;
    }

    TrackingLogger.log(
        '◉ fallback poll firing — stream silent for '
        '${timeSinceLastStream.inSeconds}s');
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
        // Use FLP (not forceAndroidLocationManager) so this call survives
        // Doze mode. Ghost locations are caught by the accuracy > 100m guard
        // in shouldSendPosition() — no need to force the raw LocationManager.
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
        // Reject stale positions older than 10 minutes
        if (pos != null) {
          final age = DateTime.now().difference(pos.timestamp);
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
          await releaseWakeLock();
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
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 15),
      );
    } catch (_) {
      firstPos = await Geolocator.getLastKnownPosition();
      if (firstPos != null) {
        final age = DateTime.now().difference(firstPos.timestamp);
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
        await releaseWakeLock();
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
        connectivitySub?.cancel();
        fallbackTimer?.cancel();
        connectivityCheckTimer?.cancel();
        dbCleanupTimer?.cancel();
        timer.cancel();
        await alertNotifications.cancel(_alertNotificationId);
        await releaseWakeLock();
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
          alertType: 'gps_off',
        );
      }
    } catch (_) {}

    // ── Battery low check (every 5 watchdog ticks ≈ every 5 min) ──
    if (watchdogTicks % 5 == 0) {
      try {
        final batteryLevel = await const MethodChannel('bestseeds/device_info')
            .invokeMethod<int>('getBatteryLevel');
        if (batteryLevel != null && batteryLevel <= 20) {
          TrackingLogger.log('🔋 battery low: $batteryLevel%');
          updateNotification('Battery Low — $batteryLevel%! Please charge now.');
          await showErrorAlert(
            title: 'Battery Low — $batteryLevel%!',
            body:
                'Driver battery is critically low. Please charge your phone to keep live tracking active.',
            alertType: 'battery_low',
          );
        }
      } catch (_) {}
    }

    // ── Location-not-sending check ──
    // GPS and internet are both up but the backend has not received a location
    // update for more than 10 minutes (consecutiveFailures >= 5 with isOnline).
    // This catches silent API failures, certificate errors, or a frozen service.
    if (isOnline && consecutiveFailures >= 5) {
      final sinceLastSend = lastSentAt == null
          ? const Duration(hours: 1)
          : DateTime.now().difference(lastSentAt!);
      if (sinceLastSend >= const Duration(minutes: 10)) {
        TrackingLogger.log(
            '📡 location_not_sending: ${sinceLastSend.inMinutes}m since last successful send');
        updateNotification(
            'Location not reaching server — ${sinceLastSend.inMinutes}m silent');
        await showErrorAlert(
          title: 'Location Not Updating!',
          body:
              'Your location has not reached the server for ${sinceLastSend.inMinutes} minutes. '
              'GPS and internet appear active — please restart the app if this persists.',
          alertType: 'location_not_sending',
        );
      }
    }

    final timeSinceLastPosition =
        DateTime.now().difference(lastStreamPositionTime);

    // Honour an explicit restart request from sendPosition() even if
    // the stream looks alive. Sustained API POST failures often mean
    // the stream is still ticking but positions are stale fallback
    // values (getLastKnownPosition), so a fresh subscription helps.
    if (streamRestartRequested) {
      TrackingLogger.log(
          '⟲ watchdog restart requested by sendPosition '
          '(fails=$consecutiveFailures)');
      print('BackgroundLocationService: WATCHDOG — stream restart requested by '
          'sendPosition (consecutiveFailures=$consecutiveFailures)');
      streamRestartRequested = false;
      updateNotification('Reconnecting GPS...');
      await startPositionStream();
      lastStreamPositionTime = DateTime.now();
    } else if (timeSinceLastPosition > _streamTimeout) {
      TrackingLogger.log(
          '⟲ watchdog stream silent for ${timeSinceLastPosition.inSeconds}s '
          '— restarting');
      print('BackgroundLocationService: WATCHDOG — No position received for '
          '${timeSinceLastPosition.inMinutes} minutes. Restarting stream...');
      updateNotification('Reconnecting GPS...');

      await startPositionStream();
      // Reset the timer
      lastStreamPositionTime = DateTime.now();
    } else {
      print('BackgroundLocationService: Watchdog OK — last position '
          '${timeSinceLastPosition.inSeconds}s ago.');
      updateNotification(trackingNotificationContent());
    }

    // ── WorkManager chain health check (every 30 min) ──
    // The active-capture chain is self-maintaining, but on aggressive OEMs
    // (Xiaomi MIUI, Realme, Vivo) it can be coalesced or silently dropped
    // during multi-day journeys without any error. Re-registering every
    // 30 min ensures the 2-min Doze-bypass backup never stays dead longer
    // than one watchdog window — critical for 5–10 day journeys.
    watchdogTicks++;
    if (watchdogTicks % 30 == 0) {
      try {
        await registerActiveCaptureTask();
        TrackingLogger.log('🔁 watchdog re-registered active-capture chain '
            '(tick=$watchdogTicks)');
        print('BackgroundLocationService: WATCHDOG — active-capture chain '
            're-registered at tick $watchdogTicks');
      } catch (e) {
        print('BackgroundLocationService: WATCHDOG — active-capture '
            're-register failed: $e');
      }
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
  // 6. CONNECTIVITY STREAM — instant reaction to network changes.
  //
  //    The periodic timer (every 30s) is too slow when the driver switches
  //    from mobile data to hotspot (or vice-versa). connectivity_plus fires
  //    immediately when any network interface changes, so we react within
  //    ~1 second instead of up to 90 seconds (30s timer × 3 failures).
  //
  //    On every change to a connected state:
  //      • reset failure counter so the next send isn't throttled
  //      • flush SQLite queue (points captured while offline)
  //      • restart the Geolocator stream — OEM phones (Xiaomi, Realme) can
  //        reset the GPS socket when the network interface changes, causing
  //        the stream to silently stop delivering positions
  //      • fire an immediate fallback poll to send a fresh position NOW
  // ==========================================================================
  connectivitySub = Connectivity().onConnectivityChanged.listen(
    (List<ConnectivityResult> results) async {
      if (shouldStop) return;

      final hasNetwork = results.any((r) =>
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet);

      TrackingLogger.log(
          '📶 connectivity changed → ${results.map((r) => r.name).join(",")}');
      print('BackgroundLocationService: Network changed → $results');

      if (hasNetwork) {
        // Network became available (hotspot connected, data restored, etc.)
        isOnline = true;
        consecutiveFailures = 0;
        streamRestartRequested = false;
        await dismissErrorAlert();
        updateNotification('Network connected — syncing location...');

        // Flush any points queued while we were offline
        await flushLocationQueue();

        // Restart GPS stream — network change can silently kill it on OEMs.
        // The stream itself will emit a fresh position within ~10s.
        // (fallbackPoll is NOT called here — it always skips immediately after
        // a stream restart because lastStreamPositionTime is reset to now.)
        await startPositionStream();
        lastStreamPositionTime = DateTime.now();
      }
    },
  );

  // ==========================================================================
  // 7. PERIODIC SQLITE CLEANUP — delete old sent records every hour
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
        desiredAccuracy: LocationAccuracy.best,
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

    final locationName = await reverseGeocodeHttp(
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
/// Public so the WorkManager isolate can call it directly.
///
/// WHY NO result_type FILTER:
/// Using result_type=sublocality|locality forces Google to return only results
/// matching those administrative types. In rural/bridge areas this causes
/// Google to pick the nearest administrative "sublocality" owner — which can
/// be a village several km away from the actual GPS point (e.g. returning
/// "Komaragiri" when the driver is at Annampalli/Muramalla Bridge).
///
/// Without result_type, Google returns all result types ordered by precision
/// (street-level first). We then scan ALL results' address_components and
/// collect the first locality, sublocality, and state values found.
/// Scanning all results (not just results[0]) means a street-address result
/// that has no locality component still contributes — the locality we want
/// usually appears in components of one of the first 2-3 results.
///
/// Priority: sublocality (neighbourhood) > locality (city/town) > state only.
///
/// Output format:
///   Urban  — "Madhapur, Hyderabad"       (sublocality + locality)
///   Rural  — "Bhimanapalli, Andhra Pradesh" (locality + state, no sublocality)
///   Bridge — "Annampalli, Andhra Pradesh" (locality or sublocality + state)
Future<String?> reverseGeocodeHttp(double lat, double lng) async {
  try {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json'
      '?latlng=$lat,$lng'
      '&language=en'
      '&key=$_googleApiKey',
    );

    // 6s timeout — background isolate on mobile networks needs more headroom.
    // Was 3s but caused frequent silent failures, keeping stale city names.
    final response = await http.get(url).timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body);
    if (data['status'] != 'OK') return null;

    final results = data['results'] as List;
    if (results.isEmpty) return null;

    String? locality;
    String? subLocality;
    String? adminArea;
    String? village; // administrative_area_level_3/4/5 — remote village name

    // Scan up to 5 results to collect sublocality, locality, state, and village.
    // Stop only once we have BOTH sublocality and locality — a single result
    // usually carries all three in its address_components, but some results
    // (e.g. highway/POI) omit locality, so keep scanning until we have both.
    for (var result in results.take(5)) {
      for (var component in result['address_components']) {
        final types = (component['types'] as List).cast<String>();
        if (types.contains('locality')) {
          locality ??= component['long_name'];
        }
        if (types.contains('sublocality') ||
            types.contains('sublocality_level_1')) {
          subLocality ??= component['long_name'];
        }
        if (types.contains('administrative_area_level_1')) {
          adminArea ??= component['long_name'];
        }
        // Remote villages often appear only at level 3/4/5 with no locality.
        if (types.contains('administrative_area_level_3') ||
            types.contains('administrative_area_level_4') ||
            types.contains('administrative_area_level_5')) {
          village ??= component['long_name'];
        }
      }
      // Stop once we have everything we need
      if (locality != null && subLocality != null && adminArea != null) break;
    }

    // ── Build the display string ─────────────────────────────────────
    // Urban  (has sublocality): "Madhapur, Hyderabad"
    // Rural  (no sublocality):  "Bhimanapalli, Andhra Pradesh"
    // Remote village (no locality, no sublocality): "Ananthagiri, Andhra Pradesh"
    if (subLocality != null) {
      // Urban: neighbourhood + city (or state if city unknown)
      final context = locality ?? adminArea;
      return [subLocality, context]
          .where((e) => e != null && e.isNotEmpty)
          .join(', ');
    } else {
      // Rural / remote village / highway: most-specific name + state
      // Prefer locality; fall back to village name from deeper admin levels.
      final place = locality ?? village;
      if (place == null && adminArea == null) return null;
      return [place, adminArea]
          .where((e) => e != null && e.isNotEmpty)
          .join(', ');
    }
  } catch (e) {
    print('Background reverse geocoding failed: $e');
    return null;
  }
}

