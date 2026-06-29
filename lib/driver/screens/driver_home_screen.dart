import 'dart:io';

import 'package:bestseeds/driver/controllers/driver_permissions_controller.dart';
import 'package:bestseeds/driver/models/driver_booking_model.dart';
import 'package:bestseeds/driver/models/driver_model.dart';
import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/screens/driver_location_tracking.dart';
import 'package:bestseeds/driver/screens/drop_location_bottomsheet.dart';
import 'package:bestseeds/driver/screens/profile_screen.dart';
import 'package:bestseeds/driver/screens/tracking_logs_screen.dart';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/driver/services/tracking_alert_service.dart';
import 'package:bestseeds/driver/widgets/driver_location_permission.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:bestseeds/widgets/location_selector_screen.dart';
import 'package:bestseeds/widgets/refresh_button.dart';
import 'package:bestseeds/widgets/route_visualization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DriverDashboard extends StatefulWidget {
  const DriverDashboard({super.key});

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard>
    with WidgetsBindingObserver {
  static const MethodChannel _deviceInfoChannel =
      MethodChannel('bestseeds/device_info');

  int selectedTabIndex = 2;
  final DriverPermissionsController _permController =
      Get.put(DriverPermissionsController());
  final DriverStorageService _storage = DriverStorageService();
  final DriverAuthRepository _repo = DriverAuthRepository();
  Driver? _driver;
  String? _locationAddress;

  // Prevents concurrent battery-optimization dialogs (initState + startJourney
  // both call _ensureBatteryOptimizationExemption; without this flag they race
  // and show two dialogs simultaneously).
  bool _batteryExemptionInProgress = false;

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
    WidgetsBinding.instance.addObserver(this);
    _loadDriver();
    _loadLocation();
    _fetchBookings();
    _checkActiveJourney();
    _requestNotificationPermission();
    TrackingAlertService.start();
  }

  /// Request notification permission early (on app open) so alert sounds work.
  /// On Android 13+ (API 33+), POST_NOTIFICATIONS requires a runtime request.
  Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.status;
    // If already permanently denied, skip — user already saw the denial.
    // Showing an error on every initState would be annoying.
    if (status.isPermanentlyDenied || status.isGranted) return;
    await Permission.notification.request();
  }

  Future<bool> _ensureBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return true;

    // Guard against concurrent calls (e.g. initState + startJourney).
    if (_batteryExemptionInProgress) return false;
    _batteryExemptionInProgress = true;

    try {
      // Standard Android check via permission_handler.
      final permStatus = await Permission.ignoreBatteryOptimizations.status;
      if (permStatus.isGranted) return true;

      // Native channel double-check.
      try {
        final isIgnoring = await _deviceInfoChannel.invokeMethod<bool>(
              'isIgnoringBatteryOptimizations',
            ) ??
            false;
        if (isIgnoring) return true;
      } catch (_) {}

      // On many OEM phones (iQOO/Vivo, OnePlus, Samsung, etc.) the standard
      // Android API always reports "not granted" even after the user enables the
      // OEM's own background-running permission. Asking every app open would show
      // the dialog forever. We show it only ONCE per install using a prefs flag.
      final prefs = await SharedPreferences.getInstance();
      final alreadyPrompted = prefs.getBool('battery_opt_prompted') ?? false;
      if (alreadyPrompted) return false;

      if (!mounted) return false;

      final shouldOpen = await _showPermissionDialog(
        title: 'Disable Battery Optimization',
        message:
            'To keep live truck tracking running while the phone is locked for long journeys, please allow "Drive Bestseed" to ignore battery optimization.\n\n'
            'Otherwise some Android phones stop GPS updates after 30-40 minutes and the customer marker gets stuck.',
        icon: Icons.battery_saver_rounded,
        iconColor: const Color(0xFF0077C8),
      );

      // Mark prompted regardless of choice — OEM APIs may never report
      // "granted" even after the user enables it, so we must not re-ask.
      await prefs.setBool('battery_opt_prompted', true);

      if (!shouldOpen) return false;

      try {
        await _deviceInfoChannel.invokeMethod(
          'requestIgnoreBatteryOptimizations',
        );
      } catch (_) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      await Future.delayed(const Duration(milliseconds: 800));

      try {
        return await _deviceInfoChannel.invokeMethod<bool>(
              'isIgnoringBatteryOptimizations',
            ) ??
            false;
      } catch (_) {
        return (await Permission.ignoreBatteryOptimizations.status).isGranted;
      }
    } finally {
      _batteryExemptionInProgress = false;
    }
  }

  /// If there was an active journey (e.g. app was killed/cleared during delivery),
  /// restart the background location service and switch to the Live tab.
  /// Also handles zombie state (service alive but isolate dead after hot restart).
  Future<void> _checkActiveJourney() async {
    debugPrint('📍 [HOME] ═══════════════════════════════════════');
    debugPrint('📍 [HOME] TRACKING STATUS CHECK');
    debugPrint('📍 [HOME] ═══════════════════════════════════════');

    final shouldRun = await BackgroundLocationService.shouldBeRunning();
    final runningBefore = await BackgroundLocationService.isRunning();

    // Check last sent timestamp
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final lastSentMs = prefs.getInt('last_location_sent_at') ?? 0;
    final lastSentAgeSec = lastSentMs > 0
        ? (DateTime.now().millisecondsSinceEpoch - lastSentMs) ~/ 1000
        : -1;

    debugPrint('📍 [HOME] shouldRun=$shouldRun');
    debugPrint('📍 [HOME] isRunning=$runningBefore');
    debugPrint('📍 [HOME] lastSentAge=${lastSentAgeSec == -1 ? "NEVER" : "${lastSentAgeSec}s ago"}');

    if (shouldRun) {
      debugPrint('📍 [HOME] 🟡 Journey is ACTIVE — ensuring tracking is alive...');
      // Refresh token so background isolate has the latest
      final currentToken = _storage.getToken();
      if (currentToken != null && currentToken.isNotEmpty) {
        final sp = await SharedPreferences.getInstance();
        await sp.setString('driver_token', currentToken);
      }
      await BackgroundLocationService.restartIfNeeded();
      final runningAfter = await BackgroundLocationService.isRunning();
      if (runningAfter) {
        debugPrint('📍 [HOME] ✅ TRACKING IS ON — service running, lat/lng being sent');
      } else {
        debugPrint('📍 [HOME] ❌ TRACKING FAILED TO START — service not running after restart attempt');
      }
    } else {
      debugPrint('📍 [HOME] ⚪ TRACKING IS OFF — no active journey');
    }

    debugPrint('📍 [HOME] ═══════════════════════════════════════');

    final running = await BackgroundLocationService.isRunning();
    if (running && mounted) {
      setState(() {
        selectedTabIndex = 1; // Live tab
      });
    }
  }

  /// Called after bookings API confirms NO live journey exists.
  /// If the tracking flag is somehow still on, stop the background service
  /// so iOS's persistent SLC monitor is released (otherwise iOS counts the
  /// app as a background-location consumer indefinitely and shows the
  /// "used your location in the background over the past 3 days" prompt).
  Future<void> _stopTrackingIfNoLiveJourney() async {
    final shouldRun = await BackgroundLocationService.shouldBeRunning();
    if (!shouldRun) return;
    debugPrint('📍 [HOME] ⚠️ Backend has NO live journey but tracking flag is ON — stopping tracking');
    await BackgroundLocationService.stop();
  }

  /// Called after bookings API confirms live journeys exist.
  /// If tracking flag is off (SharedPreferences lost/cleared), force-start it.
  /// Also refreshes the token in SharedPreferences so the background isolate
  /// picks up the latest valid token (prevents 401 after hot restart/token refresh).
  Future<void> _ensureTrackingForLiveJourney() async {
    final shouldRun = await BackgroundLocationService.shouldBeRunning();
    if (shouldRun) return; // already flagged, _checkActiveJourney handles it

    debugPrint('📍 [HOME] ⚠️ Backend has LIVE journey but tracking flag is OFF — force-starting tracking');

    // Refresh the token in SharedPreferences so background isolate gets the latest
    final currentToken = _storage.getToken();
    if (currentToken != null && currentToken.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final storedToken = prefs.getString('driver_token');
      if (storedToken != currentToken) {
        await prefs.setString('driver_token', currentToken);
        debugPrint('📍 [HOME] Token refreshed in SharedPreferences (was stale)');
      }
      // Set the flag so restartIfNeeded knows to keep it alive
      await prefs.setBool('bg_location_service_running', true);
    } else {
      debugPrint('📍 [HOME] ❌ No token available — cannot start tracking');
      return;
    }

    // Now start the service
    await BackgroundLocationService.restartIfNeeded();

    final running = await BackgroundLocationService.isRunning();
    if (running) {
      debugPrint('📍 [HOME] ✅ Tracking auto-started for live journey');
      if (mounted) {
        setState(() {
          selectedTabIndex = 1; // Live tab
        });
      }
    } else {
      debugPrint('📍 [HOME] ❌ Failed to auto-start tracking');
    }
  }

  void _loadLocation() {
    final address = _storage.getLocationAddress();
    setState(() {
      _locationAddress = address;
    });
  }

  Future<void> _pickLocation() async {
    // Opens the "Select Location" sheet with both options — Use Current Location
    // and Select from Map (the map picker).
    final result = await LocationSelector.show(
      context: context,
      initialLatitude: _storage.getLocationLat(),
      initialLongitude: _storage.getLocationLng(),
    );
    if (result == null || !mounted) return;

    await _storage.saveLocation(
      latitude: result.latitude,
      longitude: result.longitude,
      address: result.address,
    );

    final token = _driver?.token;
    if (token != null && token.isNotEmpty) {
      try {
        await _repo.updateCurrentLocation(
          token: token,
          latitude: result.latitude,
          longitude: result.longitude,
          address: result.address,
        );
      } catch (e) {
        debugPrint('Driver updateCurrentLocation failed: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _locationAddress = result.address;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      debugPrint('📍 [HOME] App RESUMED — refreshing token + reconciling tracking...');
      // Refresh token so background isolate always has the latest
      final currentToken = _storage.getToken();
      if (currentToken != null && currentToken.isNotEmpty) {
        SharedPreferences.getInstance().then((sp) {
          sp.setString('driver_token', currentToken);
        });
      }
      // Refresh bookings first — _fetchBookings is the canonical
      // start/stop reconciler (live > 0 ⇒ ensure tracking; live == 0
      // ⇒ stop tracking). restartIfNeeded() afterwards is then a no-op
      // when no journey is live, instead of blindly reviving SLC on iOS.
      _fetchBookings().then((_) {
        BackgroundLocationService.restartIfNeeded();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Always fetch fresh data from API — no cache
    final token = _storage.getToken();
    if (token == null) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Session expired. Please login again.';
          _isLoading = false;
        });
      }
      return;
    }

    try {
      final response = await _repo.getBookings(token);
      if (mounted) {
        setState(() {
          _allRoutes = response.routes;
          _allCount = response.counts.all;
          _liveCount = response.counts.live;
          _assignedCount = response.counts.assigned;
          _pastCount = response.counts.past;
          _filterRoutes();
          _isLoading = false;
        });

        // If backend has live journeys but tracking is off, auto-start it.
        // This catches: hot restart, app data cleared, flag lost, etc.
        if (response.counts.live > 0) {
          _ensureTrackingForLiveJourney();
        } else {
          // Inverse: backend says no live journey — make sure tracking
          // (and on iOS, the persistent SLC monitor) is fully stopped.
          // Without this the run flag can stay stuck true after a journey
          // ends via a path that doesn't go through stop(), and iOS keeps
          // counting the app as a background-location consumer.
          _stopTrackingIfNoLiveJourney();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load bookings. Please try again.';
        });
        AppSnackbar.error('Could not refresh bookings');
      }
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
        filtered = _allRoutes.where((r) => r.routeStatus == 4).toList();
        break;
      case 2: // Assigned Bookings (status 3 - confirmed, waiting to start)
        filtered = _allRoutes.where((r) => r.routeStatus == 3).toList();
        break;
      case 3: // Past Bookings (status 5 - completed)
        filtered =
            _allRoutes.where((r) => r.isCompleted || r.isFailed).toList();
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

    return DriverLocationGuard(
      child: Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: [
            /// ================= Header =================
            _buildHeader(width, height),

            /// ================= Search Bar =================
            _buildSearchBar(width, height),

            /// ===== Permission prompts (only the ones still disabled) =====
            _buildPermissionPrompts(width, height),

            /// ================= Tab Bar =================
            _buildTabBar(width, height),

            /// ================= Routes List =================
            Expanded(
              child: _buildRoutesList(width, height),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Compact permission prompts shown on the main screen. Each row (label +
  /// arrow) appears ONLY while that permission is still disabled:
  ///   • both off  → both rows shown
  ///   • one off   → only that row shown
  ///   • both on   → nothing shown
  /// Tapping a row redirects (request permission / open settings).
  Widget _buildPermissionPrompts(double width, double height) {
    return Obx(() {
      final showLocation = !_permController.locationGranted.value;
      final showBattery = !_permController.batteryDisabled.value;

      if (!showLocation && !showBattery) return const SizedBox.shrink();

      return Container(
        color: const Color(0xFFF8F9FA),
        padding: EdgeInsets.fromLTRB(width * 0.05, 0, width * 0.05, height * 0.01),
        child: Column(
          children: [
            if (showLocation)
              _permissionPromptRow(
                icon: Icons.location_on_outlined,
                label: 'Location',
                onTap: () => _permController.enableLocation(),
              ),
            if (showLocation && showBattery) const SizedBox(height: 8),
            if (showBattery)
              _permissionPromptRow(
                icon: Icons.battery_charging_full_outlined,
                label: 'Background activity',
                onTap: () => _permController.enableBattery(),
              ),
          ],
        ),
      );
    });
  }

  Widget _permissionPromptRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFC62828).withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFFC62828)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                size: 22, color: Colors.grey),
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
                // Long-press the greeting to open the tracking-logs
                // viewer. Hidden access so normal drivers don't see a
                // "debug" button cluttering the header, but the dev
                // running this build can tail the location pipeline.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const TrackingLogsScreen(),
                      ),
                    );
                  },
                  child: Text(
                    'Hello, $firstName',
                    style: TextStyle(
                      fontSize: width * 0.055,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                InkWell(
                  onTap: _pickLocation,
                  child: Row(
                    children: [
                      Icon(
                        Icons.location_on,
                        size: width * 0.04,
                        color: const Color(0xFF0077C8),
                      ),
                      SizedBox(width: width * 0.01),
                      Expanded(
                        child: Text(
                          (_locationAddress != null &&
                                  _locationAddress!.isNotEmpty)
                              ? _locationAddress!
                              : 'Set your location',
                          style: TextStyle(
                            fontSize: width * 0.032,
                            color: Colors.grey.shade600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: width * 0.04,
                        color: Colors.grey.shade500,
                      ),
                    ],
                  ),
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
          Container(
            margin: EdgeInsets.only(bottom: height * 0.015),
            child: RefreshButton(onTap: () {
              _fetchBookings();
            }),
          ),
          GestureDetector(
            onTap: _showFilterDialog,
            child: Container(
              margin: EdgeInsets.only(bottom: height * 0.015),
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
        return SafeArea(
          top: false,
          child: StatefulBuilder(
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
          ),
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
        physics: const AlwaysScrollableScrollPhysics(),
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

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Hatchery name + Date + Status chips
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F7FF),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        route.hatcheryName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1F2937),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (route.firstDeliveryDatetime != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0077C8).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          DateFormat('dd MMM, hh:mm a')
                              .format(route.firstDeliveryDatetime!),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0077C8),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                // Info chips row
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _infoChip(Icons.tag_rounded,
                        route.bookingIdsString, Colors.grey.shade700),
                    // Pieces chip — for multi-booking routes shows
                    // a per-booking breakdown like
                    // "1200 pcs (217), 2000 pcs (218)" so the driver
                    // knows which booking carries which load.
                    // Single-booking routes still show just "1200 pcs".
                    _infoChip(Icons.inventory_2_outlined,
                        route.piecesByBookingString, Colors.grey.shade700),
                    _infoChip(Icons.place_outlined,
                        '${route.totalDrops} drops', Colors.grey.shade700),
                    // Category chip — same per-booking breakdown when
                    // bookings on a route belong to different categories
                    // (e.g. "syaqua (217), hyderline (218)").
                    if (route.categoriesByBookingString.isNotEmpty)
                      _infoChip(Icons.category_outlined,
                          route.categoriesByBookingString, Colors.grey.shade700),
                  ],
                ),
              ],
            ),
          ),

          // Route Visualization
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: buildRouteVisualization(width, height, route),
          ),

          // Packing date + Action Button
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.calendar_today_outlined,
                        size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      'Packing: $packingDate',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildActionButton(width, height, route),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
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
            backgroundColor: const Color(0xFF0077C8),
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
            backgroundColor: Colors.orange,
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

  /// Ensures both foreground + background location and notification permissions
  /// are granted. Returns true if all required permissions are good.
  Future<bool> _ensureLocationPermissions() async {
    if (Platform.isIOS) {
      // iOS: never show custom dialogs — the system handles permission prompts.
      // Only trigger the system dialog on first launch (when denied).
      // whileInUse is acceptable — tracking works while app is open/suspended.
      // deniedForever silently blocks start; driver must fix in Settings themselves.
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever;
    }

    // Step 1: Foreground location ("While using the app") — Android only
    var locWhenInUse = await Permission.locationWhenInUse.status;
    if (!locWhenInUse.isGranted) {
      locWhenInUse = await Permission.locationWhenInUse.request();
      if (!locWhenInUse.isGranted) {
        if (locWhenInUse.isPermanentlyDenied) {
          final shouldOpen = await _showPermissionDialog(
            title: 'Location Permission Required',
            message:
                'To start your journey, we need access to your location so the vendor and customer can track the delivery in real time.\n\n'
                'Please tap "Open Settings" and enable Location permission for this app.',
            icon: Icons.location_on_rounded,
            iconColor: const Color(0xFF0077C8),
          );
          if (shouldOpen) await openAppSettings();
        } else {
          AppSnackbar.error(
              'Location permission is required to track your delivery.');
        }
        return false;
      }
    }

    // Step 2: Background location ("Allow all the time")
    var locAlways = await Permission.locationAlways.status;
    if (!locAlways.isGranted) {
      await Permission.locationAlways.request();
      locAlways = await Permission.locationAlways.status;
      if (!locAlways.isGranted) {
        AppSnackbar.error(
          'Background location required. Please allow "All the time" in location settings, then tap Start Journey again.',
        );
        return false;
      }
    }

    // Step 3: Notification permission (Android 13+) — non-blocking
    final notif = await Permission.notification.status;
    if (!notif.isGranted) {
      await Permission.notification.request();
    }

    // Step 4: Battery optimization exemption — CRITICAL for OEM phones
    await _ensureBatteryOptimizationExemption();

    // Step 5: OEM-specific autostart guidance on first journey start
    await _showAutoStartGuidanceIfNeeded();

    return true;
  }

  /// Shows a dialog explaining why a permission is needed and asks the driver
  /// whether to open settings. Returns true if the driver taps "Open Settings".
  Future<bool> _showPermissionDialog({
    required String title,
    required String message,
    required IconData icon,
    required Color iconColor,
  }) async {
    if (!mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Not Now',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0077C8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Open Settings',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  /// Shows a one-time dialog guiding the user to enable autostart/background
  /// activity for their phone brand. This is critical for OnePlus, Realme,
  /// Oppo, Xiaomi, etc. which have their own app-kill mechanisms.
  Future<void> _showAutoStartGuidanceIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyShown = prefs.getBool('autostart_guidance_shown') ?? false;
    if (alreadyShown) return;

    final manufacturer =
        (await _getDeviceManufacturer()).toLowerCase();

    // Only show for OEMs known to aggressively kill background services
    String? steps;
    if (manufacturer.contains('oneplus') || manufacturer.contains('oppo')) {
      steps = '1. Go to Settings > Battery > Battery Optimization\n'
          '2. Find "Drive Bestseed" and select "Don\'t Optimize"\n'
          '3. Also go to Settings > Apps > Drive Bestseed > Battery\n'
          '4. Enable "Allow Background Activity"\n'
          '5. Disable "Auto-launch manager" restriction if present';
    } else if (manufacturer.contains('realme')) {
      steps = '1. Go to Settings > Battery > App Battery Management\n'
          '2. Find "Drive Bestseed" and select "Allow Background Activity"\n'
          '3. Also go to Settings > App Management > Drive Bestseed\n'
          '4. Enable "Auto-launch" for this app\n'
          '5. Set Battery Saver to "Unrestricted"';
    } else if (manufacturer.contains('xiaomi') ||
        manufacturer.contains('redmi') ||
        manufacturer.contains('poco')) {
      steps = '1. Go to Settings > Apps > Manage Apps > Drive Bestseed\n'
          '2. Tap "Autostart" and enable it\n'
          '3. Go to Battery Saver > Drive Bestseed\n'
          '4. Set to "No Restrictions"';
    } else if (manufacturer.contains('samsung')) {
      steps = '1. Go to Settings > Battery > Background Usage Limits\n'
          '2. Remove "Drive Bestseed" from Sleeping/Deep Sleeping apps\n'
          '3. Go to Settings > Apps > Drive Bestseed > Battery\n'
          '4. Set to "Unrestricted"';
    } else if (manufacturer.contains('vivo')) {
      steps = '1. Go to Settings > Battery > Background Power Consumption\n'
          '2. Find "Drive Bestseed" and enable "Allow Background Activity"\n'
          '3. Go to Settings > Apps > Autostart and enable for this app';
    } else if (manufacturer.contains('huawei') ||
        manufacturer.contains('honor')) {
      steps = '1. Go to Settings > Battery > App Launch\n'
          '2. Find "Drive Bestseed" and set to "Manage Manually"\n'
          '3. Enable: Auto-launch, Secondary Launch, Run in Background';
    }

    if (steps == null) return; // Stock Android, no special guidance needed

    await prefs.setBool('autostart_guidance_shown', true);

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enable Background Tracking'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your phone (${manufacturer[0].toUpperCase()}${manufacturer.substring(1)}) '
                'may stop location tracking in the background. '
                'Please follow these steps to keep tracking active:',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              Text(
                steps!,
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 16),
              const Text(
                'You can also open App Settings to configure this now.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I\'ll Do It Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0077C8),
            ),
            child: const Text(
              'Open Settings',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  /// Gets the device manufacturer name using a platform channel.
  Future<String> _getDeviceManufacturer() async {
    try {
      // Use ProcessResult to get the manufacturer from Android build info.
      // This works because we already have the android.os.Build class available.
      final result =
          await _deviceInfoChannel.invokeMethod<String>('getManufacturer');
      return result ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
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

    // ── Request background-location & notification permissions ──
    final permissionGranted = await _ensureLocationPermissions();
    if (!permissionGranted) return;

    bool loadingDialogShown = false;
    try {
      // Show loading indicator
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF0077C8)),
        ),
      );
      loadingDialogShown = true;

      // Get driver's current location to save as start location
      double? startLat;
      double? startLng;
      String? startAddress;
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );
        startLat = position.latitude;
        startLng = position.longitude;

        // Reverse geocode to get address
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          startAddress = [p.subLocality, p.locality, p.administrativeArea]
              .where((e) => e != null && e.isNotEmpty)
              .join(', ');
        }
      } catch (e) {
        debugPrint('Could not get start location: $e');
      }

      debugPrint('🚀 [START-JOURNEY] bookingIds=$bookingIds startLat=$startLat startLng=$startLng startAddress=$startAddress');
      await _repo.startJourney(
        token: token,
        bookingIds: bookingIds,
        startLat: startLat,
        startLng: startLng,
        startAddress: startAddress,
      );
      debugPrint('🚀 [START-JOURNEY] ✅ API call success for bookingIds=$bookingIds');

      // Dismiss loading BEFORE starting the service so that any system dialog
      // triggered by the service (e.g. Xiaomi battery opt prompt) appears on a
      // clean stack, not stacked on top of the loading spinner.
      if (mounted && loadingDialogShown) {
        Navigator.pop(context);
        loadingDialogShown = false;
      }

      AppSnackbar.success('Journey started successfully');
      debugPrint('START JOURNEY: Starting DriverLocationService');
      await DriverLocationService.start(token);
      // Switch to Live tab and refresh bookings
      setState(() {
        selectedTabIndex = 1;
      });
      _fetchBookings();
    } catch (e) {
      AppSnackbar.error('Failed to start journey. Please try again.');
      debugPrint('Error starting journey: $e');
    } finally {
      // Safety net: dismiss loading dialog if an unexpected path left it open.
      if (mounted && loadingDialogShown) {
        Navigator.pop(context);
      }
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
        return SafeArea(
          top: false,
          child: DropLocationsBottomSheet(
            route: route,
            width: width,
            height: height,
            onUpdate: () {
              _fetchBookings();
            },
          ),
        );
      },
    );
  }
}
