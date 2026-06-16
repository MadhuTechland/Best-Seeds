import 'dart:io';

import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

/// Self-contained controller for the driver Profile → "Permissions" toggles.
///
/// It (1) reads the ACTUAL device state for the two permissions the journey
/// needs — Location and Battery-optimization exemption (background) — (2) lets
/// the driver enable them from the profile screen, and (3) syncs the current
/// state to the backend so the admin panel can see it per driver.
///
/// This is additive: it does not change the existing journey-start permission
/// flow. It only reflects and reports the same permissions.
class DriverPermissionsController extends GetxController {
  final DriverStorageService _storage = DriverStorageService();
  final DriverAuthRepository _repo = DriverAuthRepository();

  // Same native channel the journey-start flow uses for OEM-accurate battery
  // optimization status (the standard Android API misreports on many OEMs).
  static const MethodChannel _deviceInfoChannel =
      MethodChannel('bestseeds/device_info');

  /// Current known state of each permission (reflects the device).
  final RxBool locationGranted = false.obs;
  final RxBool batteryDisabled = false.obs;

  /// True while we're reading the system state (drives the row spinners).
  final RxBool isChecking = false.obs;

  /// Prevents two requests racing (e.g. fast double-taps).
  bool _requestInProgress = false;

  /// Prevents overlapping system reads (app-open + resume can fire together).
  bool _refreshInProgress = false;

  @override
  void onInit() {
    super.onInit();
    // Read the real state on open, then report it to the server.
    refreshFromSystem(sync: true);
  }

  // ── System state ──────────────────────────────────────────────────────────

  /// Re-reads both permissions from the OS. Call on screen open and on app
  /// resume (after the driver returns from Settings). When [sync] is true the
  /// fresh state is also pushed to the backend.
  Future<void> refreshFromSystem({bool sync = false}) async {
    // App-open and resume can fire together — collapse into one read so we
    // don't double-sync or race.
    if (_refreshInProgress) return;
    _refreshInProgress = true;

    final prevLocation = locationGranted.value;
    final prevBattery = batteryDisabled.value;

    isChecking.value = true;
    try {
      locationGranted.value = await _checkLocation();
      batteryDisabled.value = await _checkBattery();
    } catch (_) {
      // Never let a status read crash the screen — leave last known values.
    } finally {
      isChecking.value = false;
      _refreshInProgress = false;
    }

    // Sync to the backend when asked, OR whenever the state actually changed
    // since we last read it (so admin updates even if a caller forgot `sync`).
    final changed =
        prevLocation != locationGranted.value || prevBattery != batteryDisabled.value;
    if (sync || changed) {
      // Fire-and-forget; failures are swallowed inside _syncToServer.
      _syncToServer();
    }
  }

  Future<bool> _checkLocation() async {
    try {
      final p = await Geolocator.checkPermission();
      return p == LocationPermission.always ||
          p == LocationPermission.whileInUse;
    } catch (_) {
      return locationGranted.value; // keep last known on error
    }
  }

  Future<bool> _checkBattery() async {
    if (!Platform.isAndroid) return true; // iOS has no such restriction
    // Standard API first.
    try {
      if (await Permission.ignoreBatteryOptimizations.isGranted) return true;
    } catch (_) {}
    // OEM-accurate native check (some OEMs misreport via the standard API).
    try {
      final isIgnoring = await _deviceInfoChannel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
      return isIgnoring;
    } catch (_) {
      return batteryDisabled.value; // keep last known on error
    }
  }

  // ── Enable actions (tapping a toggle that's OFF) ────────────────────────────

  /// Requests location permission. Handles every outcome:
  ///   granted → reflected + synced; denied → snackbar; permanently denied →
  ///   opens app settings so the driver can enable it manually.
  Future<void> enableLocation() async {
    if (_requestInProgress) return;
    _requestInProgress = true;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        _info(
          'Location permission was permanently denied. Please enable it in '
          'app settings.',
        );
        await _safe(() => Geolocator.openAppSettings());
      } else if (permission == LocationPermission.denied) {
        _info('Location permission denied.');
      } else {
        _success('Location permission enabled');
      }
    } catch (e) {
      _error('Could not request location permission. Please try from settings.');
      await _safe(() => Geolocator.openAppSettings());
    } finally {
      _requestInProgress = false;
      await refreshFromSystem(sync: true);
    }
  }

  /// Requests battery-optimization exemption (Android only) via the native
  /// channel, falling back to permission_handler.
  Future<void> enableBattery() async {
    if (!Platform.isAndroid) {
      batteryDisabled.value = true;
      await _syncToServer();
      return;
    }
    if (_requestInProgress) return;
    _requestInProgress = true;
    try {
      try {
        await _deviceInfoChannel
            .invokeMethod('requestIgnoreBatteryOptimizations');
      } catch (_) {
        // Fallback to the standard request if the native method is unavailable.
        await Permission.ignoreBatteryOptimizations.request();
      }
      // Give the system dialog a moment to settle before re-reading.
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      _error('Could not open battery settings. Please enable it manually.');
      await _safe(() => openAppSettings());
    } finally {
      _requestInProgress = false;
      await refreshFromSystem(sync: true);
      if (!batteryDisabled.value) {
        _info(
          'On some phones this is under Settings → Battery → unrestricted. '
          'Background tracking may stop without it.',
        );
      }
    }
  }

  /// A toggle that's already ON can't be revoked programmatically — open the
  /// app settings so the driver can manage it themselves.
  Future<void> openManageSettings() async {
    await _safe(() => openAppSettings());
  }

  // ── Backend sync ────────────────────────────────────────────────────────────

  Future<void> _syncToServer() async {
    try {
      final token = _storage.getToken();
      if (token == null || token.isEmpty) return;
      await _repo.updatePermissions(
        token: token,
        locationPermission: locationGranted.value,
        batteryOptimizationDisabled: batteryDisabled.value,
      );
    } catch (_) {
      // Non-fatal: the local toggles still reflect the device. The next
      // refresh (screen open / app resume) will retry the sync.
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  void _success(String msg) => Get.snackbar(
        'Permissions',
        msg,
        snackPosition: SnackPosition.BOTTOM,
        margin: const EdgeInsets.all(12),
      );

  void _info(String msg) => Get.snackbar(
        'Permissions',
        msg,
        snackPosition: SnackPosition.BOTTOM,
        margin: const EdgeInsets.all(12),
      );

  void _error(String msg) => Get.snackbar(
        'Permissions',
        msg,
        snackPosition: SnackPosition.BOTTOM,
        margin: const EdgeInsets.all(12),
      );
}
