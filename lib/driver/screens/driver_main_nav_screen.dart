import 'package:bestseeds/driver/screens/booking_screen.dart';
import 'package:bestseeds/driver/screens/driver_home_screen.dart';
import 'package:bestseeds/driver/screens/profile_screen.dart';
import 'package:bestseeds/driver/screens/tracking_screen.dart';
import 'package:bestseeds/employee/screens/custom_bottom_nav_bar.dart';
import 'package:flutter/material.dart';

class DriverMainNavigationScreen extends StatefulWidget {
  const DriverMainNavigationScreen({super.key});

  @override
  State<DriverMainNavigationScreen> createState() =>
      _DriverMainNavigationScreenState();
}

class _DriverMainNavigationScreenState
    extends State<DriverMainNavigationScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const DriverDashboard(),
    const BookingScreen(),
    const TrackingScreen(),
    DriverProfileScreen(),
  ];

  void _onTabTapped(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: EmployeeBottomNavBar(
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
      ),
    );
  }
}

