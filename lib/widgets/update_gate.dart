import 'dart:async';
import 'dart:io';

import 'package:bestseeds/driver/services/active_journey_prefs.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// Dev-only overrides used for on-device UI verification. Both must be
// false for production builds — leaving them true would force every
// launch onto the update screen regardless of Play state.
const bool _kForceDialogForTest = false;
const bool _kForceInJourneyForTest = false;

const String _androidPackageName = 'com.driver.bestseed';
const String _iosAppStoreId = '';

const String _androidStoreDeepLink = 'market://details?id=$_androidPackageName';
const String _androidStoreWebUrl =
    'https://play.google.com/store/apps/details?id=$_androidPackageName';
const String _iosStoreSearchUrl =
    'https://apps.apple.com/search?term=drive%20bestseed';

const String _rcMinVersion = 'min_driver_app_version';
const String _rcStoreAndroid = 'store_url_driver_android';
const String _rcStoreIos = 'store_url_driver_ios';

/// SharedPreferences key holding the fingerprint of the journey during
/// which the driver last tapped "Later". While the current journey's
/// fingerprint matches, the update screen is suppressed. Cleared
/// automatically when the journey ends or a different one starts.
const String _kSkippedJourneyFp = 'update_gate_skipped_journey_fp';

/// What driver splash should do after `DriverVersionCheck.checkForceUpdate`.
enum DriverForceUpdateDecision {
  /// No update required — carry on with the normal auth / home navigation.
  proceed,

  /// Replace the nav stack with `DriverForceUpdateScreen`. Its "Update Now"
  /// button either invokes Google's immediate-update installer (when
  /// `useInAppUpdate` is true) or deep-links to the Play Store.
  showBlockScreen,
}

class DriverVersionCheckResult {
  final DriverForceUpdateDecision decision;

  /// True when Play Core confirmed a newer version + the device can do
  /// an immediate install. Tells DriverForceUpdateScreen to call
  /// `performImmediateUpdate` inline instead of a store deep-link.
  final bool useInAppUpdate;

  /// True when the driver is mid-journey. DriverForceUpdateScreen then
  /// shows a "Later" button that persists the driver's choice until the
  /// journey ends.
  final bool inJourney;

  /// Fingerprint of the current live journey (pickup + drop coords).
  /// Used to persist the "Later" choice per-journey.
  final String journeyFingerprint;

  final String storeUrlAndroid;
  final String storeUrlIos;

  const DriverVersionCheckResult({
    required this.decision,
    required this.useInAppUpdate,
    required this.inJourney,
    required this.journeyFingerprint,
    required this.storeUrlAndroid,
    required this.storeUrlIos,
  });
}

/// Version-check helper for the driver app. Mirrors the user app's
/// `AppVersionManager` pattern: driver splash calls
/// `DriverVersionCheck.checkForceUpdate()` before its own auth checks and,
/// on `showBlockScreen`, does `Get.offAll(() => DriverForceUpdateScreen(...))`
/// which replaces the whole stack — no dialog-above-Navigator race with
/// splash's own `Get.offAllNamed`.
class DriverVersionCheck {
  DriverVersionCheck._();

  static Future<DriverVersionCheckResult> checkForceUpdate() async {
    final journey = await _readJourneyState();
    String storeAndroid = _androidStoreWebUrl;
    String storeIos = _iosStoreSearchUrl;

    // TEMP dev override — see _kForceDialogForTest above.
    if (_kForceDialogForTest) {
      debugPrint('DriverVersionCheck: _kForceDialogForTest=true — forcing screen');
      return DriverVersionCheckResult(
        decision: journey.suppress
            ? DriverForceUpdateDecision.proceed
            : DriverForceUpdateDecision.showBlockScreen,
        useInAppUpdate: false,
        inJourney: journey.inJourney,
        journeyFingerprint: journey.fp,
        storeUrlAndroid: storeAndroid,
        storeUrlIos: storeIos,
      );
    }

    // ── 1) Android: Google Play In-App Updates ──
    // MUST guard with Platform.isAndroid — the plugin throws
    // MissingPluginException on iOS.
    if (Platform.isAndroid) {
      try {
        final upd = await InAppUpdate.checkForUpdate()
            .timeout(const Duration(seconds: 6));
        if (upd.updateAvailability == UpdateAvailability.updateAvailable) {
          return DriverVersionCheckResult(
            decision: journey.suppress
                ? DriverForceUpdateDecision.proceed
                : DriverForceUpdateDecision.showBlockScreen,
            useInAppUpdate: upd.immediateUpdateAllowed,
            inJourney: journey.inJourney,
            journeyFingerprint: journey.fp,
            storeUrlAndroid: storeAndroid,
            storeUrlIos: storeIos,
          );
        }
        // Play answered authoritatively: no update available. Trust Play,
        // skip RC (a misconfigured RC floor should not override Play).
        return DriverVersionCheckResult(
          decision: DriverForceUpdateDecision.proceed,
          useInAppUpdate: false,
          inJourney: journey.inJourney,
          journeyFingerprint: journey.fp,
          storeUrlAndroid: storeAndroid,
          storeUrlIos: storeIos,
        );
      } catch (e) {
        debugPrint('DriverVersionCheck: InAppUpdate check failed: $e');
      }
    }

    // ── 2) iOS + Android when Play was unreachable: RC floor ──
    try {
      String currentVersion = '0.0.0';
      try {
        final info = await PackageInfo.fromPlatform();
        currentVersion = info.version;
      } catch (e) {
        debugPrint('DriverVersionCheck: PackageInfo failed: $e');
      }

      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 6),
        minimumFetchInterval: Duration.zero,
      ));
      await rc.setDefaults(const {
        _rcMinVersion: '0.0.0',
        _rcStoreAndroid: '',
        _rcStoreIos: '',
      });
      await rc.fetchAndActivate();

      final a = rc.getString(_rcStoreAndroid).trim();
      final i = rc.getString(_rcStoreIos).trim();
      if (a.isNotEmpty) storeAndroid = a;
      if (i.isNotEmpty) storeIos = i;

      final minRequired = rc.getString(_rcMinVersion).trim();
      final needsUpdate = minRequired.isNotEmpty &&
          minRequired != '0.0.0' &&
          _isBelow(currentVersion, minRequired);

      return DriverVersionCheckResult(
        decision: (needsUpdate && !journey.suppress)
            ? DriverForceUpdateDecision.showBlockScreen
            : DriverForceUpdateDecision.proceed,
        useInAppUpdate: false,
        inJourney: journey.inJourney,
        journeyFingerprint: journey.fp,
        storeUrlAndroid: storeAndroid,
        storeUrlIos: storeIos,
      );
    } catch (e) {
      debugPrint('DriverVersionCheck: RC check soft-fail: $e');
      return DriverVersionCheckResult(
        decision: DriverForceUpdateDecision.proceed,
        useInAppUpdate: false,
        inJourney: journey.inJourney,
        journeyFingerprint: journey.fp,
        storeUrlAndroid: storeAndroid,
        storeUrlIos: storeIos,
      );
    }
  }

  static Future<_JourneyState> _readJourneyState() async {
    // TEMP dev override — see _kForceInJourneyForTest above.
    if (_kForceInJourneyForTest) {
      return const _JourneyState(
        inJourney: true,
        fp: 'test_journey_fp',
        suppress: false,
      );
    }
    try {
      final j = await ActiveJourneyPrefs.read();
      final fp = j.hasPickup
          ? '${j.pickupLat}_${j.pickupLng}_${j.dropLat ?? ''}_${j.dropLng ?? ''}'
          : '';

      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kSkippedJourneyFp) ?? '';

      if (fp.isEmpty) {
        if (saved.isNotEmpty) await prefs.remove(_kSkippedJourneyFp);
        return const _JourneyState(inJourney: false, fp: '', suppress: false);
      }
      if (saved == fp) {
        return _JourneyState(inJourney: true, fp: fp, suppress: true);
      }
      if (saved.isNotEmpty) await prefs.remove(_kSkippedJourneyFp);
      return _JourneyState(inJourney: true, fp: fp, suppress: false);
    } catch (e) {
      debugPrint('DriverVersionCheck: journey state read failed: $e');
      return const _JourneyState(inJourney: false, fp: '', suppress: false);
    }
  }

  static bool _isBelow(String current, String minimum) {
    final c = _segments(current);
    final m = _segments(minimum);
    final len = c.length > m.length ? c.length : m.length;
    for (var i = 0; i < len; i++) {
      final cv = i < c.length ? c[i] : 0;
      final mv = i < m.length ? m[i] : 0;
      if (cv < mv) return true;
      if (cv > mv) return false;
    }
    return false;
  }

  static List<int> _segments(String v) => v
      .split('+')
      .first
      .split('.')
      .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
}

class _JourneyState {
  final bool inJourney;
  final String fp;
  final bool suppress;
  const _JourneyState({
    required this.inJourney,
    required this.fp,
    required this.suppress,
  });
}

/// Full-screen force-update UI for the driver app. Matches the user app's
/// `ForceUpdateScreen` pattern (Bestseed logo in a halo, "Update Required"
/// title, description, big Update button) with driver-specific branding
/// (blue primary + logo.jpeg). Mounted via `Get.offAll` from splash so it
/// owns the entire stack — no dialog-vs-Navigator race.
class DriverForceUpdateScreen extends StatelessWidget {
  final bool useInAppUpdate;
  final String storeUrlAndroid;
  final String storeUrlIos;
  final bool allowLater;
  final String journeyFingerprint;

  /// Optional callback fired when the driver taps "Later" (only visible
  /// when `allowLater` is true — i.e. mid-journey). The caller passes a
  /// resume-navigation lambda that navigates the driver back to home,
  /// since this screen replaced the whole stack.
  final Future<void> Function()? onLater;

  const DriverForceUpdateScreen({
    super.key,
    required this.useInAppUpdate,
    required this.storeUrlAndroid,
    required this.storeUrlIos,
    required this.allowLater,
    required this.journeyFingerprint,
    this.onLater,
  });

  Future<void> _onLaterPressed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSkippedJourneyFp, journeyFingerprint);
    } catch (e) {
      debugPrint('DriverForceUpdate: failed to persist Later choice: $e');
    }
    if (onLater != null) {
      await onLater!();
    }
  }

  Future<void> _onUpdatePressed() async {
    if (useInAppUpdate) {
      try {
        final result = await InAppUpdate.performImmediateUpdate();
        if (result == AppUpdateResult.success) return;
        Get.snackbar(
          'Update Cancelled',
          'Please tap Update Now again to install the latest version.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.black87,
          colorText: Colors.white,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 5),
        );
        return;
      } catch (e) {
        debugPrint('DriverForceUpdate: performImmediateUpdate threw: $e');
      }
    }
    await _openStore();
  }

  Future<void> _openStore() async {
    final Uri primary;
    final Uri fallback;
    if (Platform.isAndroid) {
      primary = Uri.parse(_androidStoreDeepLink);
      fallback = Uri.parse(storeUrlAndroid);
    } else if (Platform.isIOS) {
      final looksLikeAppId = _iosAppStoreId.isNotEmpty;
      if (looksLikeAppId) {
        primary = Uri.parse('itms-apps://apps.apple.com/app/id$_iosAppStoreId');
      } else {
        primary = Uri.parse(storeUrlIos);
      }
      fallback = Uri.parse(storeUrlIos);
    } else {
      return;
    }
    try {
      if (await canLaunchUrl(primary)) {
        final ok =
            await launchUrl(primary, mode: LaunchMode.externalApplication);
        if (ok) return;
      }
    } catch (e) {
      debugPrint('DriverForceUpdate: primary launch failed: $e');
    }
    try {
      final ok =
          await launchUrl(fallback, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (e) {
      debugPrint('DriverForceUpdate: fallback launch failed: $e');
    }
    Get.snackbar(
      'Update Failed',
      'Could not open the store. Please open Play Store manually and update Drive Bestseed.',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.black87,
      colorText: Colors.white,
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 6),
    );
  }

  static const Color _kBrandBlue = Color(0xFF0077C8);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: allowLater,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    color: _kBrandBlue.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/logo.jpeg',
                      width: 118,
                      height: 118,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.system_update_alt_rounded,
                        size: 56,
                        color: _kBrandBlue,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Update Required',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.roboto(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  allowLater
                      ? 'A new version of Drive Bestseed is available.\n'
                          'You can update after finishing your current delivery.'
                      : 'A newer version of Drive Bestseed is available.\n'
                          'Please update to continue using the app.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.roboto(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 36),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: _kBrandBlue.withValues(alpha: 0.28),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _onUpdatePressed,
                      icon: const Icon(Icons.download_rounded, size: 22),
                      label: Text(
                        Platform.isIOS
                            ? 'Update from App Store'
                            : 'Update from Play Store',
                        style: GoogleFonts.roboto(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kBrandBlue,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shadowColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ),
                if (allowLater) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: TextButton(
                      onPressed: _onLaterPressed,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.grey.shade700,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Later',
                        style: GoogleFonts.roboto(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
