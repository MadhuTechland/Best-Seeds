import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
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
      Get.offAllNamed(AppRoutes.employeeHome);
      return;
    }

    // Check if driver is logged in
    final driver = await driverStorage.getDriver();
    if (driver != null) {
      print('Splash: Driver found - ${driver.name}');
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
              'assets/images/logo.png',
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
