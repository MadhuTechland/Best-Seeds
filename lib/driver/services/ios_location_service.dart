import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'active_journey_prefs.dart';
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
  // True while start() is mid-flight. Without this, two concurrent callers
  // (e.g. _checkActiveJourney + _ensureTrackingForLiveJourney both firing
  // on app open) can each pass the `_subscription == null` guard before
  // either has assigned _subscription, ending up with TWO journey-start
  // banner notifications and possibly two stream subscriptions.
  static bool _starting = false;
  static Timer? _watchdogTimer;
  static DateTime? _lastSentAt;
  static Position? _lastSentPosition;
  static String? _lastLocationName;
  static DateTime? _lastGeocodeAt;
  static Position? _lastGeocodePosition;
  // Last location name shown in the persistent tracking notification.
  // The notification is only re-posted when the resolved place name
  // actually changes (driver enters a new locality), keeping the banner
  // flashes that iOS fires on each update to ~1 per stop instead of
  // ~1 per minute. The Live Activity tile handles per-tick updates.
  static String? _lastNotificationLocationName;

  static final _notif = FlutterLocalNotificationsPlugin();

  static bool get isActive => _subscription != null;

  /// Show the persistent tracking notification ONCE at journey start so the
  /// driver knows tracking is active. The Live Activity tile handles all
  /// subsequent live updates (location name, GPS age) — re-posting this
  /// notification under the same ID causes iOS to flash a banner every
  /// time even with presentAlert:false, so we don't refresh it after start.
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

  /// Build the LiveActivity payload for the current GPS position by reading
  /// the active journey (pickup + next-drop) out of SharedPreferences and
  /// computing the progress fraction from coordinates. Returns a map ready
  /// to be passed to [LiveActivityService.start] / [LiveActivityService.update].
  ///
  /// Returns an empty map (no route fields) when no live journey is set —
  /// the Swift UI then falls back to the simpler "Live tracking" layout.
  static Future<_LiveActivityRouteData> _routeDataForLiveActivity(
    Position currentPosition,
  ) async {
    final journey = await ActiveJourneyPrefs.read();
    if (!journey.hasPickup || !journey.hasDrop) {
      return _LiveActivityRouteData.empty(nextStop: journey.nextStopLabel);
    }

    // Distance pickup → current
    final covered = Geolocator.distanceBetween(
      journey.pickupLat!,
      journey.pickupLng!,
      currentPosition.latitude,
      currentPosition.longitude,
    );
    // Straight-line distance current → drop (good enough for a progress
    // bar; real road distance would need a routing API call on every fix).
    final remaining = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      journey.dropLat!,
      journey.dropLng!,
    );
    final total = covered + remaining;
    final progress = total > 0 ? (covered / total).clamp(0.0, 1.0) : 0.0;

    // Format remaining distance for the ETA chip:
    //   < 1 km  → "850 m"
    //   ≥ 1 km  → "5.2 km"
    String etaText;
    if (remaining < 50) {
      etaText = 'Arriving';
    } else if (remaining < 1000) {
      etaText = '${remaining.toStringAsFixed(0)} m';
    } else {
      etaText = '${(remaining / 1000).toStringAsFixed(1)} km';
    }

    // Place each intermediate stop on the bar by its distance from pickup
    // as a fraction of pickup→drop total. Skips stops with missing coords.
    final pickupToDropMeters = Geolocator.distanceBetween(
      journey.pickupLat!,
      journey.pickupLng!,
      journey.dropLat!,
      journey.dropLng!,
    );
    final stops = <LiveActivityStop>[];
    if (pickupToDropMeters > 0) {
      // Skip any stop that's effectively at the final-drop coordinates —
      // that one is already drawn as the destination pin endpoint, so a
      // dot on top of it just looks like a smudge. 50 m tolerance.
      bool isFinalDrop(ActiveJourneyStop s) {
        final d = Geolocator.distanceBetween(
          s.lat,
          s.lng,
          journey.dropLat!,
          journey.dropLng!,
        );
        return d < 50;
      }

      for (final s in journey.stops) {
        if (isFinalDrop(s)) continue;
        final distFromPickup = Geolocator.distanceBetween(
          journey.pickupLat!,
          journey.pickupLng!,
          s.lat,
          s.lng,
        );
        final stopProgress =
            (distFromPickup / pickupToDropMeters).clamp(0.0, 1.0);
        stops.add(LiveActivityStop(
          name: s.name,
          progress: stopProgress,
          status: s.status,
        ));
      }
    }

    return _LiveActivityRouteData(
      pickupName: journey.pickupName,
      dropName: journey.dropName,
      progress: progress,
      etaText: etaText,
      nextStop: journey.nextStopLabel,
      stops: stops,
    );
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
    // Hardened against concurrent callers. The outer guard catches the
    // common case (already running). The _starting flag closes the race
    // window between "passed the _subscription==null check" and "_subscription
    // assigned" — without it, two awaits running in parallel would BOTH
    // post the journey-start banner and arm two Geolocator streams.
    if (_subscription != null || _starting) return;
    _starting = true;
    try {
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

      // Start the Dart watchdog. Job: if the position stream has been silent
      // for > _streamSilenceThreshold, force a getCurrentPosition() poll so
      // we recover from iOS quietly pausing the stream on long screen-locks.
      //
      // The watchdog no longer touches the tracking notification — the Live
      // Activity tile is the live status indicator now. Re-posting the
      // notification every minute (even with presentAlert:false) caused iOS
      // to flash a banner on every refresh while the app was backgrounded.
      _watchdogTimer?.cancel();
      _watchdogTimer = Timer.periodic(_watchdogInterval, (_) => _onWatchdogTick());

      print('IosLocationService: tracking started in main isolate');
    } finally {
      _starting = false;
    }
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
    _lastNotificationLocationName = null;
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
        // Push the fresh location into the Live Activity tile so the
        // lock-screen + Dynamic Island stay current. Also recompute the
        // route bar (progress along pickup→drop) from the active-journey
        // prefs so the truck icon slides along the bar as the driver
        // moves; falls back to a simpler layout if no live journey is set.
        final route = await _routeDataForLiveActivity(position);
        await LiveActivityService.update(
          latitude: position.latitude,
          longitude: position.longitude,
          locationName: locationName,
          lastSentAt: now,
          nextStop: route.nextStop,
          pickupName: route.pickupName,
          dropName: route.dropName,
          progress: route.progress,
          etaText: route.etaText,
          stops: route.stops,
        );
        // Update the persistent tracking notification ONLY when the
        // resolved place name actually changes (driver entered a new
        // locality). This keeps the Notification Center entry meaningful
        // for non-Dynamic-Island devices / iOS < 16.1 fallback, while
        // limiting the banner flashes iOS fires on each update from
        // ~1/min to ~1/stop. Skip the placeholder name so an unresolved
        // geocode doesn't show a meaningless "Live vehicle location".
        if (locationName.isNotEmpty &&
            locationName != 'Live vehicle location' &&
            locationName != _lastNotificationLocationName) {
          _lastNotificationLocationName = locationName;
          await _showTrackingNotification(locationName, banner: false);
        }
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

/// Snapshot of route-bar data passed into a single Live Activity update.
/// Held as a value type so the call sites in `_onPosition` and `start()`
/// can compute it once and pass the same fields to both `start` and
/// `update` without recomputing or re-reading prefs.
class _LiveActivityRouteData {
  _LiveActivityRouteData({
    this.pickupName,
    this.dropName,
    this.progress = 0,
    this.etaText,
    this.nextStop,
    this.stops = const [],
  });

  factory _LiveActivityRouteData.empty({String? nextStop}) =>
      _LiveActivityRouteData(nextStop: nextStop);

  final String? pickupName;
  final String? dropName;
  final double progress;
  final String? etaText;
  final String? nextStop;
  final List<LiveActivityStop> stops;
}
