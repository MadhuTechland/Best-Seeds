import 'package:flutter/material.dart';

class ProfileMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final Color? iconColor;
  final bool isLogout;

  /// Unread count shown as a red pill before the chevron. 0 hides it.
  final int badgeCount;

  const ProfileMenuItem({
    super.key,
    required this.icon,
    required this.title,
    this.onTap,
    this.iconColor,
    this.isLogout = false,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: width * 0.05,
          vertical: height * 0.02,
        ),
        // decoration: BoxDecoration(
        //   color: isLogout ? const Color(0xFFF5F5F5) : Colors.white,
        //   border: Border(
        //     bottom: BorderSide(
        //       color: Colors.grey.shade200,
        //       width: 1,
        //     ),
        //   ),
        // ),
        child: Row(
          children: [
            Icon(
              icon,
              size: width * 0.06,
              color: iconColor ?? const Color(0xFF0077C8),
            ),
            SizedBox(width: width * 0.04),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: width * 0.042,
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                ),
              ),
            ),
            if (badgeCount > 0)
              Container(
                margin: EdgeInsets.only(right: width * 0.02),
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                constraints: const BoxConstraints(minWidth: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            Icon(
              Icons.chevron_right,
              size: width * 0.06,
              color: Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }
}
