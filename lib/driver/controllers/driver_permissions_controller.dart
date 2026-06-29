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
      // The toggle reflects the app's LOCATION PERMISSION: on when granted
      // (while-in-use or always), off otherwise. Read fresh every time so it
      // matches reality after the driver changes it in Settings.
      final p = await Geolocator.checkPermission()
          .timeout(const Duration(seconds: 3),
              onTimeout: () => LocationPermission.denied);
      return p == LocationPermission.always ||
          p == LocationPermission.whileInUse;
    } catch (_) {
      return locationGranted.value; // keep last known on error
    }
  }

  Future<bool> _checkBattery() async {
    if (!Platform.isAndroid) return true; // iOS has no such restriction
    // Standard API first (timeout so a stuck plugin call can't freeze refresh).
    try {
      final granted = await Permission.ignoreBatteryOptimizations.isGranted
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
      if (granted) return true;
    } catch (_) {}
    // OEM-accurate native check (some OEMs misreport via the standard API).
    // Timeout-guarded: a hung platform channel must never block future reads
    // (that would leave _refreshInProgress stuck and freeze the toggles).
    try {
      final isIgnoring = await _deviceInfoChannel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations')
              .timeout(const Duration(seconds: 3), onTimeout: () => null) ??
          false;
      return isIgnoring;
    } catch (_) {
      return batteryDisabled.value; // keep last known on error
    }
  }

  // ── Enable actions (tapping a toggle that's OFF) ────────────────────────────

  /// Requests location permission DIRECTLY via the system dialog — the same
  /// in-place prompt the driver gets when starting a journey. Tapping the
  /// toggle should ask right here, NOT send the driver off to app settings.
  Future<void> enableLocation() async {
    if (_requestInProgress) return;
    _requestInProgress = true;
    try {
      var permission = await Geolocator.checkPermission();
      final wasGranted = permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;

      // Only the OS grant dialog can appear, and only when NOT already granted.
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        permission = await Geolocator.requestPermission();
      }

      final granted = permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
      // Reflect the result on the toggle immediately, then sync below.
      locationGranted.value = granted;

      if (granted && !wasGranted) {
        // It actually just turned ON via the dialog.
        _success('Location permission enabled');
      } else if (!granted) {
        // System dialog only — no Settings redirect. If Android permanently
        // blocked it (denied twice), the dialog won't appear.
        _info('Location permission denied.');
      }
      // Already granted before the tap → no toast (and Android has no in-app
      // dialog to turn a granted permission OFF, so nothing happens here).
    } catch (e) {
      _error('Could not request location permission.');
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
      // Give the system dialog a moment to settle, then reflect the new state
      // on the toggle immediately (the refresh below also re-reads + syncs).
      await Future.delayed(const Duration(milliseconds: 600));
      batteryDisabled.value = await _checkBattery();
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

  /// A toggle that's already ON can't be revoked programmatically — open THIS
  /// app's settings page (App info → Permissions) so the driver can turn it off
  /// there. Used by the Battery tile.
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
