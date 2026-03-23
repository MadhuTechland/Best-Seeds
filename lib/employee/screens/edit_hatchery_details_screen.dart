import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:bestseeds/widgets/location_selector_screen.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Model for driver dropdown
class DriverItem {
  final int id;
  final String name;
  final String mobile;
  final String displayName;

  DriverItem({
    required this.id,
    required this.name,
    required this.mobile,
    required this.displayName,
  });

  factory DriverItem.fromJson(Map<String, dynamic> json) {
    return DriverItem(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      mobile: json['mobile'] ?? '',
      displayName:
          json['display_name'] ?? '${json['name']} - ${json['mobile']}',
    );
  }
}

class EditHatcheryDetailsScreen extends StatefulWidget {
  final Booking booking;

  const EditHatcheryDetailsScreen({
    super.key,
    required this.booking,
  });

  @override
  State<EditHatcheryDetailsScreen> createState() =>
      _EditHatcheryDetailsScreenState();
}

class _EditHatcheryDetailsScreenState extends State<EditHatcheryDetailsScreen> {
  final AuthRepository _repo = AuthRepository();
  final StorageService _storage = StorageService();

  late TextEditingController _piecesController;
  late TextEditingController _dropLocationController;
  late TextEditingController _travelCostController;
  late TextEditingController _bookingDescriptionController;
  late TextEditingController _vehicleDescriptionController;

  int? _selectedSalinity;
  DateTime? _preferredDate;
  DateTime? _expectedDeliveryDate;
  double? _selectedLatitude;
  double? _selectedLongitude;
  bool _isRemovingDriver = false;
  bool _isSaving = false;
  int? _selectedBookingStatus;
  int? _selectedDeliveryReason;

  final Map<int, String> _statusLabels = {
    1: 'Pending',
    2: 'Confirmed',
    3: 'Driver Assigned',
    4: 'In Transit',
    5: 'Delivered',
    6: 'Failed',
  };

  final Map<int, String> _failedReasons = {
    1: 'Delay in processing',
    2: 'Incorrect order details',
    3: 'Wrong quantity requested',
    4: 'Stock quality issues',
    5: 'Other',
  };

  // Salinity values from 1 to 40
  final List<int> _salinityValues = List.generate(40, (index) => index + 1);

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    _piecesController =
        TextEditingController(text: widget.booking.noOfPieces.toString());
    _dropLocationController =
        TextEditingController(text: widget.booking.droppingLocation);

    // Initialize travel cost from model (show only if > 0)
    _travelCostController = TextEditingController(
      text: widget.booking.travelCost > 0
          ? widget.booking.travelCost.toStringAsFixed(0)
          : '',
    );

    // Initialize booking description from model
    _bookingDescriptionController = TextEditingController(
      text: widget.booking.bookingDescription ?? '',
    );

    // Initialize vehicle description from model
    _vehicleDescriptionController = TextEditingController(
      text: widget.booking.vehicleDescription ?? '',
    );

    // Initialize salinity from model (only if value is in valid range 1-40)
    final salinity = widget.booking.salinity;
    _selectedSalinity = (salinity != null && salinity >= 1 && salinity <= 40) ? salinity : null;

    // Initialize dates from model
    if (widget.booking.preferredDate != null &&
        widget.booking.preferredDate!.isNotEmpty) {
      _preferredDate = _parseDate(widget.booking.preferredDate!);
    }
    if (widget.booking.deliveryDatetime != null &&
        widget.booking.deliveryDatetime!.isNotEmpty) {
      _expectedDeliveryDate = _parseDate(widget.booking.deliveryDatetime!);
    }

    // Initialize location from model
    _selectedLatitude = widget.booking.latitude;
    _selectedLongitude = widget.booking.longitude;

    // Initialize booking status
    _selectedBookingStatus = widget.booking.status.value;
  }

  DateTime? _parseDate(String dateString) {
    try {
      // Try different date formats
      final formats = [
        'yyyy-MM-dd',
        'dd/MM/yyyy',
        'MM/dd/yyyy',
        'yyyy-MM-dd HH:mm:ss',
      ];
      for (final format in formats) {
        try {
          return DateFormat(format).parse(dateString);
        } catch (_) {}
      }
      return DateTime.tryParse(dateString);
    } catch (_) {
      return null;
    }
  }

  String _formatDate(DateTime date) {
    return DateFormat('dd/MM/yyyy').format(date);
  }

  String _formatDateForApi(DateTime date) {
    return DateFormat('yyyy-MM-dd').format(date);
  }

  @override
  void dispose() {
    _piecesController.dispose();
    _dropLocationController.dispose();
    _travelCostController.dispose();
    _bookingDescriptionController.dispose();
    _vehicleDescriptionController.dispose();
    super.dispose();
  }

  Future<void> _selectPreferredDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _preferredDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0077C8),
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _preferredDate = picked;
      });
    }
  }

  Future<void> _selectExpectedDeliveryDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _expectedDeliveryDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0077C8),
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _expectedDeliveryDate = picked;
      });
    }
  }

  Future<void> _showLocationOptions() async {
    final result = await LocationSelector.show(
      context: context,
      initialLatitude: _selectedLatitude ?? widget.booking.latitude,
      initialLongitude: _selectedLongitude ?? widget.booking.longitude,
    );

    if (result != null) {
      setState(() {
        _selectedLatitude = result.latitude;
        _selectedLongitude = result.longitude;
        _dropLocationController.text = result.address;
      });
    }
  }

  Future<void> _saveDetails() async {
    final token = _storage.getToken();
    if (token == null) {
      AppSnackbar.error('Session expired. Please login again.');
      return;
    }

    // Validate required fields
    if (_piecesController.text.isEmpty) {
      AppSnackbar.error('Please enter number of pieces');
      return;
    }

    if (_dropLocationController.text.isEmpty) {
      AppSnackbar.error('Please enter drop location');
      return;
    }

    if (_preferredDate == null) {
      AppSnackbar.error('Please select preferred date');
      return;
    }

    // Validate status transition
    if (_selectedBookingStatus != null &&
        _selectedBookingStatus != widget.booking.status.value) {
      if (_selectedBookingStatus == 5 && widget.booking.status.value != 4) {
        AppSnackbar.error(
            'Booking must be In Transit to mark as Delivered');
        return;
      }
      if (_selectedBookingStatus == 6 && _selectedDeliveryReason == null) {
        AppSnackbar.error('Please select a failed reason');
        return;
      }
    }

    setState(() => _isSaving = true);

    try {
      // Parse pieces - remove commas if present
      final piecesText = _piecesController.text.replaceAll(',', '');
      final pieces = int.tryParse(piecesText) ?? 0;

      // Parse travel cost - remove ₹ symbol and commas
      final travelCostText = _travelCostController.text
          .replaceAll('₹', '')
          .replaceAll(',', '')
          .trim();

      await _repo.updateBooking(
        token: token,
        bookingId: widget.booking.bookingId,
        noOfPieces: pieces,
        salinity: _selectedSalinity?.toString() ?? '',
        dropLocation: _dropLocationController.text,
        preferredDate:
            _preferredDate != null ? _formatDateForApi(_preferredDate!) : '',
        travelCost: travelCostText,
        expectedDeliveryDate: _expectedDeliveryDate != null
            ? _formatDateForApi(_expectedDeliveryDate!)
            : '',
        bookingDescription: _bookingDescriptionController.text.isNotEmpty
            ? _bookingDescriptionController.text
            : null,
        vehicleDescription: _vehicleDescriptionController.text.isNotEmpty
            ? _vehicleDescriptionController.text
            : null,
        dropLat: _selectedLatitude,
        dropLng: _selectedLongitude,
        status: _selectedBookingStatus != widget.booking.status.value
            ? _selectedBookingStatus
            : null,
        deliveryReason: _selectedBookingStatus == 6
            ? _selectedDeliveryReason
            : null,
      );

      AppSnackbar.success('Booking updated successfully');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            /// ================= Header =================
            _buildHeader(context, width, height),

            /// ================= Content =================
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(width * 0.05),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    /// Title
                    Text(
                      widget.booking.hatcheryName,
                      style: TextStyle(
                        fontSize: width * 0.048,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: height * 0.015),

                    /// Booking ID and Status
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'ID: ${widget.booking.bookingId}',
                          style: TextStyle(
                            fontSize: width * 0.038,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: width * 0.02,
                            vertical: height * 0.004,
                          ),
                          decoration: BoxDecoration(
                            color: _getStatusColor(widget.booking.status)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            widget.booking.status.displayLabel,
                            style: TextStyle(
                              fontSize: width * 0.032,
                              color: _getStatusColor(widget.booking.status),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: height * 0.03),

                    /// Category (Read-only display)
                    _buildReadOnlyField(
                      width,
                      height,
                      'Category',
                      widget.booking.categoryName,
                    ),
                    SizedBox(height: height * 0.025),

                    /// Pieces
                    _buildTextField(width, height, 'Pieces', _piecesController,
                        TextInputType.number),
                    SizedBox(height: height * 0.025),

                    /// Salinity Dropdown (1-40)
                    _buildSalinityDropdown(width, height),
                    SizedBox(height: height * 0.025),

                    /// Drop location with location picker
                    _buildLocationField(width, height),
                    SizedBox(height: height * 0.025),

                    /// Preferred Date with calendar
                    _buildDateField(
                      width,
                      height,
                      'Preferred Date',
                      _preferredDate,
                      _selectPreferredDate,
                    ),
                    SizedBox(height: height * 0.025),

                    /// Travel Cost
                    _buildTextField(width, height, 'Travel Cost',
                        _travelCostController, TextInputType.number),
                    SizedBox(height: height * 0.025),

                    /// Expected Delivery Date with calendar
                    _buildDateField(
                      width,
                      height,
                      'Expected Delivery Date',
                      _expectedDeliveryDate,
                      _selectExpectedDeliveryDate,
                    ),
                    SizedBox(height: height * 0.025),

                    /// Booking Description
                    _buildTextArea(width, height, 'Booking Status',
                        _bookingDescriptionController),
                    SizedBox(height: height * 0.025),

                    /// Vehicle Description
                    _buildTextArea(width, height, 'Vehicle Status',
                        _vehicleDescriptionController),
                    SizedBox(height: height * 0.025),

                    /// Booking Status Dropdown
                    _buildBookingStatusDropdown(width, height),
                    SizedBox(height: height * 0.025),

                    /// Failed Reason (shown only when Failed is selected)
                    if (_selectedBookingStatus == 6) ...[
                      _buildFailedReasonDropdown(width, height),
                      SizedBox(height: height * 0.025),
                    ],

                    /// Driver Buttons
                    Row(
                      children: [
                        Expanded(
                          child: _buildOutlineButton(
                            width,
                            height,
                            widget.booking.driverDetails.isAssigned
                                ? 'Change Driver'
                                : 'Add Driver',
                            widget.booking.driverDetails.isAssigned
                                ? Icons.swap_horiz
                                : Icons.add,
                            () => _showChangeDriverBottomSheet(context),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: height * 0.03),
                    if (widget.booking.driverDetails.isAssigned) ...[
                      _buildDriverInfoCard(width, height),
                    ]
                  ],
                ),
              ),
            ),

            /// ================= Save Button =================
            _buildSaveButton(width, height),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(BookingStatus status) {
    if (status.isPending) return Colors.orange;
    if (status.isConfirmed) return Colors.blue;
    if (status.isDriverAssigned) return Colors.purple;
    if (status.isInProgress) return Colors.teal;
    if (status.isCompleted) return Colors.green;
    if (status.isFailed) return Colors.red;
    return Colors.grey;
  }

  List<int> _getAllowedStatuses() {
    final current = widget.booking.status.value;
    switch (current) {
      case 1:
        return [1, 2, 6];
      case 2:
        return [2, 3, 6];
      case 3:
        return [3, 4, 6];
      case 4:
        return [4, 5, 6];
      default:
        return [current];
    }
  }

  Widget _buildBookingStatusDropdown(double width, double height) {
    final allowedStatuses = _getAllowedStatuses();
    final isTerminal =
        widget.booking.status.value == 5 || widget.booking.status.value == 6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Booking Status',
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.005,
          ),
          decoration: BoxDecoration(
            color: isTerminal ? Colors.grey.shade200 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedBookingStatus,
              isExpanded: true,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: width * 0.06,
                color: isTerminal ? Colors.grey : Colors.black,
              ),
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey.shade700,
              ),
              items: allowedStatuses.map((int status) {
                final label = _statusLabels[status] ?? 'Status $status';
                final isCurrent = status == widget.booking.status.value;
                return DropdownMenuItem<int>(
                  value: status,
                  child: Text(
                    isCurrent ? '$label (Current)' : label,
                    style: TextStyle(
                      color: isCurrent ? Colors.grey.shade500 : Colors.black,
                    ),
                  ),
                );
              }).toList(),
              onChanged: isTerminal
                  ? null
                  : (value) {
                      setState(() {
                        _selectedBookingStatus = value;
                        if (value != 6) {
                          _selectedDeliveryReason = null;
                        }
                      });
                    },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFailedReasonDropdown(double width, double height) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Failed Reason',
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.005,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedDeliveryReason,
              hint: Text(
                'Select Reason',
                style: TextStyle(
                  fontSize: width * 0.04,
                  color: Colors.grey.shade500,
                ),
              ),
              isExpanded: true,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: width * 0.06,
                color: Colors.black,
              ),
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey.shade700,
              ),
              items: _failedReasons.entries.map((entry) {
                return DropdownMenuItem<int>(
                  value: entry.key,
                  child: Text(entry.value),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedDeliveryReason = value;
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, double width, double height) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.02,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.shade200,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              Navigator.pop(context);
            },
            child: Icon(
              Icons.arrow_back,
              size: width * 0.06,
              color: Colors.black,
            ),
          ),
          SizedBox(width: width * 0.03),
          Text(
            'Edit Hatchery Details',
            style: TextStyle(
              fontSize: width * 0.048,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadOnlyField(
    double width,
    double height,
    String label,
    String value,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.018,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            value.isNotEmpty ? value : 'N/A',
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSalinityDropdown(double width, double height) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Salinity',
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.005,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedSalinity,
              hint: Text(
                'Select Salinity (1-40)',
                style: TextStyle(
                  fontSize: width * 0.04,
                  color: Colors.grey.shade500,
                ),
              ),
              isExpanded: true,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: width * 0.06,
                color: Colors.black,
              ),
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey.shade700,
              ),
              items: _salinityValues.map((int value) {
                return DropdownMenuItem<int>(
                  value: value,
                  child: Text('$value'),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedSalinity = value;
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationField(double width, double height) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Drop Location',
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        GestureDetector(
          onTap: _showLocationOptions,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: width * 0.04,
              vertical: height * 0.018,
            ),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _dropLocationController.text.isNotEmpty
                        ? _dropLocationController.text
                        : 'Select location',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: _dropLocationController.text.isNotEmpty
                          ? Colors.grey.shade700
                          : Colors.grey.shade500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  Icons.location_on,
                  size: width * 0.06,
                  color: const Color(0xFF0077C8),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDateField(
    double width,
    double height,
    String label,
    DateTime? selectedDate,
    VoidCallback onTap,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: width * 0.04,
              vertical: height * 0.018,
            ),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selectedDate != null
                        ? _formatDate(selectedDate)
                        : 'Select date',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: selectedDate != null
                          ? Colors.grey.shade700
                          : Colors.grey.shade500,
                    ),
                  ),
                ),
                Icon(
                  Icons.calendar_today,
                  size: width * 0.05,
                  color: const Color(0xFF0077C8),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField(
    double width,
    double height,
    String label,
    TextEditingController controller, [
    TextInputType? keyboardType,
  ]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.005,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextArea(
    double width,
    double height,
    String label,
    TextEditingController controller,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.01,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            maxLines: 3,
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOutlineButton(
    double width,
    double height,
    String label,
    IconData icon,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: height * 0.018,
        ),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: width * 0.05,
              color: Colors.black,
            ),
            SizedBox(width: width * 0.02),
            Text(
              label,
              style: TextStyle(
                fontSize: width * 0.038,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showChangeDriverBottomSheet(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    final existingDriver = widget.booking.driverDetails;
    final bool isEditing = existingDriver.isAssigned;

    // Pre-fill with existing data if editing
    final TextEditingController vehicleNumberController =
        TextEditingController(text: isEditing ? existingDriver.vehicleNumber : '');

    bool isLoading = false;
    bool isLoadingDrivers = true;
    List<DriverItem> drivers = [];
    DriverItem? selectedDriver;

    // Add New Driver mode
    bool isAddNewDriver = false;
    final TextEditingController newDriverNameController = TextEditingController();
    final TextEditingController newDriverMobileController = TextEditingController();

    // Pre-fill dates from existing driver data
    DateTime? vehicleStartDate = isEditing && existingDriver.vehicleStartDate != null
        ? DateTime.tryParse(existingDriver.vehicleStartDate!)
        : null;
    DateTime? vehicleEndDate = isEditing && existingDriver.vehicleEndDate != null
        ? DateTime.tryParse(existingDriver.vehicleEndDate!)
        : null;

    // Pre-fill priority from existing driver data (must be within 1-10 range)
    final existingPriority = isEditing ? existingDriver.priority : null;
    int? selectedPriority = (existingPriority != null && existingPriority >= 1 && existingPriority <= 10)
        ? existingPriority
        : null;

    // Pre-fill location from existing driver data
    double? vehicleStartLat = isEditing ? existingDriver.vehicleStartLat : null;
    double? vehicleStartLng = isEditing ? existingDriver.vehicleStartLng : null;
    String? vehicleStartAddress = isEditing ? existingDriver.vehicleStartAddress : null;

    // Fetch drivers list
    Future<void> fetchDrivers(StateSetter setModalState) async {
      final token = _storage.getToken();
      if (token == null) return;

      try {
        final response = await _repo.getDrivers(token: token);
        if (response['status'] == true && response['drivers'] != null) {
          drivers = (response['drivers'] as List)
              .map((e) => DriverItem.fromJson(e))
              .toList();

          // Pre-select existing driver if editing
          if (isEditing && existingDriver.driverId != null) {
            for (final driver in drivers) {
              if (driver.id == existingDriver.driverId) {
                selectedDriver = driver;
                break;
              }
            }
          }
        }
      } catch (e) {
        AppSnackbar.error('Failed to load drivers');
      } finally {
        setModalState(() => isLoadingDrivers = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // Fetch drivers on first build
            if (isLoadingDrivers && drivers.isEmpty) {
              fetchDrivers(setModalState);
            }

            return Container(
              margin: const EdgeInsets.only(top: 16),
              constraints: BoxConstraints(
                maxHeight: height * 0.85,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  /// ================= Header =================
                  Container(
                    padding: EdgeInsets.all(width * 0.05),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: Colors.grey.shade200,
                          width: 1,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.booking.driverDetails.isAssigned
                              ? 'Change Driver'
                              : 'Add Driver',
                          style: TextStyle(
                            fontSize: width * 0.048,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Icon(Icons.close, size: width * 0.06),
                        ),
                      ],
                    ),
                  ),

                  /// ================= Content (keyboard aware) =================
                  Flexible(
                    child: AnimatedPadding(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(width * 0.05),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildBookingInfoCard(width, height),
                            SizedBox(height: height * 0.03),
                            Text(
                              'Driver Details',
                              style: TextStyle(
                                fontSize: width * 0.042,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: height * 0.02),

                            /// ================= Toggle: Existing / Add New =================
                            Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => setModalState(() {
                                      isAddNewDriver = false;
                                    }),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                          vertical: height * 0.012),
                                      decoration: BoxDecoration(
                                        color: !isAddNewDriver
                                            ? const Color(0xFF0077C8)
                                            : Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Center(
                                        child: Text(
                                          'Select Existing',
                                          style: TextStyle(
                                            fontSize: width * 0.036,
                                            fontWeight: FontWeight.w600,
                                            color: !isAddNewDriver
                                                ? Colors.white
                                                : Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: width * 0.03),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => setModalState(() {
                                      isAddNewDriver = true;
                                      selectedDriver = null;
                                    }),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                          vertical: height * 0.012),
                                      decoration: BoxDecoration(
                                        color: isAddNewDriver
                                            ? const Color(0xFF0077C8)
                                            : Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Center(
                                        child: Text(
                                          'Add New Driver',
                                          style: TextStyle(
                                            fontSize: width * 0.036,
                                            fontWeight: FontWeight.w600,
                                            color: isAddNewDriver
                                                ? Colors.white
                                                : Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: height * 0.02),

                            /// ================= Driver Selection =================
                            if (!isAddNewDriver) ...[
                              // Searchable driver selector
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Select Driver',
                                    style: TextStyle(
                                      fontSize: width * 0.038,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  SizedBox(height: height * 0.01),
                                  isLoadingDrivers
                                      ? Container(
                                          padding: EdgeInsets.symmetric(
                                              vertical: height * 0.015),
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade100,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: const Center(
                                            child: SizedBox(
                                              height: 20,
                                              width: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          ),
                                        )
                                      : GestureDetector(
                                          onTap: () {
                                            _showDriverSearchDialog(
                                              context,
                                              drivers,
                                              selectedDriver,
                                              (driver) {
                                                setModalState(() {
                                                  selectedDriver = driver;
                                                });
                                              },
                                            );
                                          },
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: width * 0.04,
                                              vertical: height * 0.016,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.grey.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(Icons.search,
                                                    size: 20,
                                                    color: Colors.grey.shade500),
                                                SizedBox(width: width * 0.03),
                                                Expanded(
                                                  child: Text(
                                                    selectedDriver?.displayName ??
                                                        'Search driver by name or number...',
                                                    style: TextStyle(
                                                      fontSize: width * 0.038,
                                                      color: selectedDriver != null
                                                          ? Colors.black87
                                                          : Colors.grey.shade500,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                if (selectedDriver != null)
                                                  GestureDetector(
                                                    onTap: () {
                                                      setModalState(() {
                                                        selectedDriver = null;
                                                      });
                                                    },
                                                    child: Icon(Icons.close,
                                                        size: 18,
                                                        color: Colors.grey.shade600),
                                                  )
                                                else
                                                  Icon(
                                                      Icons.keyboard_arrow_down,
                                                      size: width * 0.06,
                                                      color: Colors.black),
                                              ],
                                            ),
                                          ),
                                        ),
                                ],
                              ),
                            ] else ...[
                              // Add new driver - manual entry
                              _buildBottomSheetTextField(
                                width,
                                height,
                                'Driver Name (Optional)',
                                newDriverNameController,
                                'Enter driver name',
                              ),
                              SizedBox(height: height * 0.02),
                              _buildBottomSheetTextField(
                                width,
                                height,
                                'Driver Mobile *',
                                newDriverMobileController,
                                'Enter 10-digit mobile number',
                                TextInputType.phone,
                              ),
                            ],
                            SizedBox(height: height * 0.025),

                            /// ================= Vehicle Number =================
                            _buildBottomSheetTextField(
                              width,
                              height,
                              'Vehicle Number',
                              vehicleNumberController,
                              'Enter vehicle number',
                            ),
                            SizedBox(height: height * 0.025),

                            /// ================= Priority =================
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Priority',
                                  style: TextStyle(
                                    fontSize: width * 0.038,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                ),
                                SizedBox(height: height * 0.01),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: width * 0.04,
                                    vertical: height * 0.005,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<int>(
                                      value: selectedPriority,
                                      hint: Text(
                                        'Select Priority',
                                        style: TextStyle(
                                          fontSize: width * 0.04,
                                          color: Colors.grey.shade500,
                                        ),
                                      ),
                                      isExpanded: true,
                                      icon: Icon(
                                        Icons.keyboard_arrow_down,
                                        size: width * 0.06,
                                        color: Colors.black,
                                      ),
                                      style: TextStyle(
                                        fontSize: width * 0.04,
                                        color: Colors.grey.shade700,
                                      ),
                                      items: List.generate(10, (index) {
                                        final value = index + 1;
                                        return DropdownMenuItem<int>(
                                          value: value,
                                          child: Text('$value'),
                                        );
                                      }),
                                      onChanged: (value) {
                                        setModalState(() {
                                          selectedPriority = value;
                                        });
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: height * 0.025),

                            /// ================= Vehicle Start Date =================
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Vehicle Start Date',
                                  style: TextStyle(
                                    fontSize: width * 0.038,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                ),
                                SizedBox(height: height * 0.01),
                                GestureDetector(
                                  onTap: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate:
                                          vehicleStartDate ?? DateTime.now(),
                                      firstDate: DateTime.now(),
                                      lastDate: DateTime.now()
                                          .add(const Duration(days: 365)),
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme:
                                                const ColorScheme.light(
                                              primary: Color(0xFF0077C8),
                                              onPrimary: Colors.white,
                                              onSurface: Colors.black,
                                            ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (picked != null) {
                                      setModalState(() {
                                        vehicleStartDate = picked;
                                      });
                                    }
                                  },
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: width * 0.04,
                                      vertical: height * 0.018,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            vehicleStartDate != null
                                                ? _formatDate(vehicleStartDate!)
                                                : 'Select start date',
                                            style: TextStyle(
                                              fontSize: width * 0.04,
                                              color: vehicleStartDate != null
                                                  ? Colors.grey.shade700
                                                  : Colors.grey.shade500,
                                            ),
                                          ),
                                        ),
                                        Icon(
                                          Icons.calendar_today,
                                          size: width * 0.05,
                                          color: const Color(0xFF0077C8),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: height * 0.025),

                            /// ================= Vehicle End Date =================
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Vehicle End Date',
                                  style: TextStyle(
                                    fontSize: width * 0.038,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                ),
                                SizedBox(height: height * 0.01),
                                GestureDetector(
                                  onTap: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate:
                                          vehicleEndDate ?? DateTime.now(),
                                      firstDate:
                                          vehicleStartDate ?? DateTime.now(),
                                      lastDate: DateTime.now()
                                          .add(const Duration(days: 365)),
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme:
                                                const ColorScheme.light(
                                              primary: Color(0xFF0077C8),
                                              onPrimary: Colors.white,
                                              onSurface: Colors.black,
                                            ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (picked != null) {
                                      setModalState(() {
                                        vehicleEndDate = picked;
                                      });
                                    }
                                  },
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: width * 0.04,
                                      vertical: height * 0.018,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            vehicleEndDate != null
                                                ? _formatDate(vehicleEndDate!)
                                                : 'Select end date',
                                            style: TextStyle(
                                              fontSize: width * 0.04,
                                              color: vehicleEndDate != null
                                                  ? Colors.grey.shade700
                                                  : Colors.grey.shade500,
                                            ),
                                          ),
                                        ),
                                        Icon(
                                          Icons.calendar_today,
                                          size: width * 0.05,
                                          color: const Color(0xFF0077C8),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: height * 0.025),

                            /// ================= Vehicle Start Location =================
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Vehicle Start Location',
                                  style: TextStyle(
                                    fontSize: width * 0.038,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                ),
                                SizedBox(height: height * 0.01),
                                GestureDetector(
                                  onTap: () async {
                                    final result = await LocationSelector.show(
                                      context: context,
                                      initialLatitude: vehicleStartLat,
                                      initialLongitude: vehicleStartLng,
                                    );

                                    if (result != null) {
                                      setModalState(() {
                                        vehicleStartLat = result.latitude;
                                        vehicleStartLng = result.longitude;
                                        vehicleStartAddress = result.address;
                                      });
                                    }
                                  },
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: width * 0.04,
                                      vertical: height * 0.018,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            vehicleStartAddress != null &&
                                                    vehicleStartAddress!
                                                        .isNotEmpty
                                                ? vehicleStartAddress!
                                                : 'Select start location',
                                            style: TextStyle(
                                              fontSize: width * 0.04,
                                              color: vehicleStartAddress != null
                                                  ? Colors.grey.shade700
                                                  : Colors.grey.shade500,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Icon(
                                          Icons.location_on,
                                          size: width * 0.06,
                                          color: const Color(0xFF0077C8),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: height * 0.02),
                          ],
                        ),
                      ),
                    ),
                  ),

                  /// ================= Fixed Bottom Button =================
                  Container(
                    padding: EdgeInsets.all(width * 0.05),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: isLoading
                            ? null
                            : () async {
                                // Validate based on mode
                                if (isAddNewDriver) {
                                  if (newDriverMobileController.text.trim().isEmpty) {
                                    AppSnackbar.error('Please enter driver mobile number');
                                    return;
                                  }
                                  if (newDriverMobileController.text.trim().length < 10) {
                                    AppSnackbar.error('Please enter a valid 10-digit mobile number');
                                    return;
                                  }
                                } else {
                                  if (selectedDriver == null) {
                                    AppSnackbar.error('Please select a driver');
                                    return;
                                  }
                                }

                                if (vehicleNumberController.text.isEmpty) {
                                  AppSnackbar.error(
                                      'Please enter vehicle number');
                                  return;
                                }

                                final token = _storage.getToken();
                                if (token == null) {
                                  AppSnackbar.error(
                                      'Session expired. Please login again.');
                                  Navigator.pop(context);
                                  return;
                                }

                                setModalState(() => isLoading = true);

                                try {
                                  await _repo.changeDriver(
                                    token: token,
                                    bookingId: widget.booking.bookingId,
                                    driverId: isAddNewDriver ? null : selectedDriver!.id,
                                    driverName: isAddNewDriver
                                        ? newDriverNameController.text.trim()
                                        : (selectedDriver!.name.isNotEmpty ? selectedDriver!.name : null),
                                    driverMobile: isAddNewDriver
                                        ? newDriverMobileController.text.trim()
                                        : selectedDriver!.mobile,
                                    vehicleNumber: vehicleNumberController.text,
                                    vehicleStartDate: vehicleStartDate != null
                                        ? _formatDateForApi(vehicleStartDate!)
                                        : null,
                                    vehicleEndDate: vehicleEndDate != null
                                        ? _formatDateForApi(vehicleEndDate!)
                                        : null,
                                    vehicleStartLat: vehicleStartLat,
                                    vehicleStartLng: vehicleStartLng,
                                    vehicleStartAddress: vehicleStartAddress,
                                    priority: selectedPriority,
                                  );

                                  AppSnackbar.success(
                                      'Driver assigned successfully');
                                  if (context.mounted) {
                                    Navigator.pop(
                                        context); // Close bottom sheet
                                  }
                                  // Don't pop the edit screen — let user continue
                                  // editing other fields (travel cost, description,
                                  // delivery date, status) and save them all together.
                                } catch (e) {
                                  AppSnackbar.error(extractErrorMessage(e));
                                } finally {
                                  setModalState(() => isLoading = false);
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0077C8),
                          padding:
                              EdgeInsets.symmetric(vertical: height * 0.018),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        child: isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                isAddNewDriver
                                    ? 'Add New Driver'
                                    : (widget.booking.driverDetails.isAssigned
                                        ? 'Change Driver'
                                        : 'Add Driver'),
                                style: TextStyle(
                                  fontSize: width * 0.045,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDriverInfoCard(double width, double height) {
    final driver = widget.booking.driverDetails;

    return Stack(children: [
      Container(
        padding: EdgeInsets.all(width * 0.04),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.shade100),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Driver Details',
              style: TextStyle(
                  fontSize: width * 0.042, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: height * 0.015),
            _buildDriverRow('Name', driver.name, width),
            _buildDriverRow('Driver Mobile', driver.mobile, width),
            _buildDriverRow('Vehicle Number', driver.vehicleNumber, width),
            if (driver.vehicleStartDate != null &&
                driver.vehicleStartDate!.isNotEmpty)
              _buildDriverRow('Vehicle Start Date',
                  _formatDisplayDate(driver.vehicleStartDate!), width),
            if (driver.vehicleEndDate != null &&
                driver.vehicleEndDate!.isNotEmpty)
              _buildDriverRow('Vehicle End Date',
                  _formatDisplayDate(driver.vehicleEndDate!), width),
            if (driver.vehicleStartAddress != null &&
                driver.vehicleStartAddress!.isNotEmpty)
              _buildDriverRow(
                  'Start Location', driver.vehicleStartAddress!, width),
          ],
        ),
      ),
      // Edit and Delete buttons
      Positioned(
        top: 10,
        right: 10,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Edit button
            GestureDetector(
              onTap: () => _showChangeDriverBottomSheet(context),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.edit_outlined,
                  color: Colors.blue,
                  size: width * 0.055,
                ),
              ),
            ),
            SizedBox(width: width * 0.02),
            // Delete button
            GestureDetector(
              onTap: _isRemovingDriver
                  ? null
                  : () {
                      _confirmRemoveDriver();
                    },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: _isRemovingDriver
                    ? SizedBox(
                        height: width * 0.045,
                        width: width * 0.045,
                        child: const CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(
                        Icons.delete_outline,
                        color: Colors.red,
                        size: width * 0.055,
                      ),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  String _formatDisplayDate(String dateString) {
    try {
      final date = DateTime.tryParse(dateString);
      if (date != null) {
        return DateFormat('dd/MM/yyyy').format(date);
      }
    } catch (_) {}
    return dateString;
  }

  void _confirmRemoveDriver() {
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Remove Driver'),
            content: const Text(
              'Are you sure you want to remove the driver from this booking?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await _removeDriver();
                  },
                  child: const Text(
                    'Remove',
                    style: TextStyle(color: Colors.red),
                  ))
            ],
          );
        });
  }

  Future<void> _removeDriver() async {
    final token = _storage.getToken();

    if (token == null) {
      AppSnackbar.error("Seesion expired. Please login again.");
      return;
    }

    setState(() => _isRemovingDriver = true);

    try {
      await _repo.removeDriver(
        token: token,
        bookingId: widget.booking.bookingId,
      );

      AppSnackbar.success('Driver removed successfully');

      if (mounted) {
        Navigator.pop(context, true); // Pop screen with refresh flag
      }
    } catch (e) {
      AppSnackbar.error(extractErrorMessage(e));
      if (mounted) {
        setState(() => _isRemovingDriver = false);
      }
    }
  }

  Widget _buildDriverRow(String label, String value, double width) {
    return Padding(
      padding: EdgeInsets.only(bottom: width * 0.02),
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: width * 0.038,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade700,
              ),
            ),
          ),
          Expanded(
              flex: 1,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: width * 0.038,
                  fontWeight: FontWeight.w600,
                ),
              ))
        ],
      ),
    );
  }

  Widget _buildBookingInfoCard(double width, double height) {
    return Container(
      padding: EdgeInsets.all(width * 0.04),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_preferredDate != null)
            Text(
              _formatDate(_preferredDate!),
              style: TextStyle(
                fontSize: width * 0.04,
                fontWeight: FontWeight.bold,
              ),
            ),
          SizedBox(height: height * 0.015),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ID: ${widget.booking.bookingId}',
                style: TextStyle(
                  fontSize: width * 0.038,
                  color: Colors.grey.shade700,
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.02,
                  vertical: height * 0.004,
                ),
                decoration: BoxDecoration(
                  color: _getStatusColor(widget.booking.status)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.booking.status.displayLabel,
                  style: TextStyle(
                    fontSize: width * 0.028,
                    color: _getStatusColor(widget.booking.status),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.015),
          Text(
            widget.booking.hatcheryName,
            style: TextStyle(
              fontSize: width * 0.04,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            widget.booking.categoryName,
            style: TextStyle(
              fontSize: width * 0.035,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  void _showDriverSearchDialog(
    BuildContext context,
    List<DriverItem> allDrivers,
    DriverItem? currentSelection,
    void Function(DriverItem) onSelect,
  ) {
    final searchController = TextEditingController();
    List<DriverItem> filtered = List.from(allDrivers);

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                    child: Row(
                      children: [
                        const Text(
                          'Select Driver',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(dialogContext),
                        ),
                      ],
                    ),
                  ),

                  // Search field
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search by name or mobile...',
                        hintStyle: TextStyle(color: Colors.grey.shade400),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  searchController.clear();
                                  setDialogState(() {
                                    filtered = List.from(allDrivers);
                                  });
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (query) {
                        final q = query.toLowerCase().trim();
                        setDialogState(() {
                          if (q.isEmpty) {
                            filtered = List.from(allDrivers);
                          } else {
                            filtered = allDrivers
                                .where((d) =>
                                    d.name.toLowerCase().contains(q) ||
                                    d.mobile.contains(q))
                                .toList();
                          }
                        });
                      },
                    ),
                  ),

                  // Results count
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${filtered.length} driver${filtered.length == 1 ? '' : 's'} found',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),

                  // Driver list
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.4,
                      ),
                      child: filtered.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.person_search,
                                      size: 48, color: Colors.grey.shade300),
                                  const SizedBox(height: 12),
                                  Text(
                                    'No drivers found',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  Divider(height: 1, color: Colors.grey.shade200),
                              itemBuilder: (context, index) {
                                final driver = filtered[index];
                                final isSelected =
                                    currentSelection?.id == driver.id;

                                return ListTile(
                                  leading: CircleAvatar(
                                    radius: 18,
                                    backgroundColor: isSelected
                                        ? const Color(0xFF0077C8)
                                        : Colors.grey.shade200,
                                    child: Icon(
                                      Icons.person,
                                      size: 18,
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.grey.shade600,
                                    ),
                                  ),
                                  title: Text(
                                    driver.name.isNotEmpty
                                        ? driver.name
                                        : 'Driver',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: isSelected
                                          ? const Color(0xFF0077C8)
                                          : Colors.black87,
                                    ),
                                  ),
                                  subtitle: Text(
                                    driver.mobile,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                  trailing: isSelected
                                      ? const Icon(Icons.check_circle,
                                          color: Color(0xFF0077C8), size: 20)
                                      : null,
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  onTap: () {
                                    onSelect(driver);
                                    Navigator.pop(dialogContext);
                                  },
                                );
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBottomSheetTextField(
    double width,
    double height,
    String label,
    TextEditingController controller,
    String hint, [
    TextInputType? keyboardType,
  ]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: width * 0.038,
            fontWeight: FontWeight.w500,
            color: Colors.black87,
          ),
        ),
        SizedBox(height: height * 0.01),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.04,
            vertical: height * 0.005,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            style: TextStyle(
              fontSize: width * 0.04,
              color: Colors.grey.shade700,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              hintText: hint,
              hintStyle: TextStyle(
                color: Colors.grey.shade400,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton(double width, double height) {
    return Container(
      padding: EdgeInsets.all(width * 0.05),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _isSaving ? null : _saveDetails,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0077C8),
            padding: EdgeInsets.symmetric(vertical: height * 0.018),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
          child: _isSaving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  'Save Details',
                  style: TextStyle(
                    fontSize: width * 0.045,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}
