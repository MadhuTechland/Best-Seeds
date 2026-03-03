import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:bestseeds/widgets/refresh_button.dart';
import 'package:flutter/material.dart';
import 'edit_hatchery_details_screen.dart';
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

  // Pagination
  int _currentPage = 1;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  // Search and filter
  final TextEditingController _searchController = TextEditingController();

  // Filter options
  String? _selectedBookingType; // hatchery, spot, vehicle
  String? _selectedVehicleAvailability; // assigned, not_assigned

  // List scroll controller for pagination
  final ScrollController _listScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadBookings();
    _searchController.addListener(_onSearchChanged);
    _listScrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_listScrollController.position.pixels >=
        _listScrollController.position.maxScrollExtent - 200) {
      _loadMoreBookings();
    }
  }

  // Debounce timer for search
  DateTime? _lastSearchTime;

  void _onSearchChanged() {
    _lastSearchTime = DateTime.now();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_lastSearchTime != null &&
          DateTime.now().difference(_lastSearchTime!) >=
              const Duration(milliseconds: 450)) {
        _loadBookings();
      }
    });
  }

  bool get _hasActiveFilters =>
      _selectedBookingType != null || _selectedVehicleAvailability != null;

  Future<void> _loadBookings() async {
    final searchText = _searchController.text.trim();
    final isCacheable = searchText.isEmpty &&
        _selectedBookingType == null &&
        _selectedVehicleAvailability == null;

    setState(() {
      _isLoading = true;
      _error = null;
      _currentPage = 1;
      _hasMore = true;
      _allBookings = [];
    });

    // Load cached data first for instant display
    if (isCacheable) {
      final cached = await _repo.getCachedBookings('tracking');
      if (cached != null && cached.bookings.isNotEmpty && mounted) {
        setState(() {
          _allBookings = cached.bookings;
          _hasMore = cached.pagination.currentPage < cached.pagination.lastPage;
          _isLoading = false;
        });
      }
    }

    // Fetch fresh data from API
    try {
      final token = _storage.getToken();
      if (token == null) {
        if (mounted) {
          setState(() {
            if (_allBookings.isEmpty) {
              _error = 'Session expired. Please login again.';
            }
            _isLoading = false;
          });
        }
        return;
      }

      final response = await _repo.getBookingsPage(
        token,
        page: 1,
        tab: 'tracking',
        search: searchText.isNotEmpty ? searchText : null,
        bookingType: _selectedBookingType,
        vehicleAvailability: _selectedVehicleAvailability,
      );
      if (mounted) {
        setState(() {
          _allBookings = response.bookings;
          _hasMore =
              response.pagination.currentPage < response.pagination.lastPage;
          _currentPage = 1;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        if (_allBookings.isEmpty) {
          setState(() {
            _error = extractErrorMessage(e);
            _isLoading = false;
          });
        } else {
          setState(() => _isLoading = false);
          AppSnackbar.error('Could not refresh bookings');
        }
      }
    }
  }

  Future<void> _loadMoreBookings() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final token = _storage.getToken();
      if (token == null) {
        setState(() => _isLoadingMore = false);
        return;
      }

      final nextPage = _currentPage + 1;
      final searchText = _searchController.text.trim();
      final response = await _repo.getBookingsPage(
        token,
        page: nextPage,
        tab: 'tracking',
        search: searchText.isNotEmpty ? searchText : null,
        bookingType: _selectedBookingType,
        vehicleAvailability: _selectedVehicleAvailability,
      );

      setState(() {
        _allBookings.addAll(response.bookings);
        _currentPage = nextPage;
        _hasMore =
            response.pagination.currentPage < response.pagination.lastPage;
        _isLoadingMore = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  // Server-side filtered - just return loaded data
  List<Booking> get _currentBookings => _allBookings;

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
      padding: EdgeInsets.only(
          left: width * 0.05, right: width * 0.05, bottom: height * 0.015),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: width * 0.04),
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
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search Bookings',
                        hintStyle: TextStyle(
                          color: Colors.grey,
                          fontSize: width * 0.04,
                        ),
                        border: InputBorder.none,
                        contentPadding:
                            EdgeInsets.symmetric(vertical: height * 0.015),
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchController.clear();
                      },
                      child: Icon(
                        Icons.close,
                        color: Colors.grey,
                        size: width * 0.05,
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(width: width * 0.03),
          RefreshButton(onTap: () {
            _loadBookings();
          }),
          GestureDetector(
            onTap: _showFilterDialog,
            child: Container(
              padding: EdgeInsets.all(width * 0.03),
              decoration: BoxDecoration(
                color: _hasActiveFilters
                    ? const Color(0xFF0077C8)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(
                children: [
                  Icon(
                    Icons.filter_list,
                    color:
                        _hasActiveFilters ? Colors.white : Colors.grey.shade700,
                    size: width * 0.06,
                  ),
                  if (_hasActiveFilters)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.orange,
                          shape: BoxShape.circle,
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

  void _showFilterDialog() {
    final width = MediaQuery.of(context).size.width;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              padding: EdgeInsets.all(width * 0.05),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Filters',
                        style: TextStyle(
                          fontSize: width * 0.05,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setModalState(() {
                            _selectedBookingType = null;
                            _selectedVehicleAvailability = null;
                          });
                        },
                        child: Text(
                          'Clear All',
                          style: TextStyle(
                            color: const Color(0xFF0077C8),
                            fontSize: width * 0.04,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: width * 0.04),

                  // Booking Type Filter
                  Text(
                    'Booking Type',
                    style: TextStyle(
                      fontSize: width * 0.042,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: width * 0.02),
                  Wrap(
                    spacing: width * 0.02,
                    children: [
                      _buildFilterChip(
                        label: 'All',
                        isSelected: _selectedBookingType == null,
                        onTap: () =>
                            setModalState(() => _selectedBookingType = null),
                        width: width,
                      ),
                      _buildFilterChip(
                        label: 'Spot Hatchery',
                        isSelected: _selectedBookingType == 'spot',
                        onTap: () =>
                            setModalState(() => _selectedBookingType = 'spot'),
                        width: width,
                      ),
                      _buildFilterChip(
                        label: 'Hatchery',
                        isSelected: _selectedBookingType == 'hatchery',
                        onTap: () => setModalState(
                            () => _selectedBookingType = 'hatchery'),
                        width: width,
                      ),
                    ],
                  ),
                  SizedBox(height: width * 0.05),

                  // Vehicle Availability Filter
                  Text(
                    'Vehicle Availability',
                    style: TextStyle(
                      fontSize: width * 0.042,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: width * 0.02),
                  Wrap(
                    spacing: width * 0.02,
                    children: [
                      _buildFilterChip(
                        label: 'All',
                        isSelected: _selectedVehicleAvailability == null,
                        onTap: () => setModalState(
                            () => _selectedVehicleAvailability = null),
                        width: width,
                      ),
                      _buildFilterChip(
                        label: 'Driver Assigned',
                        isSelected: _selectedVehicleAvailability == 'assigned',
                        onTap: () => setModalState(
                            () => _selectedVehicleAvailability = 'assigned'),
                        width: width,
                      ),
                      _buildFilterChip(
                        label: 'No Driver',
                        isSelected:
                            _selectedVehicleAvailability == 'not_assigned',
                        onTap: () => setModalState(() =>
                            _selectedVehicleAvailability = 'not_assigned'),
                        width: width,
                      ),
                    ],
                  ),
                  SizedBox(height: width * 0.06),

                  // Apply Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _loadBookings(); // Reload with server-side filters
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0077C8),
                        padding: EdgeInsets.symmetric(vertical: width * 0.04),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Apply Filters',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: width * 0.045,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: width * 0.02),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required double width,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: width * 0.04,
          vertical: width * 0.025,
        ),
        margin: EdgeInsets.only(bottom: width * 0.02),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0077C8) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF0077C8) : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.black87,
            fontSize: width * 0.035,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
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
            Icon(Icons.local_shipping_outlined,
                size: 48, color: Colors.grey.shade400),
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
        controller: _listScrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(width * 0.04),
        itemCount: bookings.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          // Show loading indicator at the bottom
          if (index == bookings.length) {
            return _buildLoadingIndicator();
          }
          final booking = bookings[index];
          return Padding(
            padding: EdgeInsets.only(bottom: height * 0.02),
            child: _buildTrackingCard(width, height, booking),
          );
        },
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    if (!_isLoadingMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildDot(0),
            const SizedBox(width: 8),
            _buildDot(1),
            const SizedBox(width: 8),
            _buildDot(2),
          ],
        ),
      ),
    );
  }

  Widget _buildDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 600 + (index * 200)),
      builder: (context, value, child) {
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color:
                const Color(0xFF0077C8).withValues(alpha: 0.3 + (value * 0.7)),
            shape: BoxShape.circle,
          ),
        );
      },
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
              if (booking.deliveryDatetime != null &&
                  booking.deliveryDatetime!.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: width * 0.02,
                    vertical: height * 0.004,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    booking.deliveryDatetime!,
                    style: TextStyle(
                      fontSize: width * 0.035,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: height * 0.015),

          // Type badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  booking.displayBookingType,
                  style: TextStyle(
                    fontSize: width * 0.035,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.03,
                  vertical: height * 0.005,
                ),
                decoration: BoxDecoration(
                  color: _getStatusColor(booking.status).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  booking.status.displayLabel,
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

          // Title and category - only show if data is available
          Text(
            booking.hatcheryName.isNotEmpty
                ? booking.hatcheryName
                : booking.displayBookingType,
            style: TextStyle(
              fontSize: width * 0.045,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (booking.categoryName.isNotEmpty)
            Text(
              booking.categoryName,
              style: TextStyle(
                fontSize: width * 0.035,
                color: Colors.grey,
              ),
            ),
          if (booking.hatcheryName.isNotEmpty ||
              booking.categoryName.isNotEmpty)
            SizedBox(height: height * 0.015),

          // Info section
          if (booking.noOfPieces > 0 ||
              (booking.preferredDate != null &&
                  booking.preferredDate!.isNotEmpty))
            Row(
              children: [
                if (booking.noOfPieces > 0) ...[
                  Icon(
                    Icons.inventory_2_outlined,
                    size: width * 0.04,
                    color: Colors.grey,
                  ),
                  SizedBox(width: width * 0.02),
                  Text(
                    '${booking.noOfPieces} Pieces',
                    style: TextStyle(
                      fontSize: width * 0.038,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],

                /// Pushes next widget to the right
                const Spacer(),

                if (booking.preferredDate != null &&
                    booking.preferredDate!.isNotEmpty)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.02,
                      vertical: height * 0.004,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min, // IMPORTANT
                      children: [
                        Icon(
                          Icons.calendar_today_outlined,
                          size: width * 0.04,
                          color: Colors.grey.shade700,
                        ),
                        SizedBox(width: width * 0.01),
                        Text(
                          booking.preferredDate!,
                          style: TextStyle(
                            fontSize: width * 0.035,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),

          // Address - only show if droppingLocation is not empty
          if (booking.droppingLocation.isNotEmpty) ...[
            SizedBox(height: height * 0.01),
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
          ],

          // Farmer info - only show if farmer name is not empty
          if (booking.farmer.name.isNotEmpty) ...[
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
          ],
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
              if (booking.isEditable) SizedBox(width: width * 0.03),
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
        ],
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
}
