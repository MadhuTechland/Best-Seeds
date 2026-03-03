import 'package:bestseeds/driver/models/driver_booking_model.dart';
import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/screens/driver_location_tracking.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DropLocationsBottomSheet extends StatefulWidget {
  final DriverRoute route;
  final double width;
  final double height;
  final VoidCallback onUpdate;

  const DropLocationsBottomSheet({
    required this.route,
    required this.width,
    required this.height,
    required this.onUpdate,
  });

  @override
  State<DropLocationsBottomSheet> createState() =>
      _DropLocationsBottomSheetState();
}

class _DropLocationsBottomSheetState extends State<DropLocationsBottomSheet> {
  late List<Map<String, dynamic>> dropLocations;
  final DriverAuthRepository _repo = DriverAuthRepository();
  final DriverStorageService _storage = DriverStorageService();
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    _initializeDropLocations();
  }

  void _initializeDropLocations() {
    // Initialize with actual booking data from the route
    final bookings = widget.route.bookings.map((booking) {
      return {
        'id': booking.id,
        'bookingUid': booking.bookingUid,
        'name': booking.customerName,
        'location': booking.droppingLocation ?? 'Unknown Location',
        'mobile': booking.customerMobile ?? '',
        'pieces': booking.noOfPieces,
        'status': _getStatusString(booking.status),
        'statusCode': booking.status,
      };
    }).toList();

    // Sort: completed (status 5) first, then others
    bookings.sort((a, b) {
      final aCompleted = a['statusCode'] == 5;
      final bCompleted = b['statusCode'] == 5;
      if (aCompleted && !bCompleted) return -1;
      if (!aCompleted && bCompleted) return 1;
      return 0;
    });

    dropLocations = bookings;
  }

  String _getStatusString(int status) {
    switch (status) {
      case 5:
        return 'Delivered';
      case 6:
        return 'Failed';
      default:
        return 'Pending';
    }
  }

  int _getStatusCode(String status) {
    switch (status) {
      case 'Delivered':
        return 5;
      case 'Failed':
        return 6;
      default:
        return 4; // In progress/pending
    }
  }

  // Check if this item should be blue (completed or is the current active one)
  bool _isItemCompleted(int index) {
    // Count completed items (status 5 - Delivered)
    int completedCount = 0;
    for (var loc in dropLocations) {
      if (loc['statusCode'] == 5) {
        completedCount++;
      }
    }

    // Items up to and including the first pending item should be blue
    // This creates the timeline effect where completed items and the current one are highlighted
    return index < completedCount || index == completedCount;
  }

  Future<void> _updateDropStatus() async {
    final token = _storage.getToken();
    if (token == null) {
      AppSnackbar.error('Session expired. Please login again.');
      return;
    }

    // Find items that have changed status
    final changedItems = dropLocations.where((loc) {
      final newStatusCode = _getStatusCode(loc['status']);
      return newStatusCode != loc['statusCode'] &&
          (newStatusCode == 5 ||
              newStatusCode ==
                  6); // Only update if changing to Delivered or Failed
    }).toList();

    if (changedItems.isEmpty) {
      Navigator.pop(context);
      return;
    }

    setState(() {
      _isUpdating = true;
    });

    try {
      // Update each changed item
      for (var item in changedItems) {
        final newStatusCode = _getStatusCode(item['status']);
        await _repo.updateDropStatus(
          token: token,
          bookingId: item['id'],
          status: newStatusCode,
        );

        // Update local status code after successful API call
        final index =
            dropLocations.indexWhere((loc) => loc['id'] == item['id']);
        if (index != -1) {
          dropLocations[index]['statusCode'] = newStatusCode;
        }
      }

      setState(() {
        _isUpdating = false;
      });

      bool _isJourneyCompleted() {
        return dropLocations
            .every((loc) => loc['statusCode'] == 5 || loc['statusCode'] == 6);
      }

      if (mounted) Navigator.pop(context);
      widget.onUpdate();
      AppSnackbar.success('Drop status updated successfully');
      if (_isJourneyCompleted()) {
        await DriverLocationService.stop();
        debugPrint('Journey completed. Location tracking stopped.');
      }
    } catch (e) {
      setState(() {
        _isUpdating = false;
      });
      AppSnackbar.error('Failed to update status. Please try again.');
      debugPrint('Error updating drop status: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final packingDate = widget.route.packingDate != null
        ? DateFormat('dd MMM yyyy').format(widget.route.packingDate!)
        : 'N/A';

    return Container(
      height: widget.height * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Column(
        children: [
          /// Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          /// Header Info
          Padding(
            padding: EdgeInsets.all(widget.width * 0.05),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  packingDate,
                  style: TextStyle(
                    fontSize: widget.width * 0.045,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: widget.height * 0.01),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'ID: ${widget.route.bookingIdsString}',
                      style: TextStyle(
                        fontSize: widget.width * 0.038,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${widget.route.totalDrops} Drops',
                      style: TextStyle(
                        fontSize: widget.width * 0.032,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: widget.height * 0.01),
                Text(
                  widget.route.hatcheryName,
                  style: TextStyle(
                    fontSize: widget.width * 0.042,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (widget.route.categoryName.isNotEmpty)
                  Text(
                    widget.route.categoryName,
                    style: TextStyle(
                      fontSize: widget.width * 0.035,
                      color: Colors.grey.shade600,
                    ),
                  ),
                SizedBox(height: widget.height * 0.02),
                Text(
                  'Drop locations',
                  style: TextStyle(
                    fontSize: widget.width * 0.04,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          /// Drop Locations List
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: widget.width * 0.05),
              itemCount: dropLocations.length,
              itemBuilder: (context, index) {
                final location = dropLocations[index];
                final isLast = index == dropLocations.length - 1;
                final isCompleted = _isItemCompleted(index);
                final isDelivered = location['statusCode'] == 5;

                return _buildDropLocationItem(
                  index: index + 1,
                  name: location['name'],
                  locationName: location['location'],
                  pieces: location['pieces'],
                  status: location['status'],
                  isLast: isLast,
                  isCompleted: isCompleted,
                  isDelivered: isDelivered,
                  onStatusChanged: (newStatus) {
                    setState(() {
                      dropLocations[index]['status'] = newStatus;
                    });
                  },
                );
              },
            ),
          ),

          /// Update Button
          Container(
            padding: EdgeInsets.all(widget.width * 0.05),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isUpdating ? null : _updateDropStatus,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0077C8),
                    disabledBackgroundColor:
                        const Color(0xFF0077C8).withValues(alpha: 0.6),
                    padding:
                        EdgeInsets.symmetric(vertical: widget.height * 0.018),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                  ),
                  child: _isUpdating
                      ? SizedBox(
                          height: widget.width * 0.05,
                          width: widget.width * 0.05,
                          child: const CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          'Update',
                          style: TextStyle(
                            fontSize: widget.width * 0.042,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropLocationItem({
    required int index,
    required String name,
    required String locationName,
    required int pieces,
    required String status,
    required bool isLast,
    required bool isCompleted,
    required bool isDelivered,
    required Function(String) onStatusChanged,
  }) {
    // Timeline colors based on completion status
    final Color timelineColor =
        isCompleted ? const Color(0xFF0077C8) : Colors.grey.shade400;

    final Color circleColor = isDelivered
        ? Colors.green
        : (isCompleted ? const Color(0xFF0077C8) : Colors.grey.shade400);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// Timeline
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: circleColor,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: isDelivered
                      ? const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 16,
                        )
                      : Text(
                          '$index',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: timelineColor,
                  ),
                ),
            ],
          ),
          SizedBox(width: widget.width * 0.03),

          /// Content
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: widget.height * 0.02),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: widget.width * 0.04,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          locationName,
                          style: TextStyle(
                            fontSize: widget.width * 0.038,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$pieces Pieces',
                          style: TextStyle(
                            fontSize: widget.width * 0.032,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),

                  /// Status Dropdown
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.width * 0.03,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isDelivered
                          ? Colors.green.shade50
                          : (status == 'Failed' ? Colors.red.shade50 : null),
                      border: Border.all(
                        color: isDelivered
                            ? Colors.green.shade300
                            : (status == 'Failed'
                                ? Colors.red.shade300
                                : Colors.grey.shade300),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: status,
                        isDense: true,
                        icon: const Icon(Icons.arrow_drop_down, size: 20),
                        style: TextStyle(
                          fontSize: widget.width * 0.035,
                          color: isDelivered
                              ? Colors.green.shade700
                              : (status == 'Failed'
                                  ? Colors.red.shade700
                                  : Colors.black87),
                          fontWeight: (isDelivered || status == 'Failed')
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        items: ['Pending', 'Delivered', 'Failed']
                            .map((String value) {
                          return DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          );
                        }).toList(),
                        onChanged: (newValue) {
                          if (newValue != null) {
                            onStatusChanged(newValue);
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
