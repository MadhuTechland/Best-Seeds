import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/tracking_work_manager.dart';
import 'package:bestseeds/services/notification_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:bestseeds/firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences prefs;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

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
    );
  }
}
