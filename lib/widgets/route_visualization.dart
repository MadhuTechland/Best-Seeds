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

  if (dropLocations.isEmpty) {
    dropLocations.add('Drop Location');
  }

  final displayLocations = dropLocations.take(3).toList();
  final remaining = dropLocations.length - displayLocations.length;

  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFB),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.grey.shade200),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pickup location
        _buildLocationRow(
          icon: Icons.circle,
          iconColor: const Color(0xFF0077C8),
          iconSize: 10,
          label: 'PICKUP',
          labelColor: const Color(0xFF0077C8),
          location: startLocation,
          showConnector: true,
        ),

        // Drop locations
        for (int i = 0; i < displayLocations.length; i++)
          _buildLocationRow(
            icon: i == displayLocations.length - 1
                ? Icons.location_on_rounded
                : Icons.circle,
            iconColor: const Color(0xFF10B981),
            iconSize: i == displayLocations.length - 1 ? 18 : 10,
            label: displayLocations.length == 1
                ? 'DROP'
                : 'DROP ${i + 1}',
            labelColor: const Color(0xFF10B981),
            location: displayLocations[i],
            showConnector: i < displayLocations.length - 1,
          ),

        // Remaining count
        if (remaining > 0)
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '+$remaining more drop${remaining > 1 ? 's' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

Widget _buildLocationRow({
  required IconData icon,
  required Color iconColor,
  required double iconSize,
  required String label,
  required Color labelColor,
  required String location,
  required bool showConnector,
}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Icon column with connector
      SizedBox(
        width: 20,
        child: Column(
          children: [
            const SizedBox(height: 2),
            Icon(icon, size: iconSize, color: iconColor),
            if (showConnector)
              Container(
                width: 1.5,
                height: 28,
                margin: const EdgeInsets.symmetric(vertical: 2),
                color: Colors.grey.shade300,
              ),
          ],
        ),
      ),

      const SizedBox(width: 8),

      // Location text
      Expanded(
        child: Padding(
          padding: EdgeInsets.only(bottom: showConnector ? 0 : 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: labelColor,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                location,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1F2937),
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
