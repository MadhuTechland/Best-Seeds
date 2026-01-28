import 'package:bestseeds/employee/controllers/profile_controller.dart';
import 'package:bestseeds/employee/screens/employee_main_nav_screen.dart';
import 'package:bestseeds/employee/screens/help_screen.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:bestseeds/widgets/profile_menu_item.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class EmployeeProfileScreen extends StatelessWidget {
  EmployeeProfileScreen({super.key});

  final EmployeeProfileController controller = Get.put(EmployeeProfileController());

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, width, height),
            Obx(() => _buildProfileInfo(width, height)),
            SizedBox(height: height * 0.03),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ProfileMenuItem(
                      icon: Icons.notifications_outlined,
                      title: 'Notification',
                      onTap: () {
                        AppSnackbar.info('Notifications', 'No notifications found');
                      },
                    ),
                    ProfileMenuItem(
                      icon: Icons.description_outlined,
                      title: 'Bookings',
                      onTap: () {
                        final navController = Get.find<EmployeeNavController>();
                        navController.goToBookings();
                      },
                    ),
                    ProfileMenuItem(
                      icon: Icons.local_shipping_outlined,
                      title: 'Vehicle Tracking',
                      onTap: () {
                        final navController = Get.find<EmployeeNavController>();
                        navController.goToTracking();
                      },
                    ),
                    ProfileMenuItem(
                      icon: Icons.help_outline,
                      title: 'Help',
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const HelpScreen(),
                          ),
                        );
                      },
                    ),
                    ProfileMenuItem(
                      icon: Icons.share_outlined,
                      title: 'Share this app',
                      onTap: () {},
                    ),
                    ProfileMenuItem(
                      icon: Icons.description_outlined,
                      title: 'Terms & conditions',
                      onTap: () {},
                    ),
                    ProfileMenuItem(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Privacy Policy',
                      onTap: () {},
                    ),
                    SizedBox(height: height * 0.02),
                    ProfileMenuItem(
                      icon: Icons.logout,
                      title: 'Logout',
                      iconColor: const Color(0xFF0077C8),
                      isLogout: true,
                      onTap: () {
                        _showLogoutDialog(context);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, double width, double height) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.02,
      ),
      color: Colors.white,
      child: Row(
        children: [
          Text(
            'Profile',
            style: TextStyle(
              fontSize: width * 0.055,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileInfo(double width, double height) {
    final user = controller.user.value;

    return GestureDetector(
      onTap: () => Get.toNamed(AppRoutes.employeeEditProfile),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: width * 0.05,
          vertical: height * 0.02,
        ),
        color: Colors.white,
        child: Row(
          children: [
            Container(
              width: width * 0.25,
              height: width * 0.25,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.grey.shade300,
                image: user?.fullProfileImageUrl.isNotEmpty == true
                    ? DecorationImage(
                        image: NetworkImage(user!.fullProfileImageUrl),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: user?.fullProfileImageUrl.isNotEmpty != true
                  ? Icon(
                      Icons.person,
                      size: width * 0.12,
                      color: Colors.grey.shade500,
                    )
                  : null,
            ),
            SizedBox(width: width * 0.04),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user?.name ?? 'Employee',
                    style: TextStyle(
                      fontSize: width * 0.048,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  SizedBox(height: height * 0.005),
                  Text(
                    user?.mobile ?? '',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  if (user?.bestSeedsId.isNotEmpty == true) ...[
                    SizedBox(height: height * 0.003),
                    Text(
                      'ID: ${user!.bestSeedsId}',
                      style: TextStyle(
                        fontSize: width * 0.035,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: Colors.grey.shade400,
              size: width * 0.07,
            ),
          ],
        ),
      ),
    );
  }

  void _showLogoutDialog(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Logout',
            style: TextStyle(
              fontSize: width * 0.05,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Are you sure you want to logout?',
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                'Cancel',
                style: TextStyle(
                  fontSize: width * 0.04,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
            Obx(() => ElevatedButton(
                  onPressed: controller.isLoading.value
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          controller.logout();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0077C8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: controller.isLoading.value
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          'Logout',
                          style: TextStyle(
                            fontSize: width * 0.04,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                )),
          ],
        );
      },
    );
  }
}
