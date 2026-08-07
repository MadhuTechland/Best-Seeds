import 'dart:async';
import 'dart:io';

import 'package:bestseeds/driver/service/auth_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/routes/app_constants.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Periodically checks driver device state (GPS, location, internet)
/// and sends alerts to the backend every 5 minutes.
class TrackingAlertService {
  static Timer? _timer;
  static const _interval = Duration(minutes: 5);
  static final AuthService _authService = AuthService();
  static final DriverStorageService _storage = DriverStorageService();
  static const MethodChannel _deviceInfoChannel =
      MethodChannel('bestseeds/device_info');
  static String? _pendingIssueType;
  static String? _lastDetectedIssueType;

  /// Start the periodic alert checker after driver login.
  static void start() {
    stop(); // cancel any existing timer
    // Run once immediately, then every 5 minutes
    _checkAndSendAlert();
    _timer = Timer.periodic(_interval, (_) => _checkAndSendAlert());
  }

  /// Stop the periodic alert checker (call on logout).
  static void stop() {
    _timer?.cancel();
    _timer = null;
    _pendingIssueType = null;
    _lastDetectedIssueType = null;
  }

  static bool get isRunning => _timer != null && _timer!.isActive;

  static Future<void> _checkAndSendAlert() async {
    final token = _storage.getToken();
    if (token == null) {
      stop();
      return;
    }

    // Only send alerts while a journey is active. Without this check the
    // service would send false gps_off / no_internet alerts whenever the
    // driver opens the app without an active delivery.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final journeyActive = prefs.getBool('bg_location_service_running') ?? false;
    if (!journeyActive) return;

    final issueType = await _detectIssue(prefs);
    if (issueType == null) {
      await _flushPendingAlert(token);
      _lastDetectedIssueType = null;
      return;
    }

    if (issueType == _lastDetectedIssueType) {
      print('TRACKING ALERT: Same issue still active, skipping -> $issueType');
      return;
    }

    _lastDetectedIssueType = issueType;

    if (issueType == 'no_internet') {
      // Cannot notify backend while offline — queue and retry when online.
      _pendingIssueType = issueType;
      print('TRACKING ALERT: Internet unavailable, alert queued for retry');
      return;
    }

    try {
      await _flushPendingAlert(token);
      await _authService.sendTrackingAlert(
        token: token,
        issueType: issueType,
      );
      print('TRACKING ALERT: Sent alert -> $issueType');
    } catch (e) {
      // A rejected alert used to vanish here. The server validated issue_type
      // against a different vocabulary than the one this service emits, so
      // every alert except gps_off came back 422 and the admin bell stayed
      // empty — with nothing in the logs to say why. Re-arm so the next sweep
      // retries, and make the failure loud.
      _lastDetectedIssueType = null;
      print('TRACKING ALERT: REJECTED for "$issueType" -> $e '
          '(will retry on next check)');
    }
  }

  static Future<void> _flushPendingAlert(String token) async {
    final pendingIssueType = _pendingIssueType;
    if (pendingIssueType == null) return;

    try {
      await _authService.sendTrackingAlert(
        token: token,
        issueType: pendingIssueType,
      );
      _pendingIssueType = null;
      print('TRACKING ALERT: Sent queued alert -> $pendingIssueType');
    } catch (e) {
      print('TRACKING ALERT: Failed to send queued alert -> $e');
    }
  }

  /// Returns the issue type string or null if everything is normal.
  static Future<String?> _detectIssue(SharedPreferences prefs) async {
    // 1. Check internet connectivity.
    // connectivity_plus reporting ConnectivityResult.none is unreliable on some
    // OEM builds (Xiaomi/Realme/Vivo battery management, VPNs, or an unusual
    // active interface) — it can say "none" while mobile data actually works,
    // which is what made some phones show a false "No internet connection". So
    // we only flag 'no_internet' when a real reachability probe to our own
    // backend ALSO fails. A thrown error while reading connectivity is
    // inconclusive (not proof of being offline), so we don't flag it either.
    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        final reachable = await _isBackendReachable();
        if (!reachable) {
          return 'no_internet';
        }
      }
    } catch (_) {
      // Inconclusive — do not report offline on a connectivity read error.
    }

    // 2. Check if location service (GPS hardware) is enabled
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return 'gps_off';
      }
    } catch (_) {
      return 'gps_off';
    }

    // 3. Check location permission (user may have revoked it)
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return 'location_off';
      }
    } catch (_) {
      return 'location_off';
    }

    // 4. Check battery level on Android via platform channel
    try {
      if (Platform.isAndroid) {
        final batteryLevel =
            await _deviceInfoChannel.invokeMethod<int>('getBatteryLevel');
        if (batteryLevel != null && batteryLevel <= 20) {
          return 'battery_low';
        }
      }
    } catch (_) {
      // Ignore battery read errors; they should not block tracking.
    }

    // 5. Detect if backend is not receiving location updates despite GPS+internet being OK.
    // background_location_service writes 'last_location_sent_at' (ms since epoch) on each
    // successful POST. If that timestamp is older than 10 minutes, something is silently broken.
    try {
      final lastSentMs = prefs.getInt('last_location_sent_at');
      if (lastSentMs != null) {
        final lastSent = DateTime.fromMillisecondsSinceEpoch(lastSentMs);
        if (DateTime.now().difference(lastSent) > const Duration(minutes: 10)) {
          return 'location_not_sending';
        }
      }
    } catch (_) {
      // Ignore read errors.
    }

    return null; // all good
  }

  /// Real reachability probe: can this device actually resolve/reach OUR
  /// backend? Used to confirm a suspected offline state before flagging it,
  /// so a misreporting connectivity_plus result doesn't raise a false
  /// "No internet connection" alert.
  static Future<bool> _isBackendReachable() async {
    try {
      final host = Uri.parse(AppConstants.baseUrl).host;
      final result = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
