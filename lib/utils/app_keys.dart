import 'package:flutter/foundation.dart';
import 'package:bestseeds/utils/secrets.dart';

/// API keys, kept out of version control.
///
/// The values live in `secrets.dart` next to this file, which is gitignored.
/// After cloning, copy the template once:
///
/// ```bash
/// cp lib/utils/secrets.example.dart lib/utils/secrets.dart
/// ```
///
/// That is the only setup step — normal commands work unchanged:
///
/// ```bash
/// flutter run
/// flutter build appbundle --release
/// ```
///
/// A CI job that doesn't check the file out must write it before building
/// (e.g. from a repository secret), otherwise compilation fails with
/// "Target of URI doesn't exist: secrets.dart" — deliberately loud, so a
/// build never ships with an empty key.
///
/// NOTE: this keeps keys out of the repository, which is what stops secret
/// scanners and casual browsing of the source. It does NOT make them secret at
/// runtime — the value is compiled into the binary, so a key shipped in the app
/// can still be extracted from the APK/IPA. The actual protection is the key
/// restrictions configured in Google Cloud Console (package name + SHA-1 for
/// the SDKs) and keeping unrestricted web-service calls behind your own backend.
class AppKeys {
  AppKeys._();

  /// Google Maps / Places / Directions / Geocoding key.
  static const String googleMaps = Secrets.googleMaps;

  static bool get hasGoogleMaps =>
      googleMaps.trim().isNotEmpty && !googleMaps.startsWith('AIza-your-key');

  /// Logs a loud warning when the template value was never replaced, so maps
  /// failing is traceable to configuration rather than to a code bug.
  static void warnIfMissing() {
    if (!hasGoogleMaps) {
      debugPrint(
        '⚠️ [KEYS] Google Maps key not configured — maps, place search and '
        'route drawing will not work. Put the real key in '
        'lib/utils/secrets.dart (see secrets.example.dart).',
      );
    }
  }
}
