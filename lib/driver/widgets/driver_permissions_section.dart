import 'package:bestseeds/driver/controllers/driver_permissions_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Profile-screen section with two independent toggles letting the driver
/// enable the permissions the journey needs — Location (GPS) and Battery
/// optimization exemption (background tracking). Each toggle reflects the real
/// device state, lets the driver enable it, and the state is synced to the
/// backend so the admin can see it. Re-checks the system whenever the app
/// resumes (so it updates after the driver returns from the Settings screen).
class DriverPermissionsSection extends StatefulWidget {
  const DriverPermissionsSection({super.key});

  @override
  State<DriverPermissionsSection> createState() =>
      _DriverPermissionsSectionState();
}

class _DriverPermissionsSectionState extends State<DriverPermissionsSection>
    with WidgetsBindingObserver {
  final DriverPermissionsController controller =
      Get.put(DriverPermissionsController());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Re-read the REAL device permission state every time the profile opens
    // (the controller may be a cached singleton holding a stale value), and
    // sync it so the toggle AND the admin panel reflect reality immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.refreshFromSystem(sync: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Driver may have just toggled the permission in device Settings.
    if (state == AppLifecycleState.resumed) {
      controller.refreshFromSystem(sync: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: width * 0.05, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Permissions',
                style: TextStyle(
                  fontSize: width * 0.042,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(width: 8),
              Obx(
                () => controller.isChecking.value
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              children: [
                Obx(
                  () => _permissionTile(
                    icon: Icons.location_on_outlined,
                    title: 'Location',
                    subtitle:
                        'Required to track your deliveries while on a journey.',
                    value: controller.locationGranted.value,
                    onChanged: (want) {
                      if (want) {
                        // OFF → enabling: show the OS system dialog (request).
                        controller.enableLocation();
                      } else {
                        // ON → disabling: open the app's settings page so the
                        // driver can revoke it (Permissions → Location), since
                        // Android has no in-app dialog to turn it off.
                        controller.openManageSettings();
                      }
                    },
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Obx(
                  () => _permissionTile(
                    icon: Icons.battery_charging_full_outlined,
                    title: 'Background (Battery)',
                    subtitle:
                        'Keeps live tracking running when the screen is off.',
                    value: controller.batteryDisabled.value,
                    onChanged: (want) {
                      if (want) {
                        controller.enableBattery();
                      } else {
                        controller.openManageSettings();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    // Whole row is tappable — tapping anywhere on the option triggers the same
    // action as the toggle (request/enable when Off, open settings when On), so
    // the user is redirected regardless of the current On/Off state. Tapping the
    // Switch directly is still handled by the Switch itself.
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (value ? const Color(0xFF0077C8) : Colors.grey)
                  .withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 20,
              color: value ? const Color(0xFF0077C8) : Colors.grey.shade600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: value
                            ? const Color(0xFF2E7D32).withOpacity(0.12)
                            : const Color(0xFFC62828).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        value ? 'On' : 'Off',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: value
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFFC62828),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeColor: const Color(0xFF0077C8),
            onChanged: onChanged,
          ),
        ],
      ),
      ),
    );
  }
}
