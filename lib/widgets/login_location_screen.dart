import 'dart:async';

import 'package:bestseeds/widgets/location_selector_screen.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:bestseeds/utils/app_snackbar.dart';

/// Why a location fetch failed — drives which recovery action we offer.
enum _LocErrorKind {
  serviceDisabled, // GPS / location services are off
  permissionDenied, // permission not granted (we re-ask via native dialog)
  failed, // permission + service OK, but no fix could be obtained
}

/// Screen shown after login to select/confirm user location
/// Used by both Driver and Employee login flows
class LoginLocationScreen extends StatefulWidget {
  final Future<void> Function(LocationData location) onLocationSelected;
  final String userType; // 'driver' or 'employee'

  const LoginLocationScreen({
    super.key,
    required this.onLocationSelected,
    this.userType = 'driver',
  });

  @override
  State<LoginLocationScreen> createState() => _LoginLocationScreenState();
}

class _LoginLocationScreenState extends State<LoginLocationScreen>
    with WidgetsBindingObserver {
  bool _isLoading = false;
  bool _isContinuing = false;
  LocationData? _selectedLocation;

  // Re-entrancy guard: a fetch is currently running. Prevents overlapping
  // attempts (e.g. an app-resume firing while we're still awaiting GPS), which
  // would otherwise stack native permission popups / dialogs.
  bool _fetching = false;
  // A recovery dialog is on screen — never show a second one on top of it.
  bool _recoveryPromptOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Auto-fetch current location on screen load (first time may prompt).
    _getCurrentLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user comes back from the system Location / App-settings screen
    // (where they may have granted permission or switched GPS on), retry
    // automatically so they don't have to tap anything. This retry is SILENT
    // (prompt: false): it never re-requests permission or re-opens a dialog, so
    // returning without fixing anything won't spam popups.
    if (state == AppLifecycleState.resumed &&
        _selectedLocation == null &&
        !_fetching &&
        !_recoveryPromptOpen) {
      _getCurrentLocation(prompt: false);
    }
  }

  /// [prompt] = true means this attempt may ask the user (native permission
  /// request + recovery dialogs). Silent retries (app resume) pass false so we
  /// only re-check state without showing anything new.
  Future<void> _getCurrentLocation({bool prompt = true}) async {
    if (_fetching) return; // ignore overlapping calls
    _fetching = true;
    debugPrint('📍 [LOGIN-LOC] _getCurrentLocation started (prompt=$prompt)');
    if (!mounted) {
      _fetching = false;
      return;
    }
    setState(() {
      _isLoading = true;
    });

    try {
      // 1) Is GPS / location service ON? Guard with a short timeout so a slow
      //    platform call (some OPPO/MediaTek ROMs are slow here) can never
      //    freeze the screen. If we can't tell in time, assume it's on and let
      //    the position fetch below surface the real problem.
      bool serviceEnabled = true;
      try {
        serviceEnabled = await Geolocator.isLocationServiceEnabled()
            .timeout(const Duration(seconds: 3), onTimeout: () => true);
      } catch (_) {
        serviceEnabled = true;
      }
      debugPrint('📍 [LOGIN-LOC] serviceEnabled=$serviceEnabled');
      if (!serviceEnabled) {
        _setError(_LocErrorKind.serviceDisabled, prompt: prompt);
        return;
      }

      // 2) Permission. When it isn't granted we show the NATIVE OS permission
      //    dialog (never a redirect to app settings). The native request is
      //    gated on [prompt]; a silent retry just re-reads the current state.
      LocationPermission permission = await Geolocator.checkPermission();
      debugPrint('📍 [LOGIN-LOC] permission=$permission');
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!prompt) {
          _setError(_LocErrorKind.permissionDenied, prompt: false);
          return;
        }
        permission = await Geolocator.requestPermission();
        debugPrint('📍 [LOGIN-LOC] after request: permission=$permission');
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setError(_LocErrorKind.permissionDenied, prompt: prompt);
        return;
      }
      debugPrint('📍 [LOGIN-LOC] permission OK, fetching position...');

      // 3) One bounded live fix + an instant last-known fallback. The old code
      //    chained several 15s attempts, so a weak signal could leave the
      //    screen "stuck" for up to a minute. This caps the wait at ~12s.
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 12),
        );
        debugPrint('📍 [LOGIN-LOC] live fix ✅ '
            'lat=${position.latitude}, lng=${position.longitude}');
      } on LocationServiceDisabledException {
        _setError(_LocErrorKind.serviceDisabled, prompt: prompt);
        return;
      } catch (e) {
        debugPrint('📍 [LOGIN-LOC] live fix failed: $e — trying last known');
      }

      position ??= await _safeLastKnown();

      if (position == null) {
        debugPrint('📍 [LOGIN-LOC] ❌ no position available');
        _setError(_LocErrorKind.failed, prompt: prompt);
        return;
      }

      final currentPosition = position;
      if (!mounted) return;
      setState(() {
        _selectedLocation = LocationData(
          latitude: currentPosition.latitude,
          longitude: currentPosition.longitude,
          address:
              'Lat: ${currentPosition.latitude.toStringAsFixed(4)}, Lng: ${currentPosition.longitude.toStringAsFixed(4)}',
        );
        _isLoading = false;
      });

      // Reverse-geocode for a friendly address (best-effort; never blocks).
      final address = await _getAddressFromCoordinates(
        currentPosition.latitude,
        currentPosition.longitude,
      );
      if (!mounted) return;
      setState(() {
        _selectedLocation = LocationData(
          latitude: currentPosition.latitude,
          longitude: currentPosition.longitude,
          address: address,
        );
      });
    } catch (e) {
      debugPrint('Error getting location: $e');
      _setError(_LocErrorKind.failed, prompt: prompt);
    } finally {
      _fetching = false;
    }
  }

  /// Last-known position with a timeout guard — on some devices the platform
  /// call can hang, so we never await it unbounded.
  Future<Position?> _safeLastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition()
          .timeout(const Duration(seconds: 4), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  void _setError(_LocErrorKind kind, {bool prompt = true}) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    // Only the user-initiated attempts (screen open / button tap) surface a
    // recovery popup. Silent resume retries stay quiet so nothing repeats.
    if (prompt) _handleScenario(kind);
  }

  /// Open the system GPS / location-services screen. On return, the lifecycle
  /// observer re-fetches automatically.
  Future<void> _openLocationSettings() async {
    try {
      await Geolocator.openLocationSettings();
    } catch (e) {
      debugPrint('openLocationSettings failed: $e');
      AppSnackbar.error('Could not open location settings.');
    }
  }

  /// Simple, per-scenario recovery — no big error card on screen. When the
  /// fetch can't complete we show a small popup (or native re-request) that
  /// matches the cause, then the lifecycle observer auto-retries on return.
  Future<void> _handleScenario(_LocErrorKind kind) async {
    // Never stack a second popup on top of one already showing.
    if (_recoveryPromptOpen) return;
    _recoveryPromptOpen = true;
    try {
      switch (kind) {
        case _LocErrorKind.serviceDisabled:
          // GPS is off — small popup that takes the user to turn it on.
          final go = await _confirmDialog(
            title: 'Turn on location',
            message: 'Please turn on your device location (GPS) to continue.',
            actionText: 'Turn On',
          );
          if (go) await _openLocationSettings();
          break;
        case _LocErrorKind.permissionDenied:
          // The native permission popup was already shown and dismissed —
          // no settings redirect, just a reminder.
          AppSnackbar.error('Location permission is required to continue.');
          break;
        case _LocErrorKind.failed:
          AppSnackbar.error('Could not get your location. Please try again.');
          break;
      }
    } finally {
      _recoveryPromptOpen = false;
    }
  }

  /// Minimal yes/no dialog. Returns true if the action button was tapped.
  Future<bool> _confirmDialog({
    required String title,
    required String message,
    required String actionText,
  }) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0077C8),
              foregroundColor: Colors.white,
            ),
            child: Text(actionText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String> _getAddressFromCoordinates(double lat, double lng) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        lat,
        lng,
      ).timeout(const Duration(seconds: 10));
      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        List<String> parts = [];
        if (place.subLocality?.isNotEmpty == true)
          parts.add(place.subLocality!);
        if (place.locality?.isNotEmpty == true) parts.add(place.locality!);
        if (place.administrativeArea?.isNotEmpty == true) {
          parts.add(place.administrativeArea!);
        }
        if (parts.isNotEmpty) return parts.join(', ');
      }
    } catch (e) {
      debugPrint('Geocoding error: $e');
    }
    return 'Lat: ${lat.toStringAsFixed(4)}, Lng: ${lng.toStringAsFixed(4)}';
  }

  Future<void> _confirmLocation() async {
    if (_selectedLocation == null || _isContinuing) return;

    setState(() {
      _isContinuing = true;
    });

    try {
      await widget.onLocationSelected(_selectedLocation!);
    } catch (_) {
      if (mounted) {
        setState(() {
          _isContinuing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      body: SingleChildScrollView(
        child: Container(
          width: width,
          height: height,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0xFF0077C8),
                Color(0xFF3FA9F5),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                /// Header
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: width * 0.06,
                    vertical: height * 0.02,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Set Your Location',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: width * 0.055,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

                /// Content
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: width * 0.06),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.location_on,
                          size: width * 0.25,
                          color: Colors.white,
                        ),
                        SizedBox(height: height * 0.03),
                        Text(
                          'Where are you located?',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: width * 0.06,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: height * 0.015),
                        Text(
                          'We need your location to show you\nrelevant bookings and services',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: width * 0.04,
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),

                /// Bottom Card
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    horizontal: width * 0.06,
                    vertical: height * 0.035,
                  ),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      /// Current Location Display
                      if (_isLoading)
                        Padding(
                          padding:
                              EdgeInsets.symmetric(vertical: height * 0.02),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF0077C8),
                                ),
                              ),
                              SizedBox(width: width * 0.03),
                              Text(
                                'Getting your location...',
                                style: TextStyle(
                                  fontSize: width * 0.04,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (_selectedLocation != null)
                        Container(
                          padding: EdgeInsets.all(width * 0.04),
                          margin: EdgeInsets.only(bottom: height * 0.02),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0077C8)
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.location_on,
                                  color: Color(0xFF0077C8),
                                ),
                              ),
                              SizedBox(width: width * 0.03),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Your Location',
                                      style: TextStyle(
                                        fontSize: width * 0.035,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    SizedBox(height: height * 0.005),
                                    Text(
                                      _selectedLocation!.address,
                                      style: TextStyle(
                                        fontSize: width * 0.04,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                      /// Use Current Location Button
                      SizedBox(
                        width: double.infinity,
                        height: height * 0.06,
                        child: OutlinedButton.icon(
                          onPressed: _isLoading ? null : _getCurrentLocation,
                          icon: const Icon(Icons.my_location),
                          label: const Text('Use Current Location'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF0077C8),
                            side: const BorderSide(color: Color(0xFF0077C8)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),    
                      SizedBox(height: height * 0.025),

                      /// Continue Button
                      SizedBox(
                        width: double.infinity,
                        height: height * 0.06,
                        child: ElevatedButton(
                          onPressed: _selectedLocation == null || _isLoading || _isContinuing
                              ? null
                              : _confirmLocation,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _selectedLocation != null
                                ? const Color(0xFF0077C8)
                                : const Color(0xFF0077C8)
                                    .withValues(alpha: 0.4),
                            disabledBackgroundColor:
                                const Color(0xFF0077C8).withValues(alpha: 0.4),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _isContinuing
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Text(
                                  'Continue',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: _selectedLocation != null
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.7),
                                  ),
                                ),
                        ),
                      ),
                      SizedBox(height: height * 0.02),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
