import 'package:bestseeds/driver/models/user_model.dart';
import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/screens/edit_hatchery_details_screen.dart';
import 'package:bestseeds/employee/screens/vehicle_tracking_map_screen.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class EmployeeDashboard extends StatefulWidget {
  const EmployeeDashboard({super.key});

  @override
  State<EmployeeDashboard> createState() => _EmployeeDashboardState();
}

class _EmployeeDashboardState extends State<EmployeeDashboard> {
  int selectedTabIndex = 0;
  final StorageService _storage = StorageService();
  final AuthRepository _repo = AuthRepository();
  User? _user;

  List<Booking> _allBookings = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    await _loadUser();
    await _loadBookings();
  }

  Future<void> _loadUser() async {
    final user = await _storage.getUser();
    setState(() {
      _user = user;
    });
  }

  Future<void> _loadBookings() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final token = _storage.getToken();
      if (token == null) {
        setState(() {
          _error = 'Session expired. Please login again.';
          _isLoading = false;
        });
        return;
      }

      final response = await _repo.getBookings(token);
      setState(() {
        _allBookings = response.bookings;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _acceptBooking(Booking booking) async {
    final token = _storage.getToken();
    if (token == null) {
      AppSnackbar.error('Session expired. Please login again.');
      return;
    }

    try {
      // Show loading
      Get.dialog(
        const Center(
            child: CircularProgressIndicator(color: Color(0xFF0077C8))),
        barrierDismissible: false,
      );

      await _repo.acceptBooking(token: token, bookingId: booking.bookingId);

      Get.back(); // Close loading
      AppSnackbar.success('Booking accepted successfully');

      // Refresh bookings
      _loadBookings();
    } catch (e) {
      Get.back(); // Close loading
      AppSnackbar.error(extractErrorMessage(e));
    }
  }

  Future<void> _showRejectDialog(Booking booking) async {
    final width = MediaQuery.of(context).size.width;

    final rejectionReasons = [
      {'code': 1, 'text': 'Out of stock'},
      {'code': 2, 'text': 'Incorrect order details'},
      {'code': 3, 'text': 'Delivery not available'},
      {'code': 4, 'text': 'Other reason'},
    ];

    int? selectedReasonCode;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Text(
                'Reject Booking',
                style: TextStyle(
                  fontSize: width * 0.05,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Please select a reason for rejection:',
                    style: TextStyle(
                      fontSize: width * 0.038,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  SizedBox(height: width * 0.04),
                  ...rejectionReasons.map((reason) {
                    return RadioListTile<int>(
                      title: Text(
                        reason['text'] as String,
                        style: TextStyle(fontSize: width * 0.038),
                      ),
                      value: reason['code'] as int,
                      groupValue: selectedReasonCode,
                      activeColor: const Color(0xFF0077C8),
                      onChanged: (value) {
                        setDialogState(() {
                          selectedReasonCode = value;
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    );
                  }),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: selectedReasonCode == null
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          _rejectBooking(booking, selectedReasonCode!);
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Reject',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _rejectBooking(Booking booking, int reasonCode) async {
    final token = _storage.getToken();
    if (token == null) {
      AppSnackbar.error('Session expired. Please login again.');
      return;
    }

    try {
      // Show loading
      Get.dialog(
        const Center(
            child: CircularProgressIndicator(color: Color(0xFF0077C8))),
        barrierDismissible: false,
      );

      await _repo.rejectBooking(
        token: token,
        bookingId: booking.bookingId,
        reasonCode: reasonCode,
      );

      Get.back(); // Close loading
      AppSnackbar.success('Booking rejected successfully');

      // Refresh bookings
      _loadBookings();
    } catch (e) {
      Get.back(); // Close loading
      AppSnackbar.error(extractErrorMessage(e));
    }
  }

  List<Booking> get _filteredBookings {
    switch (selectedTabIndex) {
      case 0: // All
        return _allBookings;
      case 1: // New Bookings (pending - status value 1)
        return _allBookings.where((b) => b.status.isPending).toList();
      case 2: // Current Bookings (in progress)
        return _allBookings
            .where((b) =>
                b.status.isAccepted ||
                b.status.isInProgress ||
                b.status.isDelivered)
            .toList();
      case 3: // Past (completed or rejected)
        return _allBookings
            .where((b) => b.status.isCompleted || b.status.isRejected)
            .toList();
      default:
        return _allBookings;
    }
  }

  int get _newBookingsCount {
    return _allBookings.where((b) => b.status.isPending).length;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(width, height),
            _buildSearchBar(width, height),
            _buildTabBar(width, height),
            Expanded(
              child: _buildBookingsList(width, height),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(double width, double height) {
    final firstName = _user?.name.split(' ').first ?? 'User';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.02,
      ),
      color: Colors.white,
      child: Row(
        children: [
          Text(
            'Hello, $firstName',
            style: TextStyle(
              fontSize: width * 0.06,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          _buildHeaderIcon(
            size: width * 0.12,
            assetPath: 'assets/icons/translate.png',
            onTap: () {},
          ),
          SizedBox(width: width * 0.02),
          _buildHeaderIcon(
            size: width * 0.12,
            assetPath: 'assets/icons/notification_icon.png',
            onTap: () {},
          ),
          SizedBox(width: width * 0.02),
          _buildProfileAvatar(width),
        ],
      ),
    );
  }

  Widget _buildProfileAvatar(double width) {
    final size = width * 0.11;

    if (_user?.fullProfileImageUrl.isNotEmpty == true) {
      return ClipOval(
        child: Image.network(
          _user!.fullProfileImageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildDefaultProfileIcon(size);
          },
        ),
      );
    }

    return _buildDefaultProfileIcon(size);
  }

  Widget _buildDefaultProfileIcon(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.grey.shade300,
      ),
      child: Icon(
        Icons.person,
        size: size * 0.6,
        color: Colors.grey.shade600,
      ),
    );
  }

  Widget _buildHeaderIcon({
    required double size,
    required String assetPath,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipOval(
        child: Image.asset(
          assetPath,
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  Widget _buildSearchBar(double width, double height) {
    return Container(
      padding: EdgeInsets.all(width * 0.05),
      color: Colors.white,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: width * 0.04,
          vertical: height * 0.015,
        ),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(width * 0.09),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search,
              color: Colors.grey,
              size: width * 0.06,
            ),
            SizedBox(width: width * 0.03),
            Text(
              'Search Bookings',
              style: TextStyle(
                color: Colors.grey,
                fontSize: width * 0.04,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(double width, double height) {
    final tabs = [
      {'label': 'All', 'count': null},
      {
        'label': 'New Bookings',
        'count': _newBookingsCount > 0 ? _newBookingsCount : null
      },
      {'label': 'Current Bookings', 'count': null},
      {'label': 'Past', 'count': null},
    ];

    return Container(
      height: height * 0.06,
      color: Colors.white,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: width * 0.03),
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final isSelected = selectedTabIndex == index;
          final tab = tabs[index];

          return GestureDetector(
            onTap: () {
              setState(() {
                selectedTabIndex = index;
              });
            },
            child: Container(
              margin: EdgeInsets.symmetric(
                horizontal: width * 0.02,
                vertical: height * 0.01,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.04,
              ),
              decoration: BoxDecoration(
                color:
                    isSelected ? const Color(0xFF0077C8) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Text(
                    tab['label'] as String,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.black,
                      fontSize: width * 0.038,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  if (tab['count'] != null) ...[
                    SizedBox(width: width * 0.015),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.white : Colors.grey.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${tab['count']}',
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFF0077C8)
                              : Colors.black,
                          fontSize: width * 0.03,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBookingsList(double width, double height) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF0077C8)),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey.shade400),
            SizedBox(height: height * 0.02),
            Text(
              _error!,
              style: TextStyle(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: height * 0.02),
            ElevatedButton(
              onPressed: _loadBookings,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0077C8),
              ),
              child: const Text('Retry', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }

    final bookings = _filteredBookings;

    if (bookings.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox_outlined, size: 48, color: Colors.grey.shade400),
              SizedBox(height: height * 0.02),
              Text(
                'No bookings assigned',
                style: TextStyle(color: Colors.grey.shade600),
              ),
              Text(
                "We're looking for nearby requests and will notify you as soon as a booking is available.",
                style: TextStyle(color: Colors.grey.shade500),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadBookings,
      color: const Color(0xFF0077C8),
      child: ListView.builder(
        padding: EdgeInsets.all(width * 0.04),
        itemCount: bookings.length,
        itemBuilder: (context, index) {
          final booking = bookings[index];
          return Padding(
            padding: EdgeInsets.only(bottom: height * 0.02),
            child: _buildBookingCard(width, height, booking),
          );
        },
      ),
    );
  }

  Widget _buildBookingCard(double width, double height, Booking booking) {
    String status;
    if (booking.status.isPending) {
      status = 'pending';
    } else if (booking.status.isCompleted) {
      status = 'completed';
    } else if (booking.status.isRejected) {
      status = 'rejected';
    } else {
      status = 'tracking';
    }

    return Container(
      padding: EdgeInsets.all(width * 0.04),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'ID: ${booking.bookingId}',
                  style: TextStyle(
                    fontSize: width * 0.035,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.02,
                  vertical: height * 0.004,
                ),
                decoration: BoxDecoration(
                  color: _getStatusColor(booking.status).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  booking.status.label,
                  style: TextStyle(
                    fontSize: width * 0.028,
                    color: _getStatusColor(booking.status),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.015),

          // Type badge
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: width * 0.03,
              vertical: height * 0.005,
            ),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              booking.displayBookingType,
              style: TextStyle(
                fontSize: width * 0.035,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(height: height * 0.015),

          // Title and category
          Text(
            booking.hatcheryName,
            style: TextStyle(
              fontSize: width * 0.045,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            booking.categoryName,
            style: TextStyle(
              fontSize: width * 0.035,
              color: Colors.grey,
            ),
          ),
          SizedBox(height: height * 0.015),

          // Info section
          Row(
            children: [
              Icon(Icons.inventory_2_outlined,
                  size: width * 0.04, color: Colors.grey),
              SizedBox(width: width * 0.02),
              Text(
                '${booking.noOfPieces} Pieces',
                style: TextStyle(
                  fontSize: width * 0.038,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.01),

          // Address
          Row(
            children: [
              Icon(Icons.location_on_outlined,
                  size: width * 0.04, color: Colors.grey),
              SizedBox(width: width * 0.02),
              Expanded(
                child: Text(
                  booking.droppingLocation,
                  style: TextStyle(
                    fontSize: width * 0.038,
                    color: Colors.grey.shade700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // Farmer info
          SizedBox(height: height * 0.015),
          Row(
            children: [
              Icon(Icons.person_outline,
                  size: width * 0.045, color: Colors.grey.shade700),
              SizedBox(width: width * 0.02),
              Text(
                booking.farmer.name,
                style: TextStyle(
                  fontSize: width * 0.038,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),

          SizedBox(height: height * 0.02),

          // Action buttons
          if (status == 'pending') ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _acceptBooking(booking),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: EdgeInsets.symmetric(vertical: height * 0.015),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Accept',
                      style: TextStyle(
                        fontSize: width * 0.04,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: width * 0.03),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _showRejectDialog(booking),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: EdgeInsets.symmetric(vertical: height * 0.015),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Reject',
                      style: TextStyle(
                        fontSize: width * 0.04,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: width * 0.03),
                GestureDetector(
                  onTap: () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => EditHatcheryDetailsScreen(
                          booking: booking,
                        ),
                      ),
                    );
                    if (result == true) {
                      _loadBookings();
                    }
                  },
                  child: Container(
                    padding: EdgeInsets.all(width * 0.025),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.edit_outlined,
                      size: width * 0.05,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (status == 'tracking') ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => VehicleTrackingMapScreen(
                            booking: booking,
                          ),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0077C8),
                      padding: EdgeInsets.symmetric(vertical: height * 0.015),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Vehicle Tracking',
                      style: TextStyle(
                        fontSize: width * 0.04,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                if (booking.isEditable)
                SizedBox(width: width * 0.03),
                if (booking.isEditable)
                  GestureDetector(
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => EditHatcheryDetailsScreen(
                            booking: booking,
                          ),
                        ),
                      );
                      if (result == true) {
                        _loadBookings();
                      }
                    },
                    child: Container(
                      padding: EdgeInsets.all(width * 0.025),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.edit_outlined,
                        size: width * 0.05,
                      ),
                    ),
                  ),
              ],
            ),
          ] else if (status == 'completed') ...[
            ElevatedButton(
              onPressed: () {},
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: EdgeInsets.symmetric(vertical: height * 0.015),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Completed',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: width * 0.02),
                  const Icon(
                    Icons.check_circle,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ] else if (status == 'rejected') ...[
            ElevatedButton(
              onPressed: null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade100,
                padding: EdgeInsets.symmetric(vertical: height * 0.015),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Rejected',
                    style: TextStyle(
                      fontSize: width * 0.04,
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                  SizedBox(width: width * 0.02),
                  const Icon(
                    Icons.cancel,
                    color: Colors.red,
                  ),
                ],
              ),
            ),
          ],
        ],
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
}
