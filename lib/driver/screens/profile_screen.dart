import 'package:bestseeds/announcement/announcement_controller.dart';
import 'package:bestseeds/announcement/announcements_screen.dart';
import 'package:bestseeds/driver/controllers/profile_controller.dart';
import 'package:bestseeds/driver/widgets/driver_permissions_section.dart';
import 'package:bestseeds/employee/screens/help_screen.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/screens/privacy_policy_screen.dart';
import 'package:bestseeds/screens/terms_and_conditions_screen.dart';
import 'package:bestseeds/widgets/profile_menu_item.dart';
import 'package:bestseeds/widgets/app_version_text.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

class DriverProfileScreen extends StatelessWidget {
  DriverProfileScreen({super.key});

  final DriverProfileController controller = Get.put(DriverProfileController());
  // Shared permanent instance — the badge stays in step with the popup service.
  final AnnouncementController announcementController = AnnouncementController.to;

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
                    // Device permission toggles (Location + Background battery),
                    // reflecting real OS state and synced to the admin panel.
                    const DriverPermissionsSection(),
                    SizedBox(height: height * 0.01),
                    ProfileMenuItem(
                      icon: Icons.notifications_outlined,
                      title: 'Notification',
                      onTap: () {},
                    ),
                    Obx(() => ProfileMenuItem(
                          icon: Icons.campaign_outlined,
                          title: 'Announcements',
                          badgeCount: announcementController.unreadCount.value,
                          onTap: () => Get.to(() => const AnnouncementsScreen()),
                        )),
                    ProfileMenuItem(
                      icon: Icons.local_shipping_outlined,
                      title: 'My Deliveries',
                      onTap: () => Get.toNamed(AppRoutes.driverMyDeliveries),
                    ),
                    ProfileMenuItem(
                      icon: Icons.help_outline,
                      title: 'Help',
                      onTap: () => Get.to(() => const HelpScreen()),
                    ),
                    ProfileMenuItem(
                      icon: Icons.share_outlined,
                      title: 'Share this app',
                      onTap: () {
                        Share.share(
                          'Check out Bestseed - the best app for seed delivery management!\nhttps://play.google.com/store/apps/details?id=com.bestseeds.app',
                        );
                      },
                    ),
                    ProfileMenuItem(
                      icon: Icons.description_outlined,
                      title: 'Terms & conditions',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TermsAndConditionsScreen(),
                        ),
                      ),
                    ),
                    ProfileMenuItem(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Privacy Policy',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PrivacyPolicyScreen(),
                        ),
                      ),
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

            // App version — reads the built version, so a release bump in
            // pubspec is all that is needed. See AppVersionText.
            const SizedBox(height: 24),
            const AppVersionText(),
            const SizedBox(height: 24),
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
          IconButton(
              icon: const Icon(
                Icons.arrow_back_ios,
                color: Colors.black,
                size: 20,
              ),
              onPressed: () {
                Navigator.pop(context);
              }),
          SizedBox(
            width: width * 0.02,
          ),
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
    final driver = controller.driver.value;

    return GestureDetector(
      onTap: () => Get.toNamed(AppRoutes.driverEditProfile),
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
                image: driver?.fullProfileImageUrl.isNotEmpty == true
                    ? DecorationImage(
                        image: NetworkImage(driver!.fullProfileImageUrl),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: driver?.fullProfileImageUrl.isNotEmpty != true
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
                    driver?.name ?? 'Driver',
                    style: TextStyle(
                      fontSize: width * 0.048,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  SizedBox(height: height * 0.005),
                  Text(
                    driver?.mobile ?? '',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: Colors.grey.shade600,
                    ),
                  ),
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
