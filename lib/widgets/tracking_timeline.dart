import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A single item in the tracking timeline
class TrackingTimelineItem {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String? time;
  final bool isCompleted;

  TrackingTimelineItem({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.time,
    this.isCompleted = false,
  });
}

/// A reusable timeline widget for tracking progress
class TrackingTimeline extends StatelessWidget {
  final List<TrackingTimelineItem> items;
  final Color completedColor;
  final Color pendingColor;
  final Color lineColor;

  const TrackingTimeline({
    super.key,
    required this.items,
    this.completedColor = Colors.green,
    this.pendingColor = Colors.grey,
    this.lineColor = const Color(0xFFE0E0E0),
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Column(
      children: List.generate(items.length, (index) {
        final item = items[index];
        final isLast = index == items.length - 1;

        return _buildTimelineItem(
          width,
          height,
          item,
          isLast: isLast,
        );
      }),
    );
  }

  Widget _buildTimelineItem(
    double width,
    double height,
    TrackingTimelineItem item, {
    bool isLast = false,
  }) {
    final iconColor = item.isCompleted ? completedColor : pendingColor;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: width * 0.08,
              height: width * 0.08,
              decoration: BoxDecoration(
                color: iconColor,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                item.icon,
                size: width * 0.045,
                color: Colors.white,
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: height * 0.05,
                color: lineColor,
              ),
          ],
        ),
        SizedBox(width: width * 0.04),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: TextStyle(
                            fontSize: width * 0.038,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (item.subtitle != null && item.subtitle!.isNotEmpty)
                          Text(
                            item.subtitle!,
                            style: TextStyle(
                              fontSize: width * 0.034,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (item.time != null && item.time!.isNotEmpty) ...[
                    SizedBox(width: width * 0.02),
                    Text(
                      item.time!,
                      style: TextStyle(
                        fontSize: width * 0.036,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ],
              ),
              if (!isLast) SizedBox(height: height * 0.01),
            ],
          ),
        ),
      ],
    );
  }
}

/// A reusable "Last Update" card widget
class LastUpdateCard extends StatelessWidget {
  final String? locationName;
  final String? updatedAt;
  final bool isActive;

  const LastUpdateCard({
    super.key,
    this.locationName,
    this.updatedAt,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    // Format the last update time
    String lastUpdateTime = '-';
    String lastUpdateDate = '';
    if (updatedAt != null) {
      try {
        final dateTime = DateTime.parse(updatedAt!);
        lastUpdateTime = DateFormat('hh:mm a').format(dateTime);
        lastUpdateDate = DateFormat('dd/MM/yyyy').format(dateTime);
      } catch (e) {
        lastUpdateTime = '-';
      }
    }

    final displayLocation = locationName ?? 'Location not available';

    return Container(
      padding: EdgeInsets.all(width * 0.04),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Last Update Title
          Text(
            'Last Update',
            style: TextStyle(
              fontSize: width * 0.04,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          SizedBox(height: height * 0.015),

          // Status indicator and time
          Row(
            children: [
              // Green dot indicator
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isActive ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: width * 0.03),
              // Time and date
              Text(
                '$lastUpdateTime, $lastUpdateDate',
                style: TextStyle(
                  fontSize: width * 0.038,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.01),

          // Location name
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: width * 0.055), // Align with text above
              Expanded(
                child: Text(
                  displayLocation,
                  style: TextStyle(
                    fontSize: width * 0.035,
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
    );
  }
}

/// Helper class for date/time formatting
class DateTimeHelper {
  static String formatTime(String? dateTimeStr) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '-';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      return DateFormat('hh:mm a').format(dateTime);
    } catch (e) {
      return '-';
    }
  }

  static String formatDate(String? dateTimeStr) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      return DateFormat('dd/MM/yyyy').format(dateTime);
    } catch (e) {
      return '';
    }
  }

  static String formatDateTime(String? dateTimeStr, {String format = 'dd/MM/yyyy hh:mm a'}) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '-';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      return DateFormat(format).format(dateTime);
    } catch (e) {
      return '-';
    }
  }
}
