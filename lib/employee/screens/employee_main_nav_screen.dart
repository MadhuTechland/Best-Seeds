import 'package:bestseeds/employee/screens/booking_screen.dart';
import 'package:bestseeds/employee/screens/custom_bottom_nav_bar.dart';
import 'package:bestseeds/employee/screens/employee_home_screen.dart';
import 'package:bestseeds/employee/screens/profile_screen.dart';
import 'package:bestseeds/employee/screens/tracking_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Controller for managing bottom navigation state
class EmployeeNavController extends GetxController {
  final currentIndex = 0.obs;

  void changeTab(int index) {
    currentIndex.value = index;
  }

  void goToBookings() => changeTab(1);
  void goToTracking() => changeTab(2);
  void goToProfile() => changeTab(3);
  void goToHome() => changeTab(0);
}

class EmployeeMainNavigationScreen extends StatelessWidget {
  const EmployeeMainNavigationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final navController = Get.put(EmployeeNavController());

    final List<Widget> screens = [
      const EmployeeDashboard(),
      const BookingScreen(),
      const TrackingScreen(),
      EmployeeProfileScreen(),
    ];

    return Scaffold(
      body: Obx(() => IndexedStack(
            index: navController.currentIndex.value,
            children: screens,
          )),
      bottomNavigationBar: Obx(() => EmployeeBottomNavBar(
            currentIndex: navController.currentIndex.value,
            onTap: navController.changeTab,
          )),
    );
  }
}

