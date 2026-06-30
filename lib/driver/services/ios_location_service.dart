import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'background_location_service.dart' show reverseGeocodeHttp;
import 'live_activity_service.dart';
import 'tracking_database.dart';

const int _iosTrackingNotifId = 887;

const String _iosBaseUrl = 'https://aqua.bestseed.in/api/';
const String _iosTokenKey = 'driver_token';
const String _iosServiceRunningKey = 'bg_location_service_running';

/// iOS-specific location tracking that runs the Geolocator stream in the
/// MAIN Flutter isolate (called directly by BackgroundLocationService).
///
/// Why this exists: flutter_background_service on iOS creates a secondary
/// FlutterEngine. CLLocationManager inside a secondary engine does NOT receive
/// background location callbacks — iOS Core Location only delivers them to the
/// primary app's CLLocationManager. Starting the stream here (main isolate,
/// called from BackgroundLocationService.start()) means iOS keeps the stream
/// alive via the "location" UIBackgroundMode and "Always Allow" permission.
class IosLocationService {
  IosLocationService._();

  static const _watchdog = MethodChannel('com.bestseed/location_watchdog');

  // Watchdog cadence. Mirrors the Android stream watchdog: tick every 60 s,
  // force a getCurrentPosition() poll when the stream has been silent for
  // longer than _streamSilenceThreshold. iOS can quietly pause the stream
  // on long screen-locks even with pauseLocationUpdatesAutomatically: false,
  // typically after the vehicle is stationary for tens of minutes.
  static const Duration _watchdogInterval = Duration(seconds: 60);
  static const Duration _streamSilenceThreshold = Duration(seconds: 90);

  static StreamSubscription<Position>? _subscription;
  static Timer? _watchdogTimer;
  static DateTime? _lastSentAt;
  static Position? _lastSentPosition;
  static String? _lastLocationName;
  static DateTime? _lastGeocodeAt;
  static Position? _lastGeocodePosition;

  static final _notif = FlutterLocalNotificationsPlugin();

  static bool get isActive => _subscription != null;

  /// Build the notification body that mirrors Android's format:
  ///   `<place name> • GPS just now`
  ///   `<place name> • GPS 5m ago`
  /// Falls back to a neutral string when no position has been sent yet.
  static String _trackingNotificationBody() {
    final loc = (_lastLocationName != null && _lastLocationName!.trim().isNotEmpty)
        ? _lastLocationName!
        : 'Tracking active';
    if (_lastSentAt == null) return '$loc • waiting for GPS';
    final age = DateTime.now().difference(_lastSentAt!);
    if (age.inSeconds < 90) return '$loc • GPS just now';
    if (age.inMinutes < 60) return '$loc • GPS ${age.inMinutes}m ago';
    return '$loc • GPS ${age.inHours}h ago';
  }

  /// Re-post the persistent tracking notification under the same ID so iOS
  /// updates the existing entry in Notification Center instead of stacking
  /// a new one. `banner = true` only at journey start; subsequent updates
  /// are silent (no alert/sound) so the driver isn't interrupted on every
  /// position fix.
  static Future<void> _showTrackingNotification(String body, {bool banner = false}) async {
    await _notif.show(
      _iosTrackingNotifId,
      'Bestseed — Delivering',
      body,
      NotificationDetails(
        iOS: DarwinNotificationDetails(
          presentAlert: banner,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
  }

  /// Silent notification refresh — same ID, no banner. Use after every
  /// successful send (to show new location) and from the watchdog (so the
  /// "GPS Xm ago" age keeps ticking and the driver can see the service is
  /// alive even when the vehicle hasn't moved).
  static Future<void> _refreshTrackingNotification() async {
    await _showTrackingNotification(_trackingNotificationBody(), banner: false);
  }

  /// Best-effort driver name read from SharedPreferences. Used only as a
  /// label inside the Live Activity tile; falls back to a generic string
  /// if the JSON isn't present (e.g. on first launch before login).
  static Future<String> _driverNameFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('driver');
      if (raw == null) return 'Bestseed Driver';
      final data = jsonDecode(raw);
      final name = (data is Map ? data['name'] : null) as String?;
      if (name == null || name.trim().isEmpty) return 'Bestseed Driver';
      return name;
    } catch (_) {
      return 'Bestseed Driver';
    }
  }

  static Future<void> start() async {
    if (_subscription != null) return;

    await _notif.initialize(const InitializationSettings(
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ));

    await _showTrackingNotification('Tracking your delivery journey...', banner: true);

    // Kick off the Live Activity tile. Defaults are placeholders — the first
    // successful position send will overwrite them with the real coords +
    // reverse-geocoded place name. No-op on iOS < 16.1 / Android.
    final driverName = await _driverNameFromPrefs();
    await LiveActivityService.start(
      journeyId: DateTime.now().millisecondsSinceEpoch.toString(),
      driverName: driverName,
      latitude: 0,
      longitude: 0,
      locationName: 'Starting tracking…',
    );

    _subscription = Geolocator.getPositionStream(
      locationSettings: AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      ),
    ).listen(
      _onPosition,
      onError: (Object e) => print('IosLocationService: stream error: $e'),
      cancelOnError: false,
    );

    // Tell AppDelegate to start native significant-location-changes watchdog
    // so iOS can relaunch the app and post locations if it gets terminated.
    try {
      await _watchdog.invokeMethod('startWatchdog');
    } catch (_) {}

    // Start the Dart watchdog. Two jobs:
    //   1. If the position stream has been silent for > _streamSilenceThreshold,
    //      force a getCurrentPosition() poll so we recover from iOS quietly
    //      pausing the stream on long screen-locks.
    //   2. Refresh the persistent tracking notification body every tick so
    //      "GPS Xm ago" keeps advancing — proves to the driver that the
    //      service is alive even when the vehicle is stationary.
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) => _onWatchdogTick());

    print('IosLocationService: tracking started in main isolate');
  }

  static Future<void> stop() async {
    try {
      await _watchdog.invokeMethod('stopWatchdog');
    } catch (_) {}
    await LiveActivityService.end();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    await _notif.cancel(_iosTrackingNotifId);
    await _subscription?.cancel();
    _subscription = null;
    _lastSentAt = null;
    _lastSentPosition = null;
    _lastLocationName = null;
    _lastGeocodeAt = null;
    _lastGeocodePosition = null;
    print('IosLocationService: stopped');
  }

  /// Watchdog tick — runs every [_watchdogInterval] while tracking is active.
  static Future<void> _onWatchdogTick() async {
    if (_subscription == null) {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      return;
    }

    final silence = _lastSentAt == null
        ? null
        : DateTime.now().difference(_lastSentAt!);

    if (silence == null || silence > _streamSilenceThreshold) {
      // Stream went quiet (or never fired). Force a one-off poll —
      // getCurrentPosition() routes through the same CLLocationManager and
      // wakes the stream back up on most iOS quiet-pause scenarios.
      print('📍 [iOS-LOC] Watchdog: stream silent for '
          '${silence?.inSeconds ?? "∞"}s — forcing getCurrentPosition()');
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
          timeLimit: const Duration(seconds: 15),
        );
        await _onPosition(pos);
      } catch (e) {
        print('📍 [iOS-LOC] Watchdog poll failed: $e');
      }
    }

    // Always refresh the notification age so the driver sees the service
    // is alive (e.g. "Madhapur • GPS 3m ago" instead of stale text).
    await _refreshTrackingNotification();
  }

  static Future<void> _onPosition(Position position) async {
    // Reject cell-tower / WiFi positions (accuracy > 100m = not real GPS)
    if (position.accuracy > 100) {
      print('📍 [iOS-LOC] SKIP — poor accuracy ${position.accuracy.toStringAsFixed(0)}m '
          'lat=${position.latitude.toStringAsFixed(6)} lng=${position.longitude.toStringAsFixed(6)}');
      return;
    }

    final now = DateTime.now();

    // Rate limiting: skip if moved < 10m within 15 seconds of last send
    if (_lastSentPosition != null && _lastSentAt != null) {
      final moved = Geolocator.distanceBetween(
        _lastSentPosition!.latitude,
        _lastSentPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      if (moved < 10 && now.difference(_lastSentAt!) < const Duration(seconds: 15)) {
        print('📍 [iOS-LOC] SKIP — moved ${moved.toStringAsFixed(1)}m < 10m in ${now.difference(_lastSentAt!).inSeconds}s');
        return;
      }
    }

    // Check SharedPreferences stop flag
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (!(prefs.getBool(_iosServiceRunningKey) ?? false)) {
      await stop();
      return;
    }

    final token = prefs.getString(_iosTokenKey);
    if (token == null || token.isEmpty) {
      await stop();
      return;
    }

    // Reverse geocode with 3-min / 300-m cache
    String locationName = _lastLocationName ?? 'Live vehicle location';
    final needsGeocode = _lastGeocodePosition == null ||
        _lastGeocodeAt == null ||
        now.difference(_lastGeocodeAt!) > const Duration(minutes: 3) ||
        Geolocator.distanceBetween(
              _lastGeocodePosition!.latitude,
              _lastGeocodePosition!.longitude,
              position.latitude,
              position.longitude,
            ) >
            300;

    if (needsGeocode) {
      try {
        final name = await reverseGeocodeHttp(position.latitude, position.longitude);
        if (name != null && name.isNotEmpty) {
          locationName = name;
          _lastLocationName = name;
          _lastGeocodeAt = now;
          _lastGeocodePosition = position;
        }
      } catch (_) {}
    }

    // Persist to SQLite (crash-safe queue)
    try {
      await TrackingDatabase.insert(
        lat: position.latitude,
        lng: position.longitude,
        locationName: locationName,
      );
    } catch (_) {}

    // POST to backend
    try {
      final response = await http
          .post(
            Uri.parse('${_iosBaseUrl}driver/location/update'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'lat': position.latitude,
              'lng': position.longitude,
              'location_name': locationName,
              'accuracy': position.accuracy,
            }),
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 401) {
        // Token revoked (driver logged in elsewhere) — stop immediately.
        print('📍 [iOS-LOC] ❌ 401 — token revoked, stopping');
        await prefs.setBool(_iosServiceRunningKey, false);
        await stop();
        return;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        if (data['status'] == false) {
          print('📍 [iOS-LOC] ❌ journey ended by backend');
          await prefs.setBool(_iosServiceRunningKey, false);
          await stop();
          return;
        }
        _lastSentAt = now;
        _lastSentPosition = position;
        await TrackingDatabase.markAllSent();
        // Refresh the persistent notification so the driver sees the
        // current location + "GPS just now" instead of the stale "Tracking
        // your delivery journey..." text from journey start.
        await _refreshTrackingNotification();
        // Push the same fresh location into the Live Activity so the
        // lock-screen + Dynamic Island tile updates in lock-step with the
        // notification (and stays fresh after a swipe-kill SLC wakeup).
        await LiveActivityService.update(
          latitude: position.latitude,
          longitude: position.longitude,
          locationName: locationName,
          lastSentAt: now,
        );
        print('📍 [iOS-LOC] ✅ SENT lat=${position.latitude.toStringAsFixed(6)} '
            'lng=${position.longitude.toStringAsFixed(6)} acc=${position.accuracy.toStringAsFixed(0)}m → $locationName');
      } else {
        print('📍 [iOS-LOC] ❌ HTTP ${response.statusCode} lat=${position.latitude.toStringAsFixed(6)} '
            'lng=${position.longitude.toStringAsFixed(6)}');
      }
    } catch (e) {
      print('📍 [iOS-LOC] ❌ send error: $e lat=${position.latitude.toStringAsFixed(6)} '
          'lng=${position.longitude.toStringAsFixed(6)}');
    }
  }
}
