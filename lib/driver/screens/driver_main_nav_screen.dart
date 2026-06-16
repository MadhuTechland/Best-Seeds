import 'package:bestseeds/driver/controllers/driver_permissions_controller.dart';
import 'package:bestseeds/driver/screens/booking_screen.dart';
import 'package:bestseeds/driver/screens/driver_home_screen.dart';
import 'package:bestseeds/driver/screens/profile_screen.dart';
import 'package:bestseeds/driver/screens/tracking_screen.dart';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/employee/screens/custom_bottom_nav_bar.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class DriverMainNavigationScreen extends StatefulWidget {
  const DriverMainNavigationScreen({super.key});

  @override
  State<DriverMainNavigationScreen> createState() =>
      _DriverMainNavigationScreenState();
}

class _DriverMainNavigationScreenState
    extends State<DriverMainNavigationScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  DateTime? _lastBackPressed;

  // App-wide device-permission sync. Reading the system here (not only on the
  // Profile screen) means that as soon as the driver opens the app — or returns
  // to it after changing a permission in Settings — the current Location +
  // Battery state is checked and pushed to the backend, so the admin panel
  // always reflects reality.
  final DriverPermissionsController _permissions =
      Get.put(DriverPermissionsController());

  final List<Widget> _screens = [
    const DriverDashboard(),
    const BookingScreen(),
    const TrackingScreen(),
    DriverProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check + sync on app open (Get.put's onInit also syncs once; the guard in
    // refreshFromSystem collapses the two into a single read).
    _permissions.refreshFromSystem(sync: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from device Settings (or any background) → re-check & sync.
    if (state == AppLifecycleState.resumed) {
      _permissions.refreshFromSystem(sync: true);
    }
  }

  void _onTabTapped(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
        } else {
          // Block exit while a delivery journey is active
          final journeyActive = await BackgroundLocationService.isRunning();
          if (journeyActive) {
            toast('Cannot exit during an active delivery journey');
            return;
          }

          final now = DateTime.now();
          if (_lastBackPressed != null &&
              now.difference(_lastBackPressed!) < const Duration(seconds: 2)) {
            SystemNavigator.pop();
          } else {
            _lastBackPressed = now;
            toast('Press back again to exit');
          }
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: _screens,
        ),
        bottomNavigationBar: EmployeeBottomNavBar(
          currentIndex: _currentIndex,
          onTap: _onTabTapped,
        ),
      ),
    );
  }
}

