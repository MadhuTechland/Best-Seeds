import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Small grey "Bestseed v1.0.27 (28)" line for the bottom of a profile screen.
///
/// Reads the version the app was actually BUILT with rather than a literal that
/// has to be remembered on every release — a hardcoded string goes stale the
/// first time someone ships without updating it, and then quietly misleads
/// whoever is trying to work out which build a user is on.
///
/// One call covers both platforms: PackageInfo reads versionName/versionCode on
/// Android and CFBundleShortVersionString/CFBundleVersion on iOS, and the
/// Flutter toolchain wires both to pubspec's `version:` (`flutter.versionName`
/// in build.gradle, `$(FLUTTER_BUILD_NAME)` in Info.plist). Bumping pubspec is
/// therefore enough — nothing here needs touching on a release.
///
/// Implemented with a FutureBuilder so it drops straight into a StatelessWidget
/// parent; both profile screens here are stateless.
class AppVersionText extends StatelessWidget {
  const AppVersionText({super.key, this.appName = 'Bestseed'});

  /// Shown before the version, e.g. "Bestseed v1.0.27 (28)".
  final String appName;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        // While loading, or on the rare corrupt install / OEM ROM where
        // PackageInfo throws, fall back to the bare app name. Better than
        // showing a number we cannot stand behind.
        final info = snapshot.data;
        final label = (snapshot.connectionState == ConnectionState.done &&
                info != null &&
                info.version.isNotEmpty)
            ? '$appName v${info.version} (${info.buildNumber})'
            : appName;

        return Text(
          label,
          style: GoogleFonts.roboto(
            fontSize: 12,
            color: Colors.grey.shade400,
          ),
        );
      },
    );
  }
}
