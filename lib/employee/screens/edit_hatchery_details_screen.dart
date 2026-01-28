import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:bestseeds/widgets/location_selector_screen.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

    // Initialize salinity from model
    _selectedSalinity = widget.booking.salinity;

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
                            widget.booking.status.label,
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
                    _buildTextArea(width, height, 'Booking Description',
                        _bookingDescriptionController),
                    SizedBox(height: height * 0.025),

                    /// Vehicle Description
                    _buildTextArea(width, height, 'Vehicle Description',
                        _vehicleDescriptionController),
                    SizedBox(height: height * 0.03),

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
    if (status.isAccepted) return Colors.blue;
    if (status.isInProgress) return Colors.purple;
    if (status.isDelivered) return Colors.teal;
    if (status.isCompleted) return Colors.green;
    if (status.isRejected) return Colors.red;
    return Colors.grey;
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

    final TextEditingController driverNameController = TextEditingController();
    final TextEditingController driverMobileController =
        TextEditingController();
    final TextEditingController vehicleNumberController =
        TextEditingController();

    bool isLoading = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              margin: const EdgeInsets.only(top: 16),
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
                          'Change Driver',
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
                              'New Driver Details',
                              style: TextStyle(
                                fontSize: width * 0.042,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: height * 0.02),
                            _buildBottomSheetTextField(
                              width,
                              height,
                              'Driver Name',
                              driverNameController,
                              'Enter driver name',
                            ),
                            SizedBox(height: height * 0.025),
                            _buildBottomSheetTextField(
                              width,
                              height,
                              'Driver Mobile Number',
                              driverMobileController,
                              'Enter mobile number',
                              TextInputType.phone,
                            ),
                            SizedBox(height: height * 0.025),
                            _buildBottomSheetTextField(
                              width,
                              height,
                              'Vehicle Number',
                              vehicleNumberController,
                              'Enter vehicle number',
                            ),
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
                                if (driverNameController.text.isEmpty ||
                                    driverMobileController.text.isEmpty ||
                                    vehicleNumberController.text.isEmpty) {
                                  AppSnackbar.error(
                                      'Please fill all driver details');
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
                                    driverName: driverNameController.text,
                                    driverMobile: driverMobileController.text,
                                    vehicleNumber: vehicleNumberController.text,
                                  );

                                  AppSnackbar.success(
                                      'Driver changed successfully');
                                  if (context.mounted) {
                                    Navigator.pop(
                                        context); // Close bottom sheet
                                  }
                                  if (mounted) {
                                    Navigator.pop(this.context,
                                        true); // Pop screen with refresh flag
                                  }
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
                                'Change Driver',
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
            SizedBox(
              height: height * 0.015,
            ),
            _buildDriverRow('Name', driver.name, width),
            _buildDriverRow('Driver Mobile', driver.mobile, width),
            _buildDriverRow('Vehicle Number', driver.vehicleNumber, width)
          ],
        ),
      ),
      Positioned(
        top: 10,
        right: 10,
        child: GestureDetector(
          onTap: _isRemovingDriver
              ? null
              : () {
                  _confirmRemoveDriver();
                },
          child: Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              shape: BoxShape.circle,
            ),
            child: _isRemovingDriver
                ? SizedBox(
                    height: height * 0.045,
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
      ),
    ]);
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
                  widget.booking.status.label,
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
