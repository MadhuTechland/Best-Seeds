import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'background_location_service.dart';
import 'tracking_database.dart';
import 'tracking_logger.dart';

// Must match the constants in background_location_service.dart
// const String _wmBaseUrl = 'http://192.168.0.104:8000/api/';
// const String _wmBaseUrl = 'http://192.168.29.111:8000/api/';
const String _wmBaseUrl = 'https://aqua.bestseed.in/api/';
const String _wmLocationEndpoint = 'driver/location/update';
const String _wmTrackingAlertEndpoint = 'driver/tracking-alert';
const String _wmTokenKey = 'driver_token';
const String _wmServiceRunningKey = 'bg_location_service_running';

// WorkManager task identifiers
const String guardianTaskName = 'bestseeds_tracking_guardian';
const String guardianTaskTag = 'tracking_guardian';

// Active-capture task: fires every ~2 minutes, actively fetches a fresh
// location via Geolocator.getCurrentPosition() and posts it. Unlike the
// 15-min periodic guardian, this task is a CHAIN of one-off tasks —
// each execution re-registers the next one. That's the only way to
// schedule sub-15-minute work on Android (platform enforces a 15-min
// minimum for registerPeriodicTask). WorkManager can wake the CPU out
// of Doze to run one-off tasks, which Timer.periodic cannot do, so
// this task bypasses Doze entirely.
//
// Reduced from 5 min → 2 min so gap periods (service killed by OEM)
// produce one GPS point every ~2 min instead of ~5 min. Android may
// coalesce tasks under aggressive Doze, but signalling a 2-min target
// gets closer to the minimum the OS will honour.
const String activeCaptureTaskName = 'bestseeds_active_capture';
const String activeCaptureTaskTag = 'active_capture';
const Duration activeCaptureInterval = Duration(minutes: 2);

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

/// Register a one-off active-capture task that will fire after [delay]
/// (default 5 minutes), capture a fresh location and post it, then
/// re-register itself for the next cycle. This is how we get
/// sub-15-minute periodic behaviour on Android without rolling our
/// own AlarmManager — WorkManager one-off tasks can fire while the
/// app is Doze-suspended, which `Timer.periodic` cannot.
Future<void> registerActiveCaptureTask({
  Duration delay = activeCaptureInterval,
}) async {
  await Workmanager().registerOneOffTask(
    activeCaptureTaskName,
    activeCaptureTaskName,
    tag: activeCaptureTaskTag,
    initialDelay: delay,
    existingWorkPolicy: ExistingWorkPolicy.replace,
    // Mark as expedited so Android schedules it immediately even during Doze.
    //
    // Regular one-off WorkManager tasks are batched to Doze "maintenance
    // windows" which happen every 15-60 min in deep Doze — the 2-min chain
    // interval means nothing during Doze without this flag.
    //
    // Expedited tasks get a JobScheduler slot outside maintenance windows.
    // The app gets a limited quota of expedited slots per day (~10 on
    // Android 12+). run_as_non_expedited_work_request means: if quota is
    // exhausted, fall back to normal scheduling rather than dropping the task.
    outOfQuotaPolicy: OutOfQuotaPolicy.run_as_non_expedited_work_request,
    constraints: Constraints(
      networkType: NetworkType.not_required,
      requiresBatteryNotLow: false,
      requiresCharging: false,
      requiresDeviceIdle: false,
      requiresStorageNotLow: false,
    ),
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 1),
  );
  print('WorkManager: Active-capture task scheduled for ${delay.inMinutes} min from now');
}

/// Cancel the active-capture chain when the journey ends.
Future<void> cancelActiveCaptureTask() async {
  await Workmanager().cancelByTag(activeCaptureTaskTag);
  print('WorkManager: Active-capture chain cancelled');
}

/// Top-level callback dispatcher for WorkManager.
/// Runs in a SEPARATE isolate — must be a top-level function.
@pragma('vm:entry-point')
void _workManagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();

      print('WorkManager[$taskName]: task starting...');

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final shouldRun = prefs.getBool(_wmServiceRunningKey) ?? false;

      if (!shouldRun) {
        print('WorkManager[$taskName]: Service flag is false, journey not active. Skipping.');
        // Even if the journey is over, make sure the active-capture chain
        // stops re-arming itself. Without this, a task enqueued just
        // before journey end would re-enqueue after journey end.
        return true;
      }

      // ── ACTIVE-CAPTURE TASK ──
      // Fire a fresh location post, then re-arm the chain for the next
      // cycle. This is the 5-min Doze-bypass path — it fires even when
      // the Timer-based watchdog and Geolocator stream are both
      // suspended by Android's battery management.
      if (taskName == activeCaptureTaskName) {
        TrackingLogger.log('⏰ workmgr active-capture fired');
        try {
          await _sendHeartbeatLocation(prefs);
          // If the foreground service looks dead, restart it so the
          // 10 s stream resumes when the CPU wakes.
          final isServiceRunning = await BackgroundLocationService.isRunning();
          if (!isServiceRunning) {
            TrackingLogger.log(
                '⏰ workmgr foreground service dead — restarting');
            print('WorkManager[$taskName]: Foreground service dead — restarting');
            await BackgroundLocationService.restartIfNeeded();
          }
        } catch (e) {
          TrackingLogger.log('⏰ workmgr active-capture error: $e');
          print('WorkManager[$taskName]: Active-capture error: $e');
        }
        // Re-arm the chain unconditionally while the journey is active.
        // If the capture failed, the next task in 5 min gets a fresh
        // attempt — WorkManager's backoff still applies to this current
        // failed invocation via `return false` below.
        await registerActiveCaptureTask();
        await TrackingLogger.flush();
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

/// Flush all SQLite-queued positions to the server, then send a fresh
/// GPS heartbeat if the queue was empty.
///
/// WHY THIS MATTERS FOR 100hr JOURNEYS:
/// During Doze maintenance windows FLP continues delivering positions to
/// the foreground service, but Android blocks network access. Each position
/// goes into the SQLite queue. When this WorkManager task fires (the OS
/// grants a brief network window during the maintenance period) we must
/// flush the ENTIRE queue — not just the last position.
///
/// The old approach: get last known → send ONE → markAllSent().
/// Problem: that silently discards every intermediate position queued
/// during the Doze gap. The backend then sees a 20-60 min hole and marks
/// the driver as 'offline' or 'stopped' — exactly the false-halt symptom.
///
/// The new approach:
///   Step 1 — Flush ALL unsent SQLite rows via the batch endpoint.
///            Backend receives them in chronological order with their
///            original GPS timestamps, so the route stays accurate.
///   Step 2 — If the queue was empty (service was alive and online the
///            whole time), capture a fresh GPS fix as a proof-of-life
///            heartbeat and send it via the single endpoint.
Future<void> _sendHeartbeatLocation(SharedPreferences prefs) async {
  final token = prefs.getString(_wmTokenKey);
  if (token == null || token.isEmpty) return;

  // ── Step 1: flush ALL queued positions via batch endpoint ──
  try {
    final unsent = await TrackingDatabase.getAllUnsent();
    if (unsent.isNotEmpty) {
      TrackingLogger.log('⏰ wm flush ${unsent.length} queued points → batch');
      print('WorkManager: Flushing ${unsent.length} queued points via batch...');

      final points = unsent.map((row) => {
        'lat': row['lat'],
        'lng': row['lng'],
        'location_name': row['location_name'] ?? 'Offline location',
        'gps_timestamp': row['timestamp'],
      }).toList();

      final batchResponse = await http.post(
        Uri.parse('${_wmBaseUrl}driver/location/batch-update'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'points': points}),
      ).timeout(const Duration(seconds: 20));

      if (batchResponse.statusCode == 401) {
        TrackingLogger.log('✗ wm batch 401 — token expired, stopping service');
        print('WorkManager: Batch 401 — token expired/revoked. Stopping.');
        await prefs.setBool(_wmServiceRunningKey, false);
        await prefs.remove(_wmTokenKey);
        return;
      }

      if (batchResponse.statusCode >= 200 && batchResponse.statusCode < 300) {
        await TrackingDatabase.markAllSent();
        TrackingLogger.log(
            '✓ wm batch flushed ${unsent.length} points '
            'http=${batchResponse.statusCode}');
        print('WorkManager: Batch flush OK (${unsent.length} points).');
        // Batch flush succeeded — no need for a separate heartbeat.
        return;
      } else {
        TrackingLogger.log('✗ wm batch http=${batchResponse.statusCode}');
        print('WorkManager: Batch flush failed: ${batchResponse.statusCode}');
        // Fall through to single-heartbeat path so at least one position
        // reaches the backend this maintenance window.
      }
    }
  } catch (e) {
    TrackingLogger.log('✗ wm batch error: $e');
    print('WorkManager: Batch flush error: $e');
    // Fall through to single-heartbeat path.
  }

  // ── Step 2: queue was empty or batch failed — send a single fresh position ──
  try {
    double? lat;
    double? lng;
    String locationName = 'Tracking active';

    // Prefer a fresh GPS fix so the heartbeat always reflects current position.
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {
      // GPS timed out (cold start after OEM kill). Use last known as fallback.
      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null) {
        lat = lastPos.latitude;
        lng = lastPos.longitude;
      }
    }

    if (lat == null || lng == null) {
      print('WorkManager: No location available for heartbeat');
      return;
    }

    // Reverse geocode so the user app shows a real place name, not an
    // internal label like "Heartbeat - fresh GPS".
    try {
      final resolved = await reverseGeocodeHttp(lat, lng);
      if (resolved != null && resolved.isNotEmpty) {
        locationName = resolved;
      }
    } catch (_) {}

    await TrackingDatabase.insert(lat: lat, lng: lng, locationName: locationName);

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

    // 401 = driver token expired or revoked (common on multi-day journeys
    // if the server uses short-lived JWTs). Stop the service and chain
    // immediately — continuing to fire every 2 min burns battery and
    // produces no useful data. Driver must re-login to resume tracking.
    if (response.statusCode == 401) {
      TrackingLogger.log('✗ wm heartbeat 401 — token expired, stopping service');
      print('WorkManager: Heartbeat 401 — token expired/revoked. Stopping.');
      await prefs.setBool(_wmServiceRunningKey, false);
      await prefs.remove(_wmTokenKey);
      return;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      await TrackingDatabase.markAllSent();
      TrackingLogger.log(
          '✓ wm heartbeat lat=${lat.toStringAsFixed(6)} '
          'lng=${lng.toStringAsFixed(6)} http=${response.statusCode}');
      print('WorkManager: Heartbeat sent successfully ($lat, $lng)');
    } else {
      TrackingLogger.log('✗ wm heartbeat http=${response.statusCode}');
      print('WorkManager: Heartbeat failed: ${response.statusCode}');
    }
  } catch (e) {
    TrackingLogger.log('✗ wm heartbeat failed: $e');
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
