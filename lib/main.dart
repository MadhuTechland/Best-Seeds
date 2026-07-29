import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/tracking_work_manager.dart';
import 'package:bestseeds/services/notification_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:bestseeds/firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/widgets/update_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:upgrader/upgrader.dart';

late SharedPreferences prefs;
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();

  // Initialize Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize push notification service (FCM + local notifications)
  final notificationService = NotificationService();
  await notificationService.initialize();
  

  // Initialize background location service (creates notification channel,
  // registers the isolate entry point). Does NOT start tracking.
  await BackgroundLocationService.initialize();

  // Initialize WorkManager (OS-guaranteed periodic task scheduler).
  // The guardian task is registered when a journey starts and cancelled
  // when it ends. If the foreground service is killed by OEM battery
  // optimization, WorkManager will restart it within 15 minutes.
  await initializeWorkManager();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // Single Upgrader instance shared across the whole app so the Play Store
  // check only runs once per cold start (Upgrader dedupes internally by
  // instance). Ignore + Later are hidden so the only button is "Update
  // Now", which deep-links to the driver app's Play Store listing; the
  // 11.x dialog is modal (no barrier dismiss) so the driver can't bypass.
  //
  // TROUBLESHOOTING (2026-07): dialog wasn't firing on a device that had
  // an older sideloaded APK while Play Store held a newer version.
  //   - debugLogging  = true       → prints Upgrader's version-check
  //     result + Play Store scrape output to logcat, filter with
  //     `adb logcat | grep -i upgrader` while cold-starting the app.
  //   - durationUntilAlertAgain = 0 → don't suppress the alert after a
  //     recent check (default is 3 days).
  //   - minAppVersion = null        → rely only on Play Store's listed
  //     version, no local floor.
  // Once auto-updates are verified working reliably in the field, flip
  // debugLogging back to false and drop the durationUntilAlertAgain
  // override (defaults are fine for steady-state).
  static final _upgrader = Upgrader(
    countryCode: 'IN',
    languageCode: 'en',
    debugLogging: true,
    durationUntilAlertAgain: Duration.zero,
  );

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Drive Bestseed',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0077C8),
        ),
      ),
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.generateRoute,
      // Wrap every route in UpdateGate so the force-update dialog can fire on
      // top of whichever screen is currently mounted (splash, login, home).
      // The Upgrader singleton above provides the version-check logic; the
      // UpdateGate renders a custom, beautiful dialog with only an "Update
      // Now" button (opens Play Store / App Store) — no dismiss, no Later,
      // no scary "Something went wrong / check Google Play" fallback.
      builder: (context, child) => UpdateGate(
        upgrader: _upgrader,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}