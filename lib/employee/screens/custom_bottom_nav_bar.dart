import 'package:flutter/material.dart';

class EmployeeBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;

  const EmployeeBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Container(
      height: height * 0.08,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(
            context,
            index: 0,
            icon: Icons.home_outlined,
            activeIcon: Icons.home,
            label: 'Home',
            width: width,
          ),
          _buildNavItem(
            context,
            index: 1,
            icon: Icons.receipt_long_outlined,
            activeIcon: Icons.receipt_long,
            label: 'Booking',
            width: width,
          ),
          _buildNavItem(
            context,
            index: 2,
            icon: Icons.local_shipping_outlined,
            activeIcon: Icons.local_shipping,
            label: 'Tracking',
            width: width,
          ),
          _buildNavItem(
            context,
            index: 3,
            icon: Icons.person_outline,
            activeIcon: Icons.person,
            label: 'Profile',
            width: width,
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required int index,
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required double width,
  }) {
    final isActive = currentIndex == index;
    final iconSize = width * 0.065;
    final fontSize = width * 0.032;

    return GestureDetector(
      onTap: () => onTap(index),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: width * 0.04,
          vertical: 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              color: isActive ? const Color(0xFF0077C8) : Colors.grey,
              size: iconSize,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? const Color(0xFF0077C8) : Colors.grey,
                fontSize: fontSize,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
