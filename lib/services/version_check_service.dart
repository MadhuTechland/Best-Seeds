import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../routes/app_constants.dart';

/// Enum describing the outcome of a version-check request.
enum VersionCheckResult {
  /// Current build is at or above the latest published version — no action.
  upToDate,

  /// Current build is above min but below latest — show a dismissible
  /// "Update available" prompt (or ignore, at the caller's discretion).
  updateAvailable,

  /// Current build is below the required minimum — MUST show a blocking
  /// dialog and prevent further use of the app until the user updates.
  forceUpdate,

  /// The check failed (network / server error). Callers should let the
  /// user proceed rather than blocking on a broken network call.
  unknown,
}

/// Talks to the admin backend's `/api/app-version-check` endpoint, compares
/// the response against the currently-installed build, and drives the
/// blocking / dismissible update dialogs.
///
/// The `app` argument distinguishes the driver app from the vendor app so
/// each has its own independently-versioned update track.
class VersionCheckService {
  VersionCheckService._();

  /// Fire the check + show a blocking dialog if force-update is required.
  /// Returns the raw result so the caller can react (e.g. delay other
  /// startup work while the dialog is up).
  ///
  /// [app] must be `'driver'` or `'vendor'` — matches the backend's
  /// `app_version_{app}_{platform}_*` config-key convention.
  ///
  /// The dialog is rendered via `Get.dialog` and uses `Get.context`
  /// under the hood, so the caller doesn't need to pass a BuildContext
  /// or worry about `mounted` across the async gap.
  static Future<VersionCheckResult> runOnStartup({required String app}) async {
    final result = await _check(app: app);
    switch (result.status) {
      case VersionCheckResult.forceUpdate:
        // Show the blocking dialog — user cannot dismiss it.
        _showForceUpdateDialog(info: result);
        break;
      case VersionCheckResult.updateAvailable:
        // Optional soft prompt — currently a no-op to avoid nagging on
        // every launch. Wire in a snackbar or a "later/update" dialog
        // if you decide you want that UX.
        break;
      case VersionCheckResult.upToDate:
      case VersionCheckResult.unknown:
        break;
    }
    return result.status;
  }

  // ─────────────────────────────────────────────────────────────────────

  static Future<_VersionCheckResponse> _check({required String app}) async {
    try {
      final platform = Platform.isIOS
          ? 'ios'
          : (Platform.isAndroid ? 'android' : null);
      if (platform == null) {
        return _VersionCheckResponse(status: VersionCheckResult.unknown);
      }

      final url = Uri.parse(
        '${AppConstants.baseUrl}app-version-check?platform=$platform&app=$app',
      );
      final response = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        return _VersionCheckResponse(status: VersionCheckResult.unknown);
      }
      final body = jsonDecode(response.body);
      if (body is! Map || body['status'] != true) {
        return _VersionCheckResponse(status: VersionCheckResult.unknown);
      }

      final minVersion = (body['min_version'] ?? '').toString();
      final latestVersion = (body['latest_version'] ?? '').toString();
      final storeUrl = (body['store_url'] ?? '').toString();
      final changelog = (body['changelog'] ?? '').toString();

      final pkg = await PackageInfo.fromPlatform();
      final currentVersion = pkg.version;

      final belowMin = _compareSemver(currentVersion, minVersion) < 0;
      final belowLatest = _compareSemver(currentVersion, latestVersion) < 0;

      final status = belowMin
          ? VersionCheckResult.forceUpdate
          : (belowLatest
              ? VersionCheckResult.updateAvailable
              : VersionCheckResult.upToDate);

      return _VersionCheckResponse(
        status: status,
        minVersion: minVersion,
        latestVersion: latestVersion,
        storeUrl: storeUrl,
        changelog: changelog,
        currentVersion: currentVersion,
      );
    } catch (e) {
      // Never block the app because the check itself failed.
      return _VersionCheckResponse(status: VersionCheckResult.unknown);
    }
  }

  /// Compare two dot-separated version strings. Returns negative if a<b,
  /// 0 if equal, positive if a>b. Missing segments are treated as 0.
  static int _compareSemver(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return -1;
    if (b.isEmpty) return 1;
    final ap = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bp = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = ap.length > bp.length ? ap.length : bp.length;
    for (var i = 0; i < len; i++) {
      final av = i < ap.length ? ap[i] : 0;
      final bv = i < bp.length ? bp[i] : 0;
      if (av != bv) return av - bv;
    }
    return 0;
  }

  static void _showForceUpdateDialog({required _VersionCheckResponse info}) {
    if (Get.context == null) return;
    // Use Get.dialog so this works even when the caller hasn't provided
    // a BuildContext (e.g. called from splash before any screen mounts).
    Get.dialog(
      PopScope(
        // canPop: false blocks Android back button (incl. predictive-back
        // gesture) — the whole point is the user cannot bypass the dialog.
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: const Text('Update Required'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.changelog.isNotEmpty
                      ? info.changelog
                      : 'A newer version of Bestseed is required to continue.',
                  style: const TextStyle(fontSize: 14),
                ),
                if (info.currentVersion.isNotEmpty &&
                    info.minVersion.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Your version: ${info.currentVersion}\n'
                    'Required:      ${info.minVersion}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontFamilyFallback: const ['Menlo', 'Courier'],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () {
                if (info.storeUrl.isEmpty) return;
                launchUrl(
                  Uri.parse(info.storeUrl),
                  mode: LaunchMode.externalApplication,
                );
              },
              child: const Text('Update Now'),
            ),
          ],
        ),
      ),
      barrierDismissible: false,
    );
  }
}

class _VersionCheckResponse {
  _VersionCheckResponse({
    required this.status,
    this.minVersion = '',
    this.latestVersion = '',
    this.storeUrl = '',
    this.changelog = '',
    this.currentVersion = '',
  });

  final VersionCheckResult status;
  final String minVersion;
  final String latestVersion;
  final String storeUrl;
  final String changelog;
  final String currentVersion;
}
