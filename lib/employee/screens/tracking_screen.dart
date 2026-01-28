import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'edit_vehicle_details_screen.dart';
import 'vehicle_tracking_map_screen.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  final AuthRepository _repo = AuthRepository();
  final StorageService _storage = StorageService();

  List<Booking> _allBookings = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBookings();
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

  // Only show current bookings (accepted, in progress, or delivered)
  List<Booking> get _currentBookings {
    return _allBookings
        .where((b) => b.status.isAccepted || b.status.isInProgress || b.status.isDelivered)
        .toList();
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
            Expanded(
              child: _buildTrackingList(width, height),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(double width, double height) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.02,
      ),
      color: Colors.white,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Vehicle Tracking',
            style: TextStyle(
              fontSize: width * 0.055,
              fontWeight: FontWeight.bold,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.translate,
              size: width * 0.06,
            ),
          ),
        ],
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
          borderRadius: BorderRadius.circular(12),
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

  Widget _buildTrackingList(double width, double height) {
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

    final bookings = _currentBookings;

    if (bookings.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_shipping_outlined, size: 48, color: Colors.grey.shade400),
            SizedBox(height: height * 0.02),
            Text(
              'No active deliveries',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
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
            child: _buildTrackingCard(width, height, booking),
          );
        },
      ),
    );
  }

  Widget _buildTrackingCard(double width, double height, Booking booking) {
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
              Icon(Icons.inventory_2_outlined, size: width * 0.04, color: Colors.grey),
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
              Icon(Icons.location_on_outlined, size: width * 0.04, color: Colors.grey),
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

          SizedBox(height: height * 0.02),

          // Vehicle Tracking Button
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
                      borderRadius: BorderRadius.circular(25),
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
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => EditVehicleDetailsScreen(
                        bookingId: booking.bookingUid,
                        title: booking.hatcheryName,
                        time: '',
                      ),
                    ),
                  );
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
        ],
      ),
    );
  }

  Color _getStatusColor(BookingStatus status) {
    if (status.isAccepted) return Colors.blue;
    if (status.isInProgress) return Colors.purple;
    if (status.isDelivered) return Colors.teal;
    return Colors.grey;
  }
}
