import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/routes/app_constants.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/services/notification_service.dart';
import 'package:bestseeds/services/version_check_service.dart';
import 'package:bestseeds/widgets/login_location_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    await Future.delayed(const Duration(seconds: 2));

    final employeeStorage = StorageService();
    final driverStorage = DriverStorageService();

    // ── Force-update gate ──
    // Ask the backend if the installed build is still supported for the
    // active session's app. If a force-update is required, the service
    // shows a blocking dialog and we short-circuit here so no further
    // navigation happens behind it. If neither session exists we skip
    // the check — the login screen has nothing that can go wrong.
    final hasEmployeeSession = await employeeStorage.getUser() != null;
    final hasDriverSession = await driverStorage.getDriver() != null;
    if (hasDriverSession) {
      final r = await VersionCheckService.runOnStartup(app: 'driver');
      if (r == VersionCheckResult.forceUpdate) return;
    } else if (hasEmployeeSession) {
      final r = await VersionCheckService.runOnStartup(app: 'vendor');
      if (r == VersionCheckResult.forceUpdate) return;
    }

    // Check if employee is logged in
    final employee = await employeeStorage.getUser();
    if (employee != null) {
      // Validate token — catches stale tokens restored from Android backup after reinstall
      try {
        final validate = await http.get(
          Uri.parse(AppConstants.baseUrl + AppConstants.employeeProfileApi),
          headers: {'Authorization': 'Bearer ${employee.token}', 'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 5));
        if (validate.statusCode == 401) {
          await employeeStorage.logout();
          Get.offAllNamed(AppRoutes.login);
          return;
        }
      } catch (_) {
        // Network error / timeout — proceed with cached data (user may be offline)
      }

      print('Splash: Employee found - ${employee.name}');
      // Register FCM token on auto-login
      NotificationService().registerEmployeeToken();

      // Check if employee has location saved
      if (!employeeStorage.hasLocation()) {
        print(
            'Splash: Employee has no location, navigating to location screen');
        Get.offAll(() => LoginLocationScreen(
              userType: 'employee',
              onLocationSelected: (location) async {
                // Save location to local storage
                await employeeStorage.saveLocation(
                  latitude: location.latitude,
                  longitude: location.longitude,
                  address: location.address,
                );
                print('Splash: Employee location saved locally');

                // Save location to backend
                try {
                  final repo = AuthRepository();
                  await repo.updateCurrentLocation(
                    token: employee.token,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    address: location.address,
                  );
                  print('Splash: Employee location saved to backend');
                } catch (e) {
                  print(
                      'Splash: Failed to save employee location to backend: $e');
                }

                // Navigate to home
                Get.offAllNamed(AppRoutes.employeeHome);
              },
            ));
        return;
      }

      Get.offAllNamed(AppRoutes.employeeHome);
      // Handle pending notification if app was opened from terminated state
      Future.delayed(const Duration(milliseconds: 500), () {
        NotificationService.handlePendingNotification();
      });
      return;
    }

    // Check if driver is logged in
    final driver = await driverStorage.getDriver();
    if (driver != null) {
      // Validate token — catches stale tokens restored from Android backup after reinstall.
      // Retry once on 401 with a short delay to survive network handoffs
      // (mobile↔WiFi, captive-portal middleboxes) — mirrors the retry in
      // api_clients.dart. Only logout if two consecutive 401s in a row.
      try {
        Future<http.Response> validate() => http.get(
          Uri.parse(AppConstants.baseUrl + AppConstants.driverProfileApi),
          headers: {'Authorization': 'Bearer ${driver.token}', 'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 5));

        var resp = await validate();
        if (resp.statusCode == 401) {
          await Future.delayed(const Duration(milliseconds: 1500));
          try {
            resp = await validate();
          } catch (_) {
            // Network still unstable — keep session, proceed with cached data.
            print('Splash: retry-validate network error, keeping session');
            resp = http.Response('', 200); // synthetic pass-through
          }
        }
        if (resp.statusCode == 401) {
          await driverStorage.logout();
          Get.offAllNamed(AppRoutes.login);
          return;
        }
      } catch (_) {
        // Network error / timeout — proceed with cached data (user may be offline)
      }

      print('Splash: Driver found - ${driver.name}');
      // Register FCM token on auto-login
      NotificationService().registerDriverToken();

      // Check if driver has location saved
      if (!driverStorage.hasLocation()) {
        // Make sure no stale background tracking service interferes with the
        // login location picker after logout/re-login.
        await BackgroundLocationService.stop();

        print('Splash: Driver has no location, navigating to location screen');
        Get.offAll(() => LoginLocationScreen(
              userType: 'driver',
              onLocationSelected: (location) async {
                // Save location to local storage
                await driverStorage.saveLocation(
                  latitude: location.latitude,
                  longitude: location.longitude,
                  address: location.address,
                );
                print('Splash: Driver location saved locally');

                // Save location to backend
                try {
                  final repo = DriverAuthRepository();
                  await repo.updateCurrentLocation(
                    token: driver.token,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    address: location.address,
                  );
                  print('Splash: Driver location saved to backend');
                } catch (e) {
                  print('Splash: Failed to save driver location to backend: $e');
                }

                // Navigate to home
                Get.offAllNamed(AppRoutes.driverHome);
              },
            ));
        return;
      }

      // Restart background location service if it was killed during active journey
      await BackgroundLocationService.restartIfNeeded();
      Get.offAllNamed(AppRoutes.driverHome);
      return;
    }

    // No user logged in, go to driver login (default)
    print('Splash: No user found, going to login');
    Get.offAllNamed(AppRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0077C8),
              Color(0xFF3FA9F5),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/logo.jpeg',
              width: width * 0.4,
              errorBuilder: (context, error, stackTrace) {
                return Icon(
                  Icons.local_shipping,
                  size: width * 0.3,
                  color: Colors.white,
                );
              },
            ),
            SizedBox(height: width * 0.06),
            Text(
              'Bestseed',
              style: TextStyle(
                color: Colors.white,
                fontSize: width * 0.08,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: width * 0.04),
            const CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2,
            ),
          ],
        ),
      ),
    );
  }
}
