import 'package:flutter/material.dart';
import 'package:bestseeds/driver/models/driver_booking_model.dart';

Widget buildRouteVisualization(
    double width, double height, DriverRoute route) {
  final startLocation = route.startLocationName;
  final drops = route.bookings;

  // Get unique drop locations
  final dropLocations = drops
      .map((d) => d.droppingLocation ?? 'Unknown')
      .where((loc) => loc.isNotEmpty && loc != 'Unknown')
      .toSet()
      .toList();

  // If no drop locations, show at least "Drop Location"
  if (dropLocations.isEmpty) {
    dropLocations.add('Drop Location');
  }

  // Limit to max 3 locations for display
  final displayLocations = dropLocations.take(3).toList();
  final lastLocation = displayLocations.last;

  return Container(
    padding: EdgeInsets.symmetric(
      vertical: height * 0.018,
      horizontal: width * 0.04,
    ),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAF8),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.grey.shade200),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Truck Icon
        Container(
          padding: EdgeInsets.all(width * 0.028),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withValues(alpha: 0.15),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            Icons.local_shipping_rounded,
            size: width * 0.06,
            color: const Color(0xFF3D3D3D),
          ),
        ),

        SizedBox(width: width * 0.025),

        // Route with locations
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Start location
                _buildLocationCard(
                  width: width,
                  locationName: startLocation,
                  isStart: true,
                  isEnd: false,
                ),

                // Arrow connector
                _buildArrowConnector(width),

                // Intermediate locations (if more than 1)
                if (displayLocations.length > 1)
                  for (int i = 0; i < displayLocations.length - 1; i++) ...[
                    _buildLocationCard(
                      width: width,
                      locationName: displayLocations[i],
                      isStart: false,
                      isEnd: false,
                    ),
                    _buildArrowConnector(width),
                  ],

                // End location with green highlight
                _buildLocationCard(
                  width: width,
                  locationName: lastLocation,
                  isStart: false,
                  isEnd: true,
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _buildLocationCard({
  required double width,
  required String locationName,
  required bool isStart,
  required bool isEnd,
}) {
  // Parse location into parts (split by comma)
  final parts = locationName
      .split(',')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  // Colors based on position
  final Color color;
  final Color bgColor;
  final Color borderColor;

  if (isEnd) {
    color = const Color(0xFF2E7D32);
    bgColor = const Color(0xFFE8F5E9);
    borderColor = const Color(0xFF81C784);
  } else if (isStart) {
    color = const Color(0xFF1565C0);
    bgColor = const Color(0xFFE3F2FD);
    borderColor = const Color(0xFF64B5F6);
  } else {
    color = const Color(0xFF5D5D5D);
    bgColor = Colors.white;
    borderColor = Colors.grey.shade300;
  }

  // Calculate max width for location card (prevent taking too much space)
  final maxCardWidth = width * 0.35;

  return Container(
    constraints: BoxConstraints(maxWidth: maxCardWidth),
    padding: EdgeInsets.symmetric(
      horizontal: width * 0.025,
      vertical: width * 0.02,
    ),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: borderColor, width: (isEnd || isStart) ? 1.5 : 1),
      boxShadow: (isEnd || isStart)
          ? [
              BoxShadow(
                color: (isEnd ? Colors.green : Colors.blue).withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ]
          : null,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Location pin icon
        Padding(
          padding: EdgeInsets.only(top: width * 0.005),
          child: Icon(
            (isEnd || isStart) ? Icons.location_on : Icons.location_on_outlined,
            size: width * 0.04,
            color: color,
          ),
        ),
        SizedBox(width: width * 0.01),
        // Location text - multi-line with constraint
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildLocationTextLines(parts, locationName, width, color, isEnd || isStart),
          ),
        ),
      ],
    ),
  );
}

List<Widget> _buildLocationTextLines(
  List<String> parts,
  String fullLocation,
  double width,
  Color color,
  bool isBold,
) {
  if (parts.length > 1) {
    // Show each part on a new line (max 3 lines)
    return parts
        .take(3)
        .map((part) => Text(
              part,
              style: TextStyle(
                fontSize: width * 0.03,
                fontWeight: isBold ? FontWeight.w600 : FontWeight.w500,
                color: color,
                height: 1.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ))
        .toList();
  } else {
    // Single line location - wrap if too long
    return [
      Text(
        fullLocation,
        style: TextStyle(
          fontSize: width * 0.032,
          fontWeight: isBold ? FontWeight.w600 : FontWeight.w500,
          color: color,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ];
  }
}

Widget _buildArrowConnector(double width) {
  return Padding(
    padding: EdgeInsets.symmetric(horizontal: width * 0.012),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Dashed line
        ...List.generate(
          3,
          (index) => Container(
            width: 4,
            height: 2,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
        // Arrow head
        Icon(
          Icons.arrow_forward_ios_rounded,
          size: width * 0.032,
          color: Colors.grey.shade500,
        ),
      ],
    ),
  );
}
