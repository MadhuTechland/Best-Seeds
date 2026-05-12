import 'dart:convert';
import 'dart:io';

import 'package:bestseeds/employee/controllers/notification_controller.dart';
import 'package:bestseeds/employee/screens/notification_screen.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/driver/service/auth_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

const AndroidNotificationChannel _highImportanceChannel =
    AndroidNotificationChannel(
  'high_importance_channel',
  'High Importance Notifications',
  description: 'This channel is used for important notifications.',
  importance: Importance.max,
);

Future<void> _showBackgroundNotification(RemoteMessage message) async {
  final notification = message.notification;
  final title = notification?.title ?? message.data['title']?.toString();
  final body = notification?.body ?? message.data['body']?.toString();

  if (title == null && body == null) return;

  final localNotifications = FlutterLocalNotificationsPlugin();
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );

  await localNotifications.initialize(initSettings);
  await localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_highImportanceChannel);

  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'high_importance_channel',
      'High Importance Notifications',
      channelDescription: 'This channel is used for important notifications.',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  );

  final payload = jsonEncode(message.data);
  final notificationId = message.messageId?.hashCode ??
      DateTime.now().millisecondsSinceEpoch % 100000;

  await localNotifications.show(
    notificationId,
    title,
    body,
    details,
    payload: payload,
  );
}

/// Clear driver session in a background isolate. Cannot use the global
/// `prefs` singleton from main.dart (not initialized here), so we open
/// SharedPreferences directly and remove the same keys DriverStorageService
/// writes. When the user later opens the app the splash will see no token
/// and route them to the login screen.
Future<void> _clearDriverSessionInBackground() async {
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('driver');
    await sp.remove('driver_token');
    await sp.remove('driver_mobile');
    await sp.remove('driver_location_lat');
    await sp.remove('driver_location_lng');
    await sp.remove('driver_location_address');
  } catch (e) {
    print('FCM bg force-logout: failed to clear prefs -> $e');
  }
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('Background message received: ${message.messageId}');

  // Force-logout pushed when the driver logs in on another device. Clear
  // session immediately so reopening the app drops the user on login.
  if (message.data['type'] == 'force_logout') {
    await _clearDriverSessionInBackground();
    return; // suppress the notification banner — silent logout
  }

  await _showBackgroundNotification(message);
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final AuthService _authService = AuthService();

  /// Stores notification data when app is opened from terminated state.
  static Map<String, dynamic>? pendingNotificationData;

  Future<void> initialize() async {
    // 1. Register Background Handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // 2. Request Permissions
    await _requestPermissions();

    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // 3. Initialize Local Notifications (for foreground display)
    await _initLocalNotifications();

    // 4. Listen for token refresh
    _fcm.onTokenRefresh.listen((newToken) {
      _sendTokenToServer(newToken);
    });

    // 5. Set up message handlers
    _setupMessageHandlers();
  }

  /// Call after employee login to register FCM token with backend.
  Future<void> registerEmployeeToken() async {
    final token = await _getFcmToken();
    if (token == null) return;

    final authToken = StorageService().getToken();
    if (authToken == null) return;

    try {
      await _authService.registerVendorFcmToken(
        token: authToken,
        fcmToken: token,
      );
      print('FCM: Employee token registered');
    } catch (e) {
      print('FCM: Failed to register employee token -> $e');
    }
  }

  /// Call after driver login to register FCM token with backend.
  Future<void> registerDriverToken() async {
    final token = await _getFcmToken();
    if (token == null) return;

    final authToken = DriverStorageService().getToken();
    if (authToken == null) return;

    try {
      await _authService.registerDriverFcmToken(
        token: authToken,
        fcmToken: token,
      );
      print('FCM: Driver token registered');
    } catch (e) {
      print('FCM: Failed to register driver token -> $e');
    }
  }

  Future<String?> _getFcmToken() async {
    try {
      // On iOS the APNs token is delivered asynchronously by the OS — it can
      // take 1-3 seconds after first launch (longer on cold start). The old
      // single-shot `getAPNSToken()` was returning null on the first call and
      // we silently bailed → driver was never registered → no pushes ever.
      // Poll for up to ~10 seconds before giving up.
      if (Platform.isIOS) {
        String? apnsToken;
        for (var attempt = 0; attempt < 10; attempt++) {
          apnsToken = await _fcm.getAPNSToken();
          if (apnsToken != null) break;
          await Future.delayed(const Duration(seconds: 1));
        }
        if (apnsToken == null) {
          print('FCM: APNs token still null after 10s — '
              'check Push Notifications capability + APNs key in Firebase');
          return null;
        }
        print('FCM: APNs token acquired');
      }
      final token = await _fcm.getToken();
      print('FCM Token: $token');
      return token;
    } catch (e) {
      print('FCM: Error getting token -> $e');
      return null;
    }
  }

  // -- Permissions --
  Future<void> _requestPermissions() async {
    final settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    print('FCM Permission status: ${settings.authorizationStatus}');
  }

  // -- Local Notifications --
  Future<void> _initLocalNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create high importance notification channel
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_highImportanceChannel);
  }

  // -- Token Management --
  Future<void> _sendTokenToServer(String fcmToken) async {
    // Try employee first, then driver
    final employeeToken = StorageService().getToken();
    if (employeeToken != null) {
      try {
        await _authService.registerVendorFcmToken(
          token: employeeToken,
          fcmToken: fcmToken,
        );
        print('FCM: Token refreshed for employee');
        return;
      } catch (e) {
        print('FCM: Failed to refresh employee token -> $e');
      }
    }

    final driverToken = DriverStorageService().getToken();
    if (driverToken != null) {
      try {
        await _authService.registerDriverFcmToken(
          token: driverToken,
          fcmToken: fcmToken,
        );
        print('FCM: Token refreshed for driver');
      } catch (e) {
        print('FCM: Failed to refresh driver token -> $e');
      }
    }
  }

  /// Force-logout the driver right now (used when an FCM `force_logout`
  /// message arrives in the foreground because they logged in elsewhere).
  /// Mirrors the api_clients 401 force-logout path.
  Future<void> _handleDriverForceLogout() async {
    print('FCM: force_logout received — clearing driver session');
    try {
      BackgroundLocationService.stop();
    } catch (_) {}
    await DriverStorageService().logout();
    Get.offAllNamed(AppRoutes.login);
  }

  void _setupMessageHandlers() {
    // Foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('FCM Foreground message: ${message.data}');
      if (message.data['type'] == 'force_logout') {
        _handleDriverForceLogout();
        return;
      }
      _showLocalNotification(message);
    });

    // When app is opened from a notification (background -> foreground)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('FCM Notification opened from background: ${message.data}');
      _handleNotificationTap(message.data);
    });

    // Check if app was opened from terminated state via notification.
    _fcm.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        print('FCM App opened from terminated via notification: ${message.data}');
        pendingNotificationData = Map<String, dynamic>.from(message.data);
      }
    });
  }

  // -- Show Local Notification --
  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    const androidDetails = AndroidNotificationDetails(
      'high_importance_channel',
      'High Importance Notifications',
      channelDescription: 'This channel is used for important notifications.',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Unique notification ID
    int notifId;
    final dataId = message.data['id'] ??
        message.data['booking_id'] ??
        message.data['notification_id'];
    if (dataId != null) {
      notifId = int.tryParse(dataId.toString()) ??
          DateTime.now().millisecondsSinceEpoch % 100000;
    } else if (message.messageId != null) {
      notifId = message.messageId.hashCode;
    } else {
      notifId = DateTime.now().millisecondsSinceEpoch % 100000;
    }

    await _localNotifications.show(
      notifId,
      notification.title,
      notification.body,
      details,
      payload: jsonEncode(message.data),
    );
  }

  // -- Notification Tap Handlers --
  void _onNotificationTapped(NotificationResponse response) {
    if (response.payload != null) {
      final data = jsonDecode(response.payload!);
      _handleNotificationTap(Map<String, dynamic>.from(data));
    }
  }

  void _handleNotificationTap(Map<String, dynamic> data) {
    // Only the employee/vendor side has a notification screen wired up.
    // If no employee session exists, do nothing — splash will route the user
    // and any genuinely-pending tap will be re-issued via handlePendingNotification.
    final employeeAuthToken = StorageService().getToken();
    if (employeeAuthToken == null) return;

    // Make sure the controller exists before opening the screen, otherwise
    // EmployeeNotificationScreen.initState() throws on Get.find(). The main
    // nav screen normally registers it, but cold-start race conditions or
    // navigating from outside that subtree can leave it unregistered.
    if (!Get.isRegistered<EmployeeNotificationController>()) {
      Get.put(EmployeeNotificationController());
    }

    // Refetch immediately so the screen shows the alert that triggered the tap.
    Get.find<EmployeeNotificationController>().fetchAlerts();

    Get.to(() => const EmployeeNotificationScreen());
  }

  /// Call from splash screen after navigation to handle pending notification.
  static void handlePendingNotification() {
    if (pendingNotificationData != null) {
      final data = pendingNotificationData!;
      pendingNotificationData = null;
      NotificationService()._handleNotificationTap(data);
    }
  }

  // -- Topic Subscription --
  Future<void> subscribeToTopic(String topic) async {
    await _fcm.subscribeToTopic(topic);
    print('FCM Subscribed to topic: $topic');
  }

  Future<void> unsubscribeFromTopic(String topic) async {
    await _fcm.unsubscribeFromTopic(topic);
    print('FCM Unsubscribed from topic: $topic');
  }

  /// Fire a local test notification immediately. Use to verify notifications
  /// are working on the current device/OS.
  Future<void> showTestNotification() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'high_importance_channel',
        'High Importance Notifications',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    await _localNotifications.show(
      9999,
      'Test Notification',
      'Notifications are working on this device!',
      details,
    );
    print('FCM: Test notification fired');
  }
}
