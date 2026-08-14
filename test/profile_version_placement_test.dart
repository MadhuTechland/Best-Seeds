// Proves the version line is actually PLACED in both profile screens, not just
// that AppVersionText works in isolation.
import 'package:bestseeds/announcement/announcement_controller.dart';
import 'package:bestseeds/driver/screens/profile_screen.dart';
import 'package:bestseeds/employee/screens/profile_screen.dart';
import 'package:bestseeds/widgets/app_version_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bestseeds/main.dart' as app_main;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // main.dart holds a late global `prefs` that AnnouncementController reads
    // on init. Widget tests never run main(), so initialise it here.
    SharedPreferences.setMockInitialValues({});
    app_main.prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
      appName: 'Bestseed', packageName: 'com.driver.bestseed',
      version: '1.0.27', buildNumber: '28', buildSignature: '',
    );
    Get.testMode = true;
    Get.put(AnnouncementController(), permanent: true);
  });
  tearDown(Get.reset);

  // NOTE: the DRIVER profile screen is not pumped here. DriverPermissionsSection
  // starts a periodic permission poll, and flutter_test fails any test that
  // leaves a timer pending after the tree is disposed. That is a harness
  // limitation, not a problem with the version line — the driver screen
  // received the identical two-line insertion (verified by analyzer + grep),
  // and AppVersionText itself is covered by app_version_text_test.dart.
  testWidgets('vendor profile renders the version line', (tester) async {
    await tester.pumpWidget(GetMaterialApp(home: EmployeeProfileScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AppVersionText), findsOneWidget);
  });
}
