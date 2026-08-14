// The profile-screen version line must show the BUILT version, never a literal.
//
// A hardcoded string goes stale the first time someone ships without editing
// it — the customer app carried "v1.0.0" nine releases past the truth before
// anyone noticed. PackageInfo reads versionName/versionCode on Android and
// CFBundleShortVersionString/CFBundleVersion on iOS, both wired by Flutter to
// pubspec's `version:`, so a release bump is all that is ever needed.

import 'package:bestseeds/widgets/app_version_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Bestseed',
      packageName: 'com.driver.bestseed',
      version: '1.0.27',
      buildNumber: '28',
      buildSignature: '',
    );
  });

  testWidgets('shows the built version and build number', (tester) async {
    await tester.pumpWidget(_wrap(const AppVersionText()));
    await tester.pumpAndSettle();
    expect(find.text('Bestseed v1.0.27 (28)'), findsOneWidget);
  });

  testWidgets('falls back to the bare app name before the future resolves',
      (tester) async {
    await tester.pumpWidget(_wrap(const AppVersionText()));
    // First frame: FutureBuilder has no data yet.
    expect(find.text('Bestseed'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('app name is configurable', (tester) async {
    await tester.pumpWidget(_wrap(const AppVersionText(appName: 'Bestseed Vendor')));
    await tester.pumpAndSettle();
    expect(find.text('Bestseed Vendor v1.0.27 (28)'), findsOneWidget);
  });

  testWidgets('renders no hardcoded version literal', (tester) async {
    // Guards the actual regression: a literal that survives a release bump.
    PackageInfo.setMockInitialValues(
      appName: 'Bestseed',
      packageName: 'com.driver.bestseed',
      version: '9.9.9',
      buildNumber: '999',
      buildSignature: '',
    );
    await tester.pumpWidget(_wrap(const AppVersionText()));
    await tester.pumpAndSettle();
    expect(find.text('Bestseed v9.9.9 (999)'), findsOneWidget);
    expect(find.text('Bestseed v1.0.27 (28)'), findsNothing);
  });
}
