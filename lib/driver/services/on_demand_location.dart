import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'background_location_service.dart' show reverseGeocodeHttp;

const String _odBaseUrl = 'https://aqua.bestseed.in/api/';
const String _odLocationEndpoint = 'driver/location/update';
const String _odTokenKey = 'driver_token';
const String _odServiceRunningKey = 'bg_location_service_running';

/// Captures a single fresh GPS fix and POSTs it to the backend, then
/// returns. Used as the driver-side handler for `type: "request_location"`
/// FCM data messages — the vendor / customer screen triggers this so the
/// next location they see is no older than the round-trip time.
///
/// Safe to call from both the main isolate (foreground FCM handler) and
/// the background isolate (`_firebaseMessagingBackgroundHandler`). It
/// does not touch any class-level state — every dependency is reloaded
/// from SharedPreferences.
///
/// Returns true if a position reached the backend, false otherwise. Errors
/// are swallowed (network failure, GPS timeout, no token) because there is
/// no UI to surface them to — the next regular stream tick will retry.
Future<bool> captureAndPostOnDemandLocation() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Only respond while a journey is active. If the driver isn't logged in
    // or there's no live journey, silently ignore — the vendor screen will
    // fall back to whatever last-known position the backend already has.
    if (!(prefs.getBool(_odServiceRunningKey) ?? false)) {
      print('📍 [ON-DEMAND] skip — no active journey');
      return false;
    }
    final token = prefs.getString(_odTokenKey);
    if (token == null || token.isEmpty) {
      print('📍 [ON-DEMAND] skip — no driver token');
      return false;
    }

    // Capture a fresh GPS fix. 10 s timeout matches the WorkManager heartbeat;
    // longer than that and the vendor screen has likely given up waiting.
    Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 10),
      );
    } catch (e) {
      // Fall back to last-known position if the GPS fix times out — better
      // than nothing for the vendor screen.
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) {
        print('📍 [ON-DEMAND] no GPS available — $e');
        return false;
      }
      pos = last;
    }

    // Reverse geocode is best-effort. The vendor screen renders fine
    // without a place name; coords are what matter.
    String? locationName;
    try {
      locationName = await reverseGeocodeHttp(pos.latitude, pos.longitude);
    } catch (_) {}

    final response = await http
        .post(
          Uri.parse('$_odBaseUrl$_odLocationEndpoint'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'lat': pos.latitude,
            'lng': pos.longitude,
            'location_name': locationName ?? 'On-demand fix',
            'accuracy': pos.accuracy,
            // Marker so the backend can distinguish on-demand pushes from
            // the regular periodic stream if it ever needs to (analytics,
            // dedup, etc.). Optional — backend can ignore.
            'source': 'on_demand',
          }),
        )
        .timeout(const Duration(seconds: 12));

    final ok = response.statusCode >= 200 && response.statusCode < 300;
    print('📍 [ON-DEMAND] http=${response.statusCode} '
        'lat=${pos.latitude.toStringAsFixed(6)} '
        'lng=${pos.longitude.toStringAsFixed(6)} '
        'acc=${pos.accuracy.toStringAsFixed(0)}m');
    return ok;
  } catch (e) {
    // Background isolate has no UI; just log and let the next stream tick
    // or WorkManager heartbeat recover.
    print('📍 [ON-DEMAND] error: $e');
    return false;
  } finally {
    // On iOS this runs in the main isolate; allow the OS to suspend us
    // again now that we've posted.
    if (Platform.isIOS) {
      // no-op marker for clarity; suspension is implicit.
    }
  }
}
