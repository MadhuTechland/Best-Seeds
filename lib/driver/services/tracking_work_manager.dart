import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'background_location_service.dart';
import 'tracking_database.dart';

// Must match the constants in background_location_service.dart
// const String _wmBaseUrl = 'http://192.168.0.104:8000/api/';
// const String _wmBaseUrl = 'http://192.168.29.111:8000/api/';
const String _wmBaseUrl = 'https://bestseed.in/api/';
const String _wmLocationEndpoint = 'driver/location/update';
const String _wmTrackingAlertEndpoint = 'driver/tracking-alert';
const String _wmTokenKey = 'driver_token';
const String _wmServiceRunningKey = 'bg_location_service_running';

// WorkManager task identifiers
const String guardianTaskName = 'bestseeds_tracking_guardian';
const String guardianTaskTag = 'tracking_guardian';

/// Initialize WorkManager and register the periodic guardian task.
/// Call once in main() after WidgetsFlutterBinding.ensureInitialized().
Future<void> initializeWorkManager() async {
  await Workmanager().initialize(
    _workManagerCallbackDispatcher,
    isInDebugMode: false,
  );
}

/// Register the periodic guardian task.
/// Call this when a journey starts (after BackgroundLocationService.start()).
Future<void> registerGuardianTask() async {
  await Workmanager().registerPeriodicTask(
    guardianTaskName,
    guardianTaskName,
    tag: guardianTaskTag,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingWorkPolicy.replace,
    constraints: Constraints(
      networkType: NetworkType.not_required,
      requiresBatteryNotLow: false,
      requiresCharging: false,
      requiresDeviceIdle: false,
      requiresStorageNotLow: false,
    ),
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 5),
  );
  print('WorkManager: Guardian task registered (every 15 min)');
}

/// Cancel the guardian task when the journey ends.
Future<void> cancelGuardianTask() async {
  await Workmanager().cancelByTag(guardianTaskTag);
  print('WorkManager: Guardian task cancelled');
}

/// Top-level callback dispatcher for WorkManager.
/// Runs in a SEPARATE isolate — must be a top-level function.
@pragma('vm:entry-point')
void _workManagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();

      print('WorkManager[$taskName]: Guardian check starting...');

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final shouldRun = prefs.getBool(_wmServiceRunningKey) ?? false;

      if (!shouldRun) {
        print('WorkManager[$taskName]: Service flag is false, journey not active. Skipping.');
        return true;
      }

      // Check if the foreground service is running
      final isServiceRunning = await BackgroundLocationService.isRunning();

      if (!isServiceRunning) {
        // FOREGROUND SERVICE IS DEAD — restart it
        print('WorkManager[$taskName]: Foreground service is DEAD! Restarting...');

        await BackgroundLocationService.restartIfNeeded();

        // Wait a moment for it to start
        await Future.delayed(const Duration(seconds: 3));

        final nowRunning = await BackgroundLocationService.isRunning();
        print('WorkManager[$taskName]: Restart result: ${nowRunning ? "SUCCESS" : "FAILED"}');

        if (!nowRunning) {
          // Second attempt
          print('WorkManager[$taskName]: Second restart attempt...');
          await BackgroundLocationService.start();
          await Future.delayed(const Duration(seconds: 3));
        }

        // Send a heartbeat location from SQLite queue or GPS
        await _sendHeartbeatLocation(prefs);

        // Alert backend that tracking had stopped and was restarted
        await _sendTrackingAlert(prefs, 'tracking_restarted');
      } else {
        print('WorkManager[$taskName]: Foreground service is running OK.');

        // Even if service is running, send a heartbeat to confirm we're alive
        // This catches cases where the service is "running" but stuck
        await _sendHeartbeatLocation(prefs);
      }

      // Cleanup old SQLite entries
      await TrackingDatabase.cleanup();

      return true;
    } catch (e) {
      print('WorkManager[$taskName]: Error: $e');
      return false; // Will be retried by WorkManager
    }
  });
}

/// Send the last known location as a heartbeat.
/// Uses SQLite queue first, falls back to GPS.
Future<void> _sendHeartbeatLocation(SharedPreferences prefs) async {
  final token = prefs.getString(_wmTokenKey);
  if (token == null || token.isEmpty) return;

  try {
    double? lat;
    double? lng;
    String locationName = 'Heartbeat - live location';

    // Try SQLite queue first (fastest, no GPS needed)
    final lastKnown = await TrackingDatabase.getLastKnownLocation();
    if (lastKnown != null) {
      lat = lastKnown['lat'] as double?;
      lng = lastKnown['lng'] as double?;
      locationName = (lastKnown['location_name'] as String?) ?? locationName;
    }

    // If no recent SQLite data, try GPS
    if (lat == null || lng == null) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );
        lat = pos.latitude;
        lng = pos.longitude;
        locationName = 'Heartbeat - fresh GPS';
      } catch (_) {
        final lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null) {
          lat = lastPos.latitude;
          lng = lastPos.longitude;
          locationName = 'Heartbeat - last known GPS';
        }
      }
    }

    if (lat == null || lng == null) {
      print('WorkManager: No location available for heartbeat');
      return;
    }

    // Also save to SQLite queue
    await TrackingDatabase.insert(lat: lat, lng: lng, locationName: locationName);

    // Send to server
    final response = await http.post(
      Uri.parse('$_wmBaseUrl$_wmLocationEndpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'lat': lat,
        'lng': lng,
        'location_name': locationName,
      }),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      await TrackingDatabase.markAllSent();
      print('WorkManager: Heartbeat sent successfully ($lat, $lng)');
    }
  } catch (e) {
    print('WorkManager: Heartbeat failed: $e');
  }
}

/// Send a tracking alert to the backend (notifies vendor).
Future<void> _sendTrackingAlert(SharedPreferences prefs, String issueType) async {
  final token = prefs.getString(_wmTokenKey);
  if (token == null || token.isEmpty) return;

  try {
    await http.post(
      Uri.parse('$_wmBaseUrl$_wmTrackingAlertEndpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'issue_type': issueType}),
    ).timeout(const Duration(seconds: 10));

    print('WorkManager: Tracking alert sent -> $issueType');
  } catch (e) {
    print('WorkManager: Alert failed: $e');
  }
}
