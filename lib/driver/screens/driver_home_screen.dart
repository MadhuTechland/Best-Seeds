import 'package:bestseeds/driver/models/driver_booking_model.dart';
import 'package:bestseeds/driver/models/driver_model.dart';
import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/screens/driver_location_tracking.dart';
import 'package:bestseeds/driver/screens/drop_location_bottomsheet.dart';
import 'package:bestseeds/driver/screens/profile_screen.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:bestseeds/widgets/route_visualization.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DriverDashboard extends StatefulWidget {
  const DriverDashboard({super.key});

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> {
  int selectedTabIndex = 0;
  final DriverStorageService _storage = DriverStorageService();
  final DriverAuthRepository _repo = DriverAuthRepository();
  Driver? _driver;
  String? _locationAddress;

  List<DriverRoute> _allRoutes = [];
  List<DriverRoute> _filteredRoutes = [];
  bool _isLoading = true;
  String? _errorMessage;

  final TextEditingController _searchController = TextEditingController();

  // Counts from backend
  int _allCount = 0;
  int _liveCount = 0;
  int _assignedCount = 0;
  int _pastCount = 0;

  // Filter options
  String? _selectedBookingType; // hatchery, spot

  // Tab scroll controller
  final ScrollController _tabScrollController = ScrollController();

  // Status constants
  // 1 = accept/reject (New booking)
  // 2 = in_progress (Processing)
  // 3 = confirmed (Driver assigned - Live)
  // 4 = vehicle tracking (In progress - Start Journey clicked)
  // 5 = completed (Delivered)
  // 6 = cancelled

  bool get _hasActiveFilters => _selectedBookingType != null;

  @override
  void initState() {
    super.initState();
    _loadDriver();
    _loadLocation();
    _fetchBookings();
  }

  void _loadLocation() {
    final address = _storage.getLocationAddress();
    setState(() {
      _locationAddress = address;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDriver() async {
    final driver = await _storage.getDriver();
    setState(() {
      _driver = driver;
    });
  }

  Future<void> _fetchBookings() async {
    final token = _storage.getToken();
    if (token == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Session expired. Please login again.';
      });
      return;
    }

    try {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      final response = await _repo.getBookings(token);
      setState(() {
        _allRoutes = response.routes;
        // Store counts from backend
        _allCount = response.counts.all;
        _liveCount = response.counts.live;
        _assignedCount = response.counts.assigned;
        _pastCount = response.counts.past;
        _filterRoutes();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load bookings. Please try again.';
      });
      debugPrint('Error fetching bookings: $e');
    }
  }

  void _filterRoutes() {
    final searchQuery = _searchController.text.toLowerCase();

    List<DriverRoute> filtered;

    switch (selectedTabIndex) {
      case 0: // All
        filtered = _allRoutes;
        break;
      case 1: // Live (routes with status 3 or 4)
        filtered = _allRoutes
            .where((r) => r.routeStatus == 4)
            .toList();
        break;
      case 2: // Assigned Bookings (status 3 - confirmed, waiting to start)
        filtered = _allRoutes.where((r) => r.routeStatus == 3).toList();
        break;
      case 3: // Past Bookings (status 5 - completed)
        filtered = _allRoutes.where((r) => r.isCompleted || r.isFailed).toList();
        break;
      default:
        filtered = _allRoutes;
    }

    // Apply search filter
    if (searchQuery.isNotEmpty) {
      filtered = filtered.where((route) {
        return route.hatcheryName.toLowerCase().contains(searchQuery) ||
            route.categoryName.toLowerCase().contains(searchQuery) ||
            route.bookings.any((b) =>
                b.customerName.toLowerCase().contains(searchQuery) ||
                (b.droppingLocation?.toLowerCase().contains(searchQuery) ??
                    false) ||
                (b.bookingUid?.toLowerCase().contains(searchQuery) ?? false));
      }).toList();
    }

    // Apply booking type filter
    if (_selectedBookingType != null) {
      filtered = filtered.where((route) {
        // Check if route's hatchery matches the selected booking type
        // This is a simplified check - you may need to adjust based on actual data structure
        if (_selectedBookingType == 'spot') {
          return route.hatcheryName.toLowerCase().contains('spot');
        } else if (_selectedBookingType == 'hatchery') {
          return !route.hatcheryName.toLowerCase().contains('spot');
        }
        return true;
      }).toList();
    }

    setState(() {
      _filteredRoutes = filtered;
    });
  }

  int _getTabCount(int tabIndex) {
    switch (tabIndex) {
      case 0: // All
        return _allCount;
      case 1: // Live
        return _liveCount;
      case 2: // Assigned Bookings
        return _assignedCount;
      case 3: // Past
        return _pastCount;
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: [
            /// ================= Header =================
            _buildHeader(width, height),

            /// ================= Search Bar =================
            _buildSearchBar(width, height),

            /// ================= Tab Bar =================
            _buildTabBar(width, height),

            /// ================= Routes List =================
            Expanded(
              child: _buildRoutesList(width, height),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(double width, double height) {
    final firstName = _driver?.name.split(' ').first ?? 'Driver';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.02,
      ),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, $firstName',
                  style: TextStyle(
                    fontSize: width * 0.055,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_locationAddress != null && _locationAddress!.isNotEmpty)
                  Row(
                    children: [
                      Icon(
                        Icons.location_on,
                        size: width * 0.04,
                        color: const Color(0xFF0077C8),
                      ),
                      SizedBox(width: width * 0.01),
                      Expanded(
                        child: Text(
                          _locationAddress!,
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
            ),
          ),
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
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DriverProfileScreen(),
                ),
              );
            },
            child: _buildProfileAvatar(width),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileAvatar(double width) {
    final size = width * 0.1;

    if (_driver?.fullProfileImageUrl.isNotEmpty == true) {
      return ClipOval(
        child: Image.network(
          _driver!.fullProfileImageUrl,
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
        color: Colors.green.shade400,
      ),
      child: Icon(
        Icons.person,
        size: size * 0.6,
        color: Colors.white,
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
      padding: EdgeInsets.symmetric(horizontal: width * 0.05),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: Container(
              margin: EdgeInsets.only(bottom: height * 0.015),
              padding: EdgeInsets.symmetric(horizontal: width * 0.04),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search,
                    color: Colors.grey.shade500,
                    size: width * 0.055,
                  ),
                  SizedBox(width: width * 0.03),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) => _filterRoutes(),
                      decoration: InputDecoration(
                        hintText: 'Search Bookings',
                        hintStyle: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: width * 0.04,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          vertical: height * 0.015,
                        ),
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchController.clear();
                        _filterRoutes();
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
          GestureDetector(
            onTap: _showFilterDialog,
            child: Container(
              margin: EdgeInsets.only(bottom: height * 0.015),
              padding: EdgeInsets.all(width * 0.03),
              decoration: BoxDecoration(
                color: _hasActiveFilters ? const Color(0xFF0077C8) : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(
                children: [
                  Icon(
                    Icons.filter_list,
                    color: _hasActiveFilters ? Colors.white : Colors.grey.shade700,
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
                        onTap: () => setModalState(() => _selectedBookingType = null),
                        width: width,
                      ),
                      _buildFilterChip(
                        label: 'Spot Hatchery',
                        isSelected: _selectedBookingType == 'spot',
                        onTap: () => setModalState(() => _selectedBookingType = 'spot'),
                        width: width,
                      ),
                      _buildFilterChip(
                        label: 'Hatchery',
                        isSelected: _selectedBookingType == 'hatchery',
                        onTap: () => setModalState(() => _selectedBookingType = 'hatchery'),
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
                        _filterRoutes();
                        Navigator.pop(context);
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

  Widget _buildTabBar(double width, double height) {
    final tabs = [
      {'label': 'All', 'showDot': false},
      {'label': 'Live', 'showDot': true},
      {'label': 'Assigned', 'showDot': false},
      {'label': 'Past', 'showDot': false},
    ];

    return Container(
      height: height * 0.055,
      color: Colors.white,
      child: ListView.builder(
        controller: _tabScrollController,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: width * 0.03),
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final isSelected = selectedTabIndex == index;
          final tab = tabs[index];
          final count = _getTabCount(index);

          return GestureDetector(
            onTap: () {
              setState(() {
                selectedTabIndex = index;
              });
              _filterRoutes();
              // Simple scroll logic for 4 tabs
              // if (_tabScrollController.hasClients) {
              //   final maxScroll = _tabScrollController.position.maxScrollExtent;
              //   if (maxScroll > 0) {
              //     // Only scroll if content is scrollable
              //     if (index == 0) {
              //       // First tab - scroll to start
              //       _tabScrollController.animateTo(
              //         0,
              //         duration: const Duration(milliseconds: 200),
              //         curve: Curves.easeOut,
              //       );
              //     } else if (index == tabs.length - 1) {
              //       // Last tab - scroll to end
              //       _tabScrollController.animateTo(
              //         maxScroll,
              //         duration: const Duration(milliseconds: 200),
              //         curve: Curves.easeOut,
              //       );
              //     }
              //     // Middle tabs don't need scrolling - they're already visible
              //   }
              // }
            },
            child: Container(
              margin: EdgeInsets.symmetric(
                horizontal: width * 0.015,
                vertical: height * 0.008,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.04,
              ),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF0077C8) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF0077C8)
                      : Colors.grey.shade300,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Live dot indicator
                  if (tab['showDot'] == true) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.white : Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: width * 0.015),
                  ],
                  Text(
                    tab['label'] as String,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.black87,
                      fontSize: width * 0.035,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  if (count > 0) ...[
                    SizedBox(width: width * 0.015),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.white : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$count',
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

  Widget _buildRoutesList(double width, double height) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF0077C8)),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: width * 0.15,
              color: Colors.grey,
            ),
            SizedBox(height: height * 0.02),
            Text(
              _errorMessage!,
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: height * 0.02),
            ElevatedButton(
              onPressed: _fetchBookings,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0077C8),
              ),
              child: const Text(
                'Retry',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );
    }

    if (_filteredRoutes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: width * 0.15,
              color: Colors.grey,
            ),
            SizedBox(height: height * 0.02),
            Text(
              'No bookings found',
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchBookings,
      color: const Color(0xFF0077C8),
      child: ListView.builder(
        padding: EdgeInsets.all(width * 0.04),
        itemCount: _filteredRoutes.length,
        itemBuilder: (context, index) {
          final route = _filteredRoutes[index];
          return Padding(
            padding: EdgeInsets.only(bottom: height * 0.02),
            child: _buildRouteCard(width, height, route),
          );
        },
      ),
    );
  }

  Widget _buildRouteCard(double width, double height, DriverRoute route) {
    final packingDate = route.packingDate != null
        ? DateFormat('dd MMM yyyy').format(route.packingDate!)
        : 'N/A';
    final packingDateFormatted = route.packingDate != null
        ? DateFormat('dd/MM/yyyy').format(route.packingDate!)
        : 'N/A';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
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
          /// Date Header
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: width * 0.04,
              vertical: height * 0.015,
            ),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  packingDate,
                  style: TextStyle(
                    fontSize: width * 0.04,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          /// Card Content
          Padding(
            padding: EdgeInsets.all(width * 0.04),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                /// Booking IDs Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'ID: ${route.bookingIdsString}',
                        style: TextStyle(
                          fontSize: width * 0.038,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${route.totalDrops} Drops',
                      style: TextStyle(
                        fontSize: width * 0.032,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: height * 0.012),

                /// Hatchery Name with Delivery Date
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        route.hatcheryName,
                        style: TextStyle(
                          fontSize: width * 0.042,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (route.firstDeliveryDatetime != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            DateFormat('dd MMM yyyy').format(route.firstDeliveryDatetime!),
                            style: TextStyle(
                              fontSize: width * 0.032,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF0077C8),
                            ),
                          ),
                          Text(
                            DateFormat('hh:mm a').format(route.firstDeliveryDatetime!),
                            style: TextStyle(
                              fontSize: width * 0.03,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),

                /// Category
                if (route.categoryName.isNotEmpty)
                  Text(
                    route.categoryName,
                    style: TextStyle(
                      fontSize: width * 0.035,
                      color: Colors.grey.shade600,
                    ),
                  ),
                SizedBox(height: height * 0.015),

                /// Route Visualization
                buildRouteVisualization(width, height, route),

                SizedBox(height: height * 0.015),

                /// Pieces and Date Info
                Row(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: width * 0.045,
                      color: Colors.grey.shade600,
                    ),
                    SizedBox(width: width * 0.02),
                    Text(
                      '${route.totalPieces} Pieces',
                      style: TextStyle(
                        fontSize: width * 0.038,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    SizedBox(width: width * 0.06),
                    Icon(
                      Icons.calendar_today_outlined,
                      size: width * 0.04,
                      color: Colors.grey.shade600,
                    ),
                    SizedBox(width: width * 0.02),
                    Text(
                      packingDateFormatted,
                      style: TextStyle(
                        fontSize: width * 0.038,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),

                SizedBox(height: height * 0.02),

                /// Action Button
                _buildActionButton(width, height, route),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(double width, double height, DriverRoute route) {
    final routeStatus = route.routeStatus;

    // Status: 3 = confirmed (show Start Journey)
    // Status: 4 = in progress (show Update Drop status)
    // Status: 5 = completed (show Delivered)

    if (routeStatus == 3) {
      // Confirmed - Show Start Journey
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => _startJourney(route),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            padding: EdgeInsets.symmetric(vertical: height * 0.015),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          child: Text(
            'Start Journey',
            style: TextStyle(
              fontSize: width * 0.04,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      );
    } else if (routeStatus == 4) {
      // In Progress - Show Update Drop status
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => _showDropLocationsSheet(route),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0077C8),
            padding: EdgeInsets.symmetric(vertical: height * 0.015),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          child: Text(
            'Update Drop status',
            style: TextStyle(
              fontSize: width * 0.04,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      );
    } else if (routeStatus == 5 || route.isCompleted) {
      // Completed - Show Delivered
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            disabledBackgroundColor: Colors.green,
            padding: EdgeInsets.symmetric(vertical: height * 0.015),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Delivered',
                style: TextStyle(
                  fontSize: width * 0.04,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: width * 0.02),
              const Icon(
                Icons.check_circle,
                color: Colors.white,
                size: 20,
              ),
            ],
          ),
        ),
      );
    } else if (routeStatus == 6 || route.isFailed) {
      // Completed - Show Delivered
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            disabledBackgroundColor: Colors.red,
            padding: EdgeInsets.symmetric(vertical: height * 0.015),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Failed',
                style: TextStyle(
                  fontSize: width * 0.04,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: width * 0.02),
              const Icon(
                Icons.cancel,
                color: Colors.white,
                size: 20,
              ),
            ],
          ),
        ),
      );
    }

    // Default - Show Update Drop status for routes with bookings
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: () => _showDropLocationsSheet(route),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF0077C8),
          padding: EdgeInsets.symmetric(vertical: height * 0.015),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          elevation: 0,
        ),
        child: Text(
          'Update Drop status',
          style: TextStyle(
            fontSize: width * 0.04,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Future<void> _startJourney(DriverRoute route) async {
    // Get all booking IDs from the route
    final bookingIds = route.bookings.map((b) => b.id).toList();

    if (bookingIds.isEmpty) {
      AppSnackbar.error('No bookings found for this route');
      return;
    }

    final token = _storage.getToken();
    if (token == null) {
      AppSnackbar.error('Session expired. Please login again.');
      return;
    }

    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF0077C8)),
        ),
      );

      await _repo.startJourney(token: token, bookingIds: bookingIds);

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      AppSnackbar.success('Journey started successfully');
      debugPrint('START JOURNEY: Starting DriverLocationService');
      DriverLocationService.start(token);
      // Refresh bookings to update the status
      _fetchBookings();
    } catch (e) {
      // Close loading dialog
      if (mounted) Navigator.pop(context);

      AppSnackbar.error('Failed to start journey. Please try again.');
      debugPrint('Error starting journey: $e');
    }
  }

  void _showDropLocationsSheet(DriverRoute route) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DropLocationsBottomSheet(
          route: route,
          width: width,
          height: height,
          onUpdate: () {
            _fetchBookings();
          },
        );
      },
    );
  }
}