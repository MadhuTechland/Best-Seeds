import 'package:bestseeds/driver/screens/driver_home_screen.dart';
import 'package:bestseeds/driver/screens/driver_main_nav_screen.dart';
import 'package:bestseeds/driver/screens/edit_profile_screen.dart';
import 'package:bestseeds/driver/screens/login_screens/login_screen.dart';
import 'package:bestseeds/driver/screens/login_screens/otp_verification_screen.dart';
import 'package:bestseeds/employee/screens/edit_profile_screen.dart';
import 'package:bestseeds/employee/screens/employee_main_nav_screen.dart';
import 'package:bestseeds/employee/screens/login_screens/employee_login_screen.dart';
import 'package:bestseeds/employee/screens/login_screens/set_password_screen.dart';
import 'package:bestseeds/screens/splash_screen.dart';
import 'package:flutter/material.dart';

class AppRoutes {
  static const splash = '/';
  static const login = '/login';
  static const employeeLogin = '/employeeLogin';
  static const driverHome = '/driverHome';
  static const employeeHome = '/employeeHome';
  static const setPassword = '/setPassword';
  static const driverOtpVerification = '/driverOtpVerification';
  static const employeeEditProfile = '/employeeEditProfile';
  static const driverEditProfile = '/driverEditProfile';

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashScreen());

      case login:
        return MaterialPageRoute(builder: (_) => DriverLoginScreen());

      case employeeLogin:
        return MaterialPageRoute(builder: (_) => EmployeeLoginScreen());

      case driverHome:
        return MaterialPageRoute(
          builder: (_) => const DriverDashboard(),
        );

      case employeeHome:
        return MaterialPageRoute(
          builder: (_) => const EmployeeMainNavigationScreen(),
        );

      case setPassword:
        return MaterialPageRoute(builder: (_) => SetPasswordScreen());

      case driverOtpVerification:
        return MaterialPageRoute(builder: (_) => OtpVerificationScreen());

      case employeeEditProfile:
        return MaterialPageRoute(
            builder: (_) => const EmployeeEditProfileScreen());

      case driverEditProfile:
        return MaterialPageRoute(
            builder: (_) => const DriverEditProfileScreen());

      default:
        return MaterialPageRoute(
          builder: (_) => const Scaffold(
            body: Center(child: Text('Route not found')),
          ),
        );
    }
  }
}
