import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Driver-side location-permission helper + dialogs.
///
/// Mirrors the customer app's behaviour: when the OS location service is
/// off (or app-level permission is missing), the driver sees a popup whose
/// primary action opens the device's location settings directly. The popup
/// re-checks on app resume so it disappears as soon as the driver flips
/// the switch.
enum DriverLocationCheckResult {
  granted,
  permissionDenied,
  permissionDeniedForever,
  serviceDisabled,
}

class DriverLocationPermissionService {
  static Future<DriverLocationCheckResult> check() async {
    // SKIP isLocationServiceEnabled entirely — it hangs forever on OPPO/MediaTek.
    // Even .timeout() doesn't help — the Dart Future never completes.
    // Just check permission. If GPS is off, getCurrentPosition will fail later.
    debugPrint('📍 [DRIVER-LOC] check() — checking permission only (skip service check)...');

    var permission = await Geolocator.checkPermission();
    debugPrint('📍 [DRIVER-LOC] permission=$permission');
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      debugPrint('📍 [DRIVER-LOC] after request: permission=$permission');
    }
    if (permission == LocationPermission.deniedForever) {
      return DriverLocationCheckResult.permissionDeniedForever;
    }
    if (permission == LocationPermission.denied) {
      return DriverLocationCheckResult.permissionDenied;
    }
    debugPrint('📍 [DRIVER-LOC] ✅ granted');
    return DriverLocationCheckResult.granted;
  }

  static Future<void> openLocationSettings() =>
      Geolocator.openLocationSettings();

  static Future<void> openAppSettings() => Geolocator.openAppSettings();
}

/// Modal dialog the driver sees when location is unavailable.
/// Primary CTA opens the device's location/app settings directly.
class DriverLocationPromptDialog extends StatelessWidget {
  final String title;
  final String message;
  final String primaryLabel;
  final IconData icon;
  final VoidCallback onPrimary;

  const DriverLocationPromptDialog({
    super.key,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.icon,
    required this.onPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: const Color(0xFF0077C8)),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onPrimary,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0077C8),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  primaryLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stateful guard widget — wraps any driver screen and shows the prompt
/// dialog when location service / permission is missing. Re-checks
/// automatically when the app resumes (so the dialog goes away on its
/// own once the driver flips the switch in Settings).
class DriverLocationGuard extends StatefulWidget {
  final Widget child;
  const DriverLocationGuard({super.key, required this.child});

  @override
  State<DriverLocationGuard> createState() => _DriverLocationGuardState();
}

class _DriverLocationGuardState extends State<DriverLocationGuard>
    with WidgetsBindingObserver {
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _runCheck());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _runCheck();
  }

  Future<void> _runCheck() async {
    if (!mounted) return;
    final result = await DriverLocationPermissionService.check();
    if (!mounted) return;

    if (result == DriverLocationCheckResult.granted) {
      // If the dialog is up, pop it — driver fixed the setting.
      if (_dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        _dialogOpen = false;
      }
      return;
    }

    if (_dialogOpen) return; // already showing

    _dialogOpen = true;
    final useAppSettings =
        result == DriverLocationCheckResult.permissionDeniedForever;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: DriverLocationPromptDialog(
          icon: useAppSettings ? Icons.settings : Icons.location_off,
          title: useAppSettings
              ? 'Permission Required'
              : 'Location Service is Off',
          message: useAppSettings
              ? 'Location permission was denied. Enable it in app settings to keep tracking your deliveries.'
              : 'Please turn on GPS / Location on your device to continue delivering.',
          primaryLabel: 'Open Settings',
          onPrimary: () async {
            if (useAppSettings) {
              await DriverLocationPermissionService.openAppSettings();
            } else {
              await DriverLocationPermissionService.openLocationSettings();
            }
            // didChangeAppLifecycleState will fire again on resume and
            // close the dialog if the driver fixed it.
          },
        ),
      ),
    );
    _dialogOpen = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
