import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:upgrader/upgrader.dart';
import 'package:url_launcher/url_launcher.dart';

// Play Store / App Store identifiers. Bundle id is the same on both stores.
const String _androidPackageName = 'com.driver.bestseed';
// iOS App Store numeric id — leave empty until the app is published; the
// fallback URL will still work as a web link.
const String _iosAppStoreId = '';

/// Wraps the app tree and shows a custom, beautiful "Update Available"
/// dialog whenever the [Upgrader] instance decides an update is required
/// OR when the version check itself fails (e.g. the Play Store scrape
/// couldn't resolve the app listing). The single **Update Now** button
/// deep-links to the store; there is no dismiss, no Later, no Close —
/// the driver cannot use the app until they update.
///
/// WHY not just [UpgradeAlert]: the stock dialog shows a scary
/// "Something went wrong / Check that Google Play is enabled" fallback
/// whenever the Play Store scrape fails, which drivers repeatedly saw
/// on cold-start and understandably confused for a device problem.
/// This gate treats the same signal as "update required" and shows a
/// friendly UI with a single call-to-action instead.
class UpdateGate extends StatefulWidget {
  final Upgrader upgrader;
  final Widget child;

  const UpdateGate({
    super.key,
    required this.upgrader,
    required this.child,
  });

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> with WidgetsBindingObserver {
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check when the app returns from background — covers the "driver
    // opened Play Store, tapped Update, came back before it installed"
    // scenario. If they're still on the old version the gate re-fires.
    if (state == AppLifecycleState.resumed) {
      _dialogShown = false;
      _check();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    // Ensure Upgrader has run its version check at least once. Safe to
    // call multiple times — it caches internally.
    try {
      await widget.upgrader.initialize();
    } catch (_) {
      // Swallow — a hard error here is treated as "we don't know", same as
      // the shouldDisplayUpgrade branch below.
    }

    if (!mounted || _dialogShown) return;

    final needsUpdate = _needsUpdate();
    if (!needsUpdate) return;

    _dialogShown = true;
    await _showUpdateDialog();
  }

  /// True when Upgrader is sure an update is required, OR when it couldn't
  /// determine the current store version at all. The second branch replaces
  /// the stock "Something went wrong / check Google Play" dialog — instead
  /// of blaming the driver's device, we assume the app is out of date and
  /// nudge them to the store.
  bool _needsUpdate() {
    try {
      if (widget.upgrader.shouldDisplayUpgrade()) return true;
    } catch (_) {}
    // Fallback for scrape failures — when Upgrader can't fetch the store
    // listing (network hiccup, region 404, scraper HTML changed) it silently
    // sets `versionInfo` to null and `shouldDisplayUpgrade()` returns false.
    // We treat that null as "we don't know → assume out of date" so the
    // driver sees the nice Update dialog instead of the stock "Something
    // went wrong / check Google Play" scare message.
    try {
      final vi = widget.upgrader.state.versionInfo;
      if (vi == null) return true;
    } catch (_) {
      return true;
    }
    return false;
  }

  Future<void> _showUpdateDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => const _UpdateDialog(),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog();

  Future<void> _openStore() async {
    // Prefer the native app scheme so Play Store / App Store opens
    // directly. Fall back to the https URL if the scheme is not
    // registered (e.g. Play Store missing on Huawei GMS-free devices).
    final Uri primary;
    final Uri fallback;
    if (Platform.isAndroid) {
      primary = Uri.parse('market://details?id=$_androidPackageName');
      fallback = Uri.parse(
          'https://play.google.com/store/apps/details?id=$_androidPackageName');
    } else if (Platform.isIOS) {
      final id = _iosAppStoreId.isEmpty ? _androidPackageName : _iosAppStoreId;
      primary = Uri.parse('itms-apps://apps.apple.com/app/id$id');
      fallback = Uri.parse('https://apps.apple.com/app/id$id');
    } else {
      return;
    }

    try {
      if (await canLaunchUrl(primary)) {
        await launchUrl(primary, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {}
    try {
      await launchUrl(fallback, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Block Android back-swipe / gesture — the driver cannot bypass this.
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Bestseed logo badge — replaces the generic system-update
              // glyph so the driver sees the brand mark on the "please
              // update" screen. Falls back to the update icon on any
              // asset-load failure (missing logo file / renamed asset).
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0077C8).withValues(alpha: 0.10),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0077C8).withValues(alpha: 0.20),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/logo.jpeg',
                    width: 82,
                    height: 82,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.system_update_alt_rounded,
                      color: Color(0xFF0077C8),
                      size: 40,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Update Available',
                textAlign: TextAlign.center,
                style: GoogleFonts.roboto(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'A new version of Drive Bestseed is available. Please update from the Play Store to continue.',
                textAlign: TextAlign.center,
                style: GoogleFonts.roboto(
                  fontSize: 14,
                  height: 1.5,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 28),
              // Update Now — the only exit from this dialog.
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _openStore,
                  icon: const Icon(Icons.download_rounded, size: 22),
                  label: Text(
                    'Update Now',
                    style: GoogleFonts.roboto(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0077C8),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

