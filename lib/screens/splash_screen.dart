import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/widgets/login_location_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

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

    // Check if employee is logged in
    final employee = await employeeStorage.getUser();
    if (employee != null) {
      print('Splash: Employee found - ${employee.name}');

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
      return;
    }

    // Check if driver is logged in
    final driver = await driverStorage.getDriver();
    if (driver != null) {
      print('Splash: Driver found - ${driver.name}');

      // Restart background location service if it was killed during active journey
      await BackgroundLocationService.restartIfNeeded();

      // Check if driver has location saved
      // if (!driverStorage.hasLocation()) {
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
      // }

      // Get.offAllNamed(AppRoutes.driverHome);
      // return;
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
              'Best Seeds',
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
