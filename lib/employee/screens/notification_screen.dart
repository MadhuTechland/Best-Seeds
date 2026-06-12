import 'package:bestseeds/employee/controllers/notification_controller.dart';
import 'package:bestseeds/employee/models/tracking_alert_model.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class _GroupedAlert {
  final TrackingAlert representative;
  final List<int> bookingIds;
  final bool isRead;

  _GroupedAlert({
    required this.representative,
    required this.bookingIds,
    required this.isRead,
  });
}

List<_GroupedAlert> _groupAlerts(List<TrackingAlert> alerts) {
  final Map<String, _GroupedAlert> map = {};
  for (final alert in alerts) {
    final key = '${alert.driverId}_${alert.reason}_${alert.time}';
    if (map.containsKey(key)) {
      final existing = map[key]!;
      map[key] = _GroupedAlert(
        representative: existing.representative,
        // Don't add the same booking id twice — show each only once
        // (e.g. "851, 852" instead of "852, 851, 851, 852").
        bookingIds: existing.bookingIds.contains(alert.bookingId)
            ? existing.bookingIds
            : [...existing.bookingIds, alert.bookingId],
        isRead: existing.isRead && alert.isRead,
      );
    } else {
      map[key] = _GroupedAlert(
        representative: alert,
        bookingIds: [alert.bookingId],
        isRead: alert.isRead,
      );
    }
  }
  return map.values.toList();
}

class EmployeeNotificationScreen extends StatefulWidget {
  const EmployeeNotificationScreen({super.key});

  @override
  State<EmployeeNotificationScreen> createState() =>
      _EmployeeNotificationScreenState();
}

class _EmployeeNotificationScreenState extends State<EmployeeNotificationScreen> {
  late final EmployeeNotificationController controller;

  bool _markedRead = false;

  @override
  void initState() {
    super.initState();
    controller = Get.find<EmployeeNotificationController>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Just refresh the list so the screen shows the newest alerts (including
      // any that arrived while the screen was closed). DO NOT mark them as
      // read here — the user needs to actually see the blue dots first. The
      // mark-as-read call fires when the user navigates back.
      await controller.fetchAlerts();
    });
  }

  /// Fires the mark-as-read API exactly once, regardless of how the user
  /// leaves the screen (AppBar back arrow, system back gesture, hardware
  /// back button, or any other pop). Idempotent via [_markedRead].
  Future<void> _markReadOnExit() async {
    if (_markedRead) return;
    _markedRead = true;
    await controller.markAllRead();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return PopScope(
      // canPop: true means the system back gesture / hardware button will
      // pop the route normally; we just hook the callback to fire mark-read.
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _markReadOnExit();
        }
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.black, size: 20),
          onPressed: () {
            // Pop immediately so the back tap feels responsive; the
            // PopScope.onPopInvokedWithResult callback will fire mark-read
            // after the pop completes.
            Navigator.pop(context);
          },
        ),
        title: Text(
          'Notifications',
          style: TextStyle(
            fontSize: width * 0.05,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
      ),
      body: Obx(() {
        if (controller.alerts.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.notifications_off_outlined,
                  size: width * 0.2,
                  color: Colors.grey.shade400,
                ),
                SizedBox(height: height * 0.02),
                Text(
                  'No notifications',
                  style: TextStyle(
                    fontSize: width * 0.045,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: height * 0.01),
                Text(
                  'Driver tracking alerts will appear here',
                  style: TextStyle(
                    fontSize: width * 0.035,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          );
        }

        final grouped = _groupAlerts(controller.alerts);
        return RefreshIndicator(
          onRefresh: controller.fetchAlerts,
          child: ListView.builder(
            padding: EdgeInsets.symmetric(
              horizontal: width * 0.04,
              vertical: height * 0.015,
            ),
            itemCount: grouped.length,
            itemBuilder: (context, index) {
              return _buildAlertCard(grouped[index], width, height);
            },
          ),
        );
      }),
      ),
    );
  }

  Widget _buildAlertCard(
    _GroupedAlert group,
    double width,
    double height,
  ) {
    final alert = group.representative;
    final icon = _getAlertIcon(alert.reason);
    final color = _getAlertColor(alert.reason);

    return Container(
      margin: EdgeInsets.only(bottom: height * 0.012),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.all(width * 0.04),
            child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: width * 0.11,
              height: width * 0.11,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: width * 0.055),
            ),
            SizedBox(width: width * 0.03),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          alert.driverName,
                          style: TextStyle(
                            fontSize: width * 0.04,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      if (alert.time.isNotEmpty)
                        Text(
                          alert.time,
                          style: TextStyle(
                            fontSize: width * 0.03,
                            color: Colors.grey.shade500,
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: height * 0.005),
                  Text(
                    alert.reason,
                    style: TextStyle(
                      fontSize: width * 0.035,
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: height * 0.005),
                  Row(
                    children: [
                      Icon(
                        Icons.phone_outlined,
                        size: width * 0.035,
                        color: Colors.grey.shade500,
                      ),
                      SizedBox(width: width * 0.01),
                      Text(
                        alert.driverMobile,
                        style: TextStyle(
                          fontSize: width * 0.032,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                  if (alert.driverLocationName.isNotEmpty) ...[
                    SizedBox(height: height * 0.004),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: width * 0.035,
                          color: Colors.grey.shade500,
                        ),
                        SizedBox(width: width * 0.01),
                        Expanded(
                          child: Text(
                            alert.driverLocationName,
                            style: TextStyle(
                              fontSize: width * 0.032,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: height * 0.004),
                  Row(
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: width * 0.035,
                        color: Colors.grey.shade500,
                      ),
                      SizedBox(width: width * 0.01),
                      Expanded(
                        child: Text(
                          'Booking ID: ${group.bookingIds.join(', ')}',
                          style: TextStyle(
                            fontSize: width * 0.032,
                            color: Colors.grey.shade600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
            ),
          ),
          if (!group.isRead)
            Positioned(
              right: width * 0.03,
              bottom: width * 0.03,
              child: Container(
                width: width * 0.025,
                height: width * 0.025,
                decoration: const BoxDecoration(
                  color: Color(0xFF2196F3),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  IconData _getAlertIcon(String reason) {
    final lower = reason.toLowerCase();
    if (lower.contains('gps') || lower.contains('location')) {
      return Icons.location_off;
    } else if (lower.contains('internet') || lower.contains('network')) {
      return Icons.wifi_off;
    }
    return Icons.warning_amber_rounded;
  }

  Color _getAlertColor(String reason) {
    final lower = reason.toLowerCase();
    if (lower.contains('gps') || lower.contains('location')) {
      return Colors.orange.shade700;
    } else if (lower.contains('internet') || lower.contains('network')) {
      return Colors.red.shade600;
    }
    return Colors.amber.shade700;
  }
}
