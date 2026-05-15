import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'background_location_service.dart' show reverseGeocodeHttp;
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

  static StreamSubscription<Position>? _subscription;
  static DateTime? _lastSentAt;
  static Position? _lastSentPosition;
  static String? _lastLocationName;
  static DateTime? _lastGeocodeAt;
  static Position? _lastGeocodePosition;

  static final _notif = FlutterLocalNotificationsPlugin();

  static bool get isActive => _subscription != null;

  static Future<void> _showTrackingNotification(String body, {bool banner = false}) async {
    await _notif.show(
      _iosTrackingNotifId,
      'Bestseed — Delivering',
      body,
      NotificationDetails(
        iOS: DarwinNotificationDetails(
          presentAlert: banner, // only show banner on journey start
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
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

    print('IosLocationService: tracking started in main isolate');
  }

  static Future<void> stop() async {
    try {
      await _watchdog.invokeMethod('stopWatchdog');
    } catch (_) {}
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

  static Future<void> _onPosition(Position position) async {
    // Reject cell-tower / WiFi positions (accuracy > 100m = not real GPS)
    if (position.accuracy > 100) return;

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
        // Token revoked — stop immediately
        await prefs.setBool(_iosServiceRunningKey, false);
        await stop();
        return;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        if (data['status'] == false) {
          // Backend ended the journey
          await prefs.setBool(_iosServiceRunningKey, false);
          await stop();
          return;
        }
        _lastSentAt = now;
        _lastSentPosition = position;
        await TrackingDatabase.markAllSent();
        print('IosLocationService: ✓ '
            '${position.latitude.toStringAsFixed(6)}, '
            '${position.longitude.toStringAsFixed(6)} → $locationName');
      }
    } catch (e) {
      print('IosLocationService: send error: $e');
    }
  }
}
