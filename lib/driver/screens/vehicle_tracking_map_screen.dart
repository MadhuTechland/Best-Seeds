import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bestseeds/widgets/refresh_button.dart';
import 'package:bestseeds/utils/custom_marker_helper.dart';
import 'package:bestseeds/utils/google_maps_service.dart';
import 'package:bestseeds/driver/models/specific_vehicle_tracking_response.dart';
import 'package:bestseeds/driver/service/auth_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';

class VehicleTrackingMapScreen extends StatefulWidget {
  final String bookingId;

  const VehicleTrackingMapScreen({super.key, required this.bookingId});

  @override
  State<VehicleTrackingMapScreen> createState() =>
      _VehicleTrackingMapScreenState();
}

class _VehicleTrackingMapScreenState extends State<VehicleTrackingMapScreen>
    with TickerProviderStateMixin {
  final AuthService _authService = AuthService();
  final DriverStorageService _storageService = DriverStorageService();

  // Separate controllers for small and expanded maps
  GoogleMapController? _smallMapController;
  GoogleMapController? _expandedMapController;

  // Default location (Hyderabad, India)
  static const LatLng _defaultLocation = LatLng(17.3850, 78.4867);
  static const Duration _liveTrackingPollInterval = Duration(seconds: 10);
  static const Duration _routeRefreshInterval = Duration(minutes: 5);
  static const Duration _rerouteCooldown = Duration(minutes: 2);
  static const Duration _markerAnimationStepDuration = Duration(
    milliseconds: 50,
  );
  static const int _markerAnimationSteps = 20;
  static const double _polylineRerouteThresholdMeters = 750;
  static const double _timelinePointMinDistanceMeters = 15;

  late CameraPosition _initialPosition;
  late LatLng _currentVehiclePosition;

  // Markers for small map view
  Set<Marker> _smallMapMarkers = {};
  // Markers for expanded map view
  Set<Marker> _expandedMapMarkers = {};

  Set<Polyline> _polylines = {};

  // Track if map is expanded
  bool _isMapExpanded = false;

  // Loading state for directions
  bool _isLoading = true;
  bool _isLoadingRoute = true;

  // Custom markers for small map (smaller size)
  BitmapDescriptor? _smallTruckMarker;
  BitmapDescriptor? _smallPickupMarker;
  BitmapDescriptor? _smallDestinationMarker;

  // Custom markers for expanded map (bigger size)
  BitmapDescriptor? _expandedTruckMarker;
  BitmapDescriptor? _expandedPickupMarker;
  BitmapDescriptor? _expandedDestinationMarker;

  // Store LatLng positions for reuse
  LatLng? _pickupLatLng;
  LatLng? _currentLatLng;
  LatLng? _destinationLatLng;
  LatLng? _lastVehicleMarkerLatLng;
  double _lastVehicleBearing = 0;

  // Tracking data
  TrackingData? _trackingData;

  // Estimated delivery time from vehicle to destination
  String _estimatedDuration = '';

  // Intermediate route stops
  List<Map<String, dynamic>> _routeStops = [];
  DateTime? _routeStartTime;
  int _totalRouteDurationSeconds = 0;

  // Full polyline data for sub-stop generation
  List<LatLng> _fullPolyline = [];
  List<double> _cumulativeDistances = [];

  // Segment-based snapping: tracks which segment the driver is on.
  // Grows forward-only so green/blue split stays stable.
  int _currentSegmentIndex = 0;

  // Snap pipeline state (mirrors employee screen)
  LatLng? _lastAcceptedSnap;
  LatLng? _lastAcceptedRaw;
  LatLng? _snapCacheInput;
  LatLng? _snapCacheOutput;

  // Historical green path preserved across reroutes so the completed
  // line never collapses to a stub after the driver diverts.
  final List<LatLng> _preservedGreenPath = [];

  // Expandable sub-timelines
  int? _expandedSegmentIndex;
  Map<int, List<Map<String, dynamic>>> _subStopsCache = {};
  int? _loadingSegment;

  // ── FIXED TIMELINE (Layer 1: Business milestones — NEVER changes) ──
  // Generated once from full pickup→destination route, persisted to storage.
  List<Map<String, dynamic>> _fixedStops = [];
  bool _isLoadingFixedStops = true;
  bool _fixedStopsGenerated = false;
  int _currentStopIndex = -1; // -1 = not started, 0 = at/past first stop, etc.
  DateTime? _lastProgressUpdateTime; // Cooldown to prevent GPS jitter
  Map<int, String> _passedStopTimes = {}; // Locked times for passed stops

  // Full pickup→destination polyline (for fixed stop generation)
  List<LatLng> _fullRoutePolyline = [];
  List<double> _fullRouteCumulativeDistances = [];
  int _fullRouteDurationSeconds = 0;

  // Refresh state
  DateTime _lastRefreshedAt = DateTime.now();
  bool _isRefreshing = false;
  Timer? _timeAgoTimer;
  Timer? _autoRefreshTimer;
  Timer? _liveTrackingTimer;
  Timer? _markerAnimationTimer;
  DateTime? _lastRouteRefreshAt;

  // Pulse animation for vehicle icon
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    // Setup pulse animation for vehicle icon
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _pulseAnimation = Tween<double>(
      begin: 1.0,
      end: 2.5,
    ).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeOut));

    _initializeMap();
    // Update "Updated X mins ago" text every 30 seconds
    _timeAgoTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    // Refresh only the marker/live position frequently (every 10s).
    _liveTrackingTimer = Timer.periodic(_liveTrackingPollInterval, (_) {
      if (mounted && !_isRefreshing) {
        _refreshData();
      }
    });
    // Rebuild route shape rarely (every 5min), or sooner if off-route.
    _autoRefreshTimer = Timer.periodic(_routeRefreshInterval, (_) {
      if (mounted && !_isRefreshing) {
        _refreshData(forceRouteRefresh: true);
      }
    });
  }

  Future<void> _fetchTrackingData() async {
    final token = _storageService.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Session expired. Please login again.');
    }

    final response = await _authService.getDriverVehicleTracking(
      token: token,
      bookingId: widget.bookingId,
    );

    if (response['status'] != true) {
      throw Exception(response['message']?.toString() ?? 'No tracking data found');
    }

    final parsed = SpecificVehicleTrackingResponse.fromJson(response);
    if (parsed.data == null) {
      throw Exception('No tracking data found');
    }
    _trackingData = parsed.data;
  }

  Future<void> _initializeMap() async {
    try {
      await _fetchTrackingData();
      if (_trackingData == null) {
        setState(() {
          _isLoadingRoute = false;
          _isLoading = false;
        });
        return;
      }

      final driverLoc = _trackingData!.driverLocation;

      if (driverLoc.lat != 0 && driverLoc.lng != 0) {
        _currentVehiclePosition = LatLng(driverLoc.lat, driverLoc.lng);
      } else {
        _currentVehiclePosition = _defaultLocation;
      }

      _initialPosition = CameraPosition(
        target: _currentVehiclePosition,
        zoom: 10.0,
      );

      await _loadCustomMarkers();
      await _setupMarkersAndPolylines();

      setState(() {
        _lastRefreshedAt = DateTime.now();
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingRoute = false;
        });
      }
    }
  }

  Future<void> _refreshData({bool forceRouteRefresh = false}) async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);

    try {
      final oldPickup = _trackingData?.pickup;
      final oldDrop = _trackingData?.drop;
      final previousVehiclePosition = _currentLatLng;
      await _fetchTrackingData();
      final newData = _trackingData;

      if (newData != null) {
        _trackingData = newData;

        final driverLoc = newData.driverLocation;
        if (driverLoc.lat != 0 && driverLoc.lng != 0) {
          _currentVehiclePosition = LatLng(driverLoc.lat, driverLoc.lng);
          _currentLatLng = LatLng(driverLoc.lat, driverLoc.lng);
        }

        // Check if route endpoints changed (rare — usually only driver moves)
        final routeChanged = oldPickup?.name != newData.pickup.name ||
            oldDrop?.name != newData.drop.name;

        if (routeChanged) {
          // Full rebuild only when pickup/destination actually changes
          _routeStops = [];
          _routeStartTime = null;
          _totalRouteDurationSeconds = 0;
          _estimatedDuration = '';
          _fullPolyline = [];
          _cumulativeDistances = [];
          _expandedSegmentIndex = null;
          _subStopsCache = {};
          _loadingSegment = null;
          // Reset fixed timeline so it regenerates from new full route
          _fixedStopsGenerated = false;
          _fixedStops = [];
          _currentStopIndex = -1;
          _fullRoutePolyline = [];
          _fullRouteCumulativeDistances = [];
          _fullRouteDurationSeconds = 0;
          _passedStopTimes = {};
          // Clear cached stops so they regenerate
          SharedPreferences.getInstance().then((prefs) {
            prefs.remove('fixed_stops_${widget.bookingId}');
            prefs.remove('stop_index_${widget.bookingId}');
            prefs.remove('passed_stop_times_${widget.bookingId}');
          });

          await _setupMarkersAndPolylines();
        } else {
          // Silent update — only move vehicle marker, keep existing polylines
          if (previousVehiclePosition != null && _currentLatLng != null) {
            _animateVehicleMarker(previousVehiclePosition, _currentLatLng!);
          } else {
            _buildMarkers();
          }

          // Update driver location timestamp for route start recalculation
          if (driverLoc.updatedAt != null && driverLoc.updatedAt!.isNotEmpty) {
            try {
              _routeStartTime = DateTime.parse(driverLoc.updatedAt!);
            } catch (_) {}
          }

          // ── REROUTE DETECTION ──
          // If driver deviated >750m from polyline, recalculate route.
          if (_currentLatLng != null &&
              _shouldRefreshRoute(forceRefresh: forceRouteRefresh)) {
            final polylinePoints = _polylines
                .where((p) => p.polylineId.value != 'completed')
                .expand((p) => p.points)
                .toList();
            final deviation = _minDistanceToPolyline(
              _currentLatLng!,
              polylinePoints,
            );
            if (forceRouteRefresh ||
                deviation > _polylineRerouteThresholdMeters) {
              debugPrint(
                'Driver deviated ${deviation.toStringAsFixed(0)}m from '
                'polyline — recalculating route',
              );
              await _setupMarkersAndPolylines();
            }
          }

          // Check if driver reached the next stop (sequential progression)
          if (_currentLatLng != null) _updateProgress(_currentLatLng!);
          setState(() => _isLoadingRoute = false);
        }

        // Smoothly re-fit maps without flicker
        _fitSmallMapToAllMarkers();
        _fitExpandedMapToAllMarkers();
      }

      setState(() {
        _lastRefreshedAt = DateTime.now();
      });
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _loadCustomMarkers() async {
    // Small map markers (smaller size for compact view)
    _smallTruckMarker = await CustomMarkerHelper.getTruckMarkerFromAsset(
      size: 30,
    );
    _smallPickupMarker =
        await CustomMarkerHelper.getStartLocationMarkerFromAsset(size: 26);
    _smallDestinationMarker =
        await CustomMarkerHelper.getDropLocationMarkerFromAsset(size: 26);

    // Expanded map markers (bigger size for full screen view)
    _expandedTruckMarker = await CustomMarkerHelper.getTruckMarkerFromAsset(
      size: 60,
    );
    _expandedPickupMarker =
        await CustomMarkerHelper.getStartLocationMarkerFromAsset(size: 30);
    _expandedDestinationMarker =
        await CustomMarkerHelper.getDropLocationMarkerFromAsset(size: 30);
  }

  Future<void> _setupMarkersAndPolylines() async {
    _lastRouteRefreshAt = DateTime.now();
    if (_trackingData == null) return;

    final pickup = _trackingData!.pickup;
    final driverLoc = _trackingData!.driverLocation;
    final destination = _trackingData!.drop;

    Set<Polyline> polylines = {};

    /// -------- Get Pickup Coordinates --------
    if (pickup.lat != 0 && pickup.lng != 0) {
      _pickupLatLng = LatLng(pickup.lat, pickup.lng);
    } else if (pickup.name.isNotEmpty) {
      _pickupLatLng = await GoogleMapsService.geocodeAddress(pickup.name);
    }

    /// -------- Get Current Location Coordinates --------
    if (driverLoc.lat != 0 && driverLoc.lng != 0) {
      _currentLatLng = LatLng(driverLoc.lat, driverLoc.lng);
    }

    /// -------- Get Destination Coordinates --------
    if (destination.lat != 0 && destination.lng != 0) {
      _destinationLatLng = LatLng(destination.lat, destination.lng);
    } else if (destination.name.isNotEmpty) {
      _destinationLatLng = await GoogleMapsService.geocodeAddress(
        destination.name,
      );
    }

    // Build markers for both small and expanded views
    _buildMarkers();

    /// -------- Route + Intermediate Stops using single Directions API call --------
    if (_pickupLatLng != null && _destinationLatLng != null) {
      // Separate waypoints into delivered (completed) and remaining (pending/in-progress)
      // Sorted by priority so polyline follows the intended delivery order
      final allWaypoints = _trackingData!.routeWaypoints
          .where((wp) => wp.lat != 0 && wp.lng != 0)
          .toList()
        ..sort((a, b) => a.priority.compareTo(b.priority));
      final remainingWaypoints = allWaypoints
          .where((wp) => !wp.isCompleted)
          .map((wp) => LatLng(wp.lat, wp.lng))
          .toList();

      // When driver position is available, calculate route from DRIVER → remaining stops → destination.
      // This gives accurate ETA because it uses the actual road from where the driver IS,
      // not the shortest path from pickup which may be a completely different road.
      // Example: Chennai → Vijayawada(delivered) → Amalapuram
      //   Old: origin=Chennai, waypoints=[], dest=Amalapuram → shortest direct route (WRONG)
      //   New: origin=DriverPos(near Vijayawada), waypoints=[], dest=Amalapuram → actual road (CORRECT)
      final routeOrigin = _currentLatLng ?? _pickupLatLng!;
      final useDriverAsOrigin = _currentLatLng != null;

      debugPrint(
        '🗺️ Route params: origin=$routeOrigin (driver=$useDriverAsOrigin), '
        'dest=$_destinationLatLng, remainingWaypoints=${remainingWaypoints.length}, '
        'totalWaypoints=${allWaypoints.length}',
      );

      final routeData = await GoogleMapsService.getRouteWithStops(
        origin: routeOrigin,
        destination: _destinationLatLng!,
        driverPosition: useDriverAsOrigin ? null : _currentLatLng,
        routeWaypoints: remainingWaypoints,
      );

      if (routeData.isNotEmpty) {
        final remainingPointsRoute =
            routeData['remaining_points'] as List<LatLng>? ?? [];
        final completedFromApi =
            routeData['completed_points'] as List<LatLng>? ?? [];
        _routeStops = routeData['stops'] as List<Map<String, dynamic>>? ?? [];
        _totalRouteDurationSeconds =
            routeData['total_duration_seconds'] as int? ?? 0;
        _fullPolyline = routeData['polyline_points'] as List<LatLng>? ?? [];
        _cumulativeDistances =
            (routeData['cumulative_distances'] as List?)?.cast<double>() ?? [];

        final remainingSeconds =
            routeData['remaining_duration_seconds'] as int? ?? 0;

        if (useDriverAsOrigin) {
          // Route was calculated from driver → destination, so the ENTIRE
          // route duration IS the remaining ETA (no fraction math needed)
          _estimatedDuration = _formatDuration(_totalRouteDurationSeconds);

          // Route start time = driver's last update (journey is "starting" from driver)
          final driverLoc = _trackingData!.driverLocation;
          if (driverLoc.updatedAt != null && driverLoc.updatedAt!.isNotEmpty) {
            try {
              _routeStartTime = DateTime.parse(driverLoc.updatedAt!);
            } catch (_) {}
          }

          // Green solid line: pickup → driver (road-following via timeline GPS points)
          List<LatLng> completedRoute = [];

          // Collect timeline GPS points for the traveled path
          final timelineCoords = <LatLng>[];
          for (final item in _trackingData!.timeline) {
            if (item.lat != null && item.lng != null) {
              timelineCoords.add(LatLng(item.lat!, item.lng!));
            }
          }

          if (timelineCoords.isNotEmpty) {
            // Sample max 10 evenly spaced points as via waypoints
            const maxPoints = 10;
            List<LatLng> viaPoints;
            if (timelineCoords.length <= maxPoints) {
              viaPoints = timelineCoords;
            } else {
              viaPoints = [];
              final step = timelineCoords.length / maxPoints;
              for (int i = 0; i < maxPoints; i++) {
                viaPoints.add(timelineCoords[(i * step).floor()]);
              }
              viaPoints[viaPoints.length - 1] = timelineCoords.last;
            }

            // Get road-snapped route using via waypoints
            completedRoute = await GoogleMapsService.getDirections(
              origin: _pickupLatLng!,
              destination: _currentLatLng!,
              waypoints: viaPoints,
              useViaWaypoints: true,
            );
          }

          // Fallback: direct road route without timeline
          if (completedRoute.isEmpty) {
            completedRoute = await GoogleMapsService.getDirections(
              origin: _pickupLatLng!,
              destination: _currentLatLng!,
            );
          }

          // Final fallback: straight line
          if (completedRoute.isEmpty) {
            completedRoute = [_pickupLatLng!, _currentLatLng!];
          }

          polylines.add(
            Polyline(
              polylineId: const PolylineId('completed'),
              points: completedRoute,
              color: Colors.green,
              width: 5,
              patterns: [PatternItem.dash(20), PatternItem.gap(10)],
            ),
          );
          // Remaining route: split into forward (blue) + return (yellow)
          // Forward = driver → last waypoint, Return = last waypoint → destination
          final allRoutePoints = [...completedFromApi, ...remainingPointsRoute];
          if (allRoutePoints.isNotEmpty) {
            _addSplitPolylines(polylines, allRoutePoints, remainingWaypoints);
          }
        } else if (_currentLatLng != null && completedFromApi.isNotEmpty) {
          // Fallback: route from pickup with driver as waypoint (original logic)
          final driverFraction =
              routeData['driver_progress_fraction'] as double? ?? 0.0;
          _estimatedDuration = _formatDuration(remainingSeconds);

          final driverLoc = _trackingData!.driverLocation;
          if (driverLoc.updatedAt != null && driverLoc.updatedAt!.isNotEmpty) {
            try {
              final updatedAt = DateTime.parse(driverLoc.updatedAt!);
              final elapsedSeconds =
                  (driverFraction * _totalRouteDurationSeconds).round();
              _routeStartTime = updatedAt.subtract(
                Duration(seconds: elapsedSeconds),
              );
            } catch (_) {}
          }

          // Green solid line: pickup to driver position (completed)
          polylines.add(
            Polyline(
              polylineId: const PolylineId('completed'),
              points: completedFromApi,
              color: Colors.green,
              width: 5,
              patterns: [PatternItem.dash(20), PatternItem.gap(10)],
            ),
          );
          // Remaining: split into forward (blue) + return (yellow)
          if (remainingPointsRoute.isNotEmpty) {
            _addSplitPolylines(
              polylines,
              remainingPointsRoute,
              remainingWaypoints,
            );
          }
        } else if (remainingPointsRoute.isNotEmpty) {
          _estimatedDuration = _formatDuration(remainingSeconds);
          // No current location — full route as dashed blue
          polylines.add(
            Polyline(
              polylineId: const PolylineId('full_route'),
              points: remainingPointsRoute,
              color: const Color(0xFF0077C8),
              width: 5,
              patterns: [PatternItem.dash(20), PatternItem.gap(10)],
            ),
          );
        }
      } else {
        // Directions API failed — never draw straight chords between
        // pickup / driver / destination. At country-scale they cross oceans
        // and rivers; at city-scale they cut through buildings. Show no
        // polyline until the next successful Directions call.
        debugPrint('❌ Directions API failed — keeping previous polylines');
        if (_polylines.isNotEmpty) {
          polylines = Set<Polyline>.from(_polylines);
        }
      }
    }

    // Calculate initial camera position to show full route
    _calculateInitialCameraPosition();

    setState(() {
      _polylines = polylines;
      _isLoadingRoute = false;
    });

    // ── FIXED TIMELINE: generate once, persist, only update progress ──
    if (!_fixedStopsGenerated && _pickupLatLng != null && _destinationLatLng != null) {
      final loaded = await _loadFixedStops();
      if (loaded) {
        // Stops from cache — still need full route polyline for time/sub-stops
        await _fetchFullRoutePolyline();
      } else {
        // No cache — generate stops from full route and persist
        await _fetchFullRouteAndGenerateFixedStops();
        await _saveFixedStops();
      }
      await _loadCurrentStopIndex();
      _fixedStopsGenerated = true;
    }
    // Check if driver reached the next stop
    if (_currentLatLng != null) _updateProgress(_currentLatLng!);
  }

  // ── REROUTE DETECTION HELPER ──
  bool _shouldRefreshRoute({bool forceRefresh = false}) {
    if (forceRefresh) return true;
    if (_lastRouteRefreshAt == null) return true;
    return DateTime.now().difference(_lastRouteRefreshAt!) >= _rerouteCooldown;
  }

  // ── BUILD COMPLETED POLYLINE FROM TIMELINE POINTS ──
  List<LatLng> _buildCompletedTimelinePolyline({
    List<LatLng> fallbackPoints = const [],
  }) {
    final points = <LatLng>[];

    if (_pickupLatLng != null) {
      points.add(_pickupLatLng!);
    }

    if (_trackingData != null) {
      for (final item in _trackingData!.timeline) {
        if (item.lat == null || item.lng == null) continue;
        final nextPoint = LatLng(item.lat!, item.lng!);
        if (points.isEmpty ||
            _haversineDistance(points.last, nextPoint) >=
                _timelinePointMinDistanceMeters) {
          points.add(nextPoint);
        }
      }
    }

    if (_currentLatLng != null &&
        (points.isEmpty ||
            _haversineDistance(points.last, _currentLatLng!) >=
                _timelinePointMinDistanceMeters)) {
      points.add(_currentLatLng!);
    }

    if (points.length >= 2) return points;
    if (fallbackPoints.isNotEmpty) return fallbackPoints;
    if (_pickupLatLng != null && _currentLatLng != null) {
      return [_pickupLatLng!, _currentLatLng!];
    }
    return points;
  }

  /// Splits the existing road-following polyline at the driver's current
  /// position into completed (green) and remaining (blue) segments.
  /// No API call needed — uses the cached `_fullPolyline` from Directions API.
  void _refreshCompletedPolylineFromTimeline() {
    if (_currentLatLng == null) return;

    // If we have a road-following polyline, split it at the driver position
    if (_fullPolyline.length >= 2) {
      final splitIndex = _getClosestPolylineIndex(_currentLatLng!);

      final completedPoints = _fullPolyline.sublist(0, splitIndex + 1);
      final remainingPoints = _fullPolyline.sublist(splitIndex);

      if (completedPoints.isNotEmpty) {
        completedPoints.add(_currentLatLng!);
      }
      if (remainingPoints.isNotEmpty) {
        remainingPoints.insert(0, _currentLatLng!);
      }

      if (completedPoints.length < 2 && remainingPoints.length < 2) return;

      final updatedPolylines = _polylines
          .where((p) =>
              p.polylineId.value != 'completed' &&
              p.polylineId.value != 'remaining')
          .toSet();

      if (completedPoints.length >= 2) {
        updatedPolylines.add(
          Polyline(
            polylineId: const PolylineId('completed'),
            points: completedPoints,
            color: Colors.green,
            width: 5,
          ),
        );
      }
      if (remainingPoints.length >= 2) {
        updatedPolylines.add(
          Polyline(
            polylineId: const PolylineId('remaining'),
            points: remainingPoints,
            color: const Color(0xFF0077C8),
            width: 4,
            patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _polylines = updatedPolylines;
      });
      return;
    }

    // Fallback: straight line from timeline points
    final completedRoute = _buildCompletedTimelinePolyline();
    if (completedRoute.length < 2) return;

    final updatedPolylines = _polylines
        .where((polyline) => polyline.polylineId.value != 'completed')
        .toSet();
    updatedPolylines.add(
      Polyline(
        polylineId: const PolylineId('completed'),
        points: completedRoute,
        color: Colors.green,
        width: 5,
      ),
    );

    if (!mounted) return;
    setState(() {
      _polylines = updatedPolylines;
    });
  }

  // ── SMOOTH MARKER ANIMATION (Uber-like) ──
  // Cubic ease-in-out for smooth acceleration/deceleration
  double _easeInOutCubic(double t) {
    return t < 0.5 ? 4 * t * t * t : 1 - ((-2 * t + 2) * (-2 * t + 2) * (-2 * t + 2)) / 2;
  }

  void _animateVehicleMarker(LatLng from, LatLng to) {
    _markerAnimationTimer?.cancel();

    if (_haversineDistance(from, to) < 2) {
      _buildMarkers();
      if (mounted) setState(() {});
      return;
    }

    // Calculate target bearing for smooth rotation
    final startBearing = _lastVehicleBearing;
    final endBearing = _getBearing(from, to);

    int step = 0;
    _markerAnimationTimer = Timer.periodic(_markerAnimationStepDuration, (timer) {
      step++;
      final linearT = step / _markerAnimationSteps;
      final easedT = _easeInOutCubic(linearT);

      // Smooth position interpolation with easing
      _currentLatLng = LatLng(
        from.latitude + (to.latitude - from.latitude) * easedT,
        from.longitude + (to.longitude - from.longitude) * easedT,
      );

      // Smooth bearing interpolation (shortest rotation path)
      double bearingDiff = endBearing - startBearing;
      if (bearingDiff > 180) bearingDiff -= 360;
      if (bearingDiff < -180) bearingDiff += 360;
      _lastVehicleBearing = (startBearing + bearingDiff * easedT) % 360;

      _buildMarkers();
      if (mounted) setState(() {});

      if (step >= _markerAnimationSteps) {
        timer.cancel();
        _currentLatLng = to;
        _lastVehicleBearing = endBearing;
        _buildMarkers();
        if (mounted) setState(() {});
      }
    });
  }

  // ── MIN DISTANCE FROM POINT TO POLYLINE ──
  double _minDistanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return double.infinity;
    double minDist = double.infinity;
    for (final p in polyline) {
      final d = _haversineDistance(point, p);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  double _getBearing(LatLng start, LatLng end) {
    double lat1 = start.latitude * pi / 180;
    double lon1 = start.longitude * pi / 180;
    double lat2 = end.latitude * pi / 180;
    double lon2 = end.longitude * pi / 180;

    double dLon = lon2 - lon1;

    double y = sin(dLon) * cos(lat2);
    double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);

    double bearing = atan2(y, x);
    return (bearing * 180 / pi + 360) % 360;
  }

  int _getClosestPolylineIndex(LatLng current) {
    double minDist = double.infinity;
    int index = 0;

    for (int i = 0; i < _fullPolyline.length; i++) {
      final d =
          (_fullPolyline[i].latitude - current.latitude).abs() +
          (_fullPolyline[i].longitude - current.longitude).abs();

      if (d < minDist) {
        minDist = d;
        index = i;
      }
    }

    return index;
  }

  double _getRouteBearing(LatLng current) {
    if (_fullPolyline.length < 2) return 0;

    int index = _getClosestPolylineIndex(current);

    // prevent overflow
    if (index >= _fullPolyline.length - 1) {
      index = _fullPolyline.length - 2;
    }

    final start = _fullPolyline[index];
    final end = _fullPolyline[index + 1];

    return _getBearing(start, end);
  }

  void _updateVehicleBearing(LatLng? previous, LatLng? current) {
    if (previous == null || current == null) return;
    if (_haversineDistance(previous, current) < 2) return;
    _lastVehicleBearing = _getBearing(previous, current);
  }

  double _getVehicleBearing() {
    if (_lastVehicleMarkerLatLng != null && _currentLatLng != null) {
      _updateVehicleBearing(_lastVehicleMarkerLatLng, _currentLatLng);
    }

    if (_lastVehicleBearing != 0) {
      return _lastVehicleBearing;
    }

    if (_currentLatLng != null && _fullPolyline.isNotEmpty) {
      return _getRouteBearing(_currentLatLng!);
    }

    return 0;
  }

  /// Build markers for both small and expanded map views
  void _buildMarkers() {
    if (_trackingData == null) return;

    final pickup = _trackingData!.pickup;
    final driverLoc = _trackingData!.driverLocation;
    final destination = _trackingData!.drop;

    Set<Marker> smallMarkers = {};
    Set<Marker> expandedMarkers = {};

    /// -------- Pickup --------
    if (_pickupLatLng != null) {
      smallMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickupLatLng!,
          icon:
              _smallPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Pickup', snippet: pickup.name),
        ),
      );

      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickupLatLng!,
          icon:
              _expandedPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Pickup', snippet: pickup.name),
        ),
      );
    }

    /// -------- Vehicle (ONLY ONCE) --------
    if (_currentLatLng != null) {
      final rotationAngle = _getVehicleBearing();

      smallMarkers.add(
        Marker(
          markerId: const MarkerId('vehicle'),
          position: _currentLatLng!,
          icon: _smallTruckMarker!,
          anchor: const Offset(0.5, 0.5),
          rotation: rotationAngle,
          flat: true,
          infoWindow: InfoWindow(title: 'Vehicle', snippet: driverLoc.name),
        ),
      );

      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('vehicle'),
          position: _currentLatLng!,
          icon: _expandedTruckMarker!,
          anchor: const Offset(0.5, 0.5),
          rotation: rotationAngle,
          flat: true,
          infoWindow: InfoWindow(title: 'Vehicle', snippet: driverLoc.name),
        ),
      );
    }

    /// -------- Destination --------
    if (_destinationLatLng != null) {
      smallMarkers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: _destinationLatLng!,
          icon:
              _smallDestinationMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Destination',
            snippet: destination.name,
          ),
        ),
      );

      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: _destinationLatLng!,
          icon:
              _expandedDestinationMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Destination',
            snippet: destination.name,
          ),
        ),
      );
    }

    _smallMapMarkers = smallMarkers;
    _expandedMapMarkers = expandedMarkers;
    _lastVehicleMarkerLatLng = _currentLatLng;
  }

  /// Calculate initial camera position to show the full route
  void _calculateInitialCameraPosition() {
    List<LatLng> points = [];

    if (_pickupLatLng != null) points.add(_pickupLatLng!);
    if (_currentLatLng != null) points.add(_currentLatLng!);
    if (_destinationLatLng != null) points.add(_destinationLatLng!);

    if (points.isEmpty) return;

    if (points.length == 1) {
      _initialPosition = CameraPosition(target: points.first, zoom: 14.0);
      return;
    }

    // Calculate center point
    double minLat = points.first.latitude;
    double maxLat = minLat;
    double minLng = points.first.longitude;
    double maxLng = minLng;

    for (final point in points) {
      minLat = min(minLat, point.latitude);
      maxLat = max(maxLat, point.latitude);
      minLng = min(minLng, point.longitude);
      maxLng = max(maxLng, point.longitude);
    }

    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;

    // Calculate zoom level based on distance
    final latDiff = maxLat - minLat;
    final lngDiff = maxLng - minLng;
    final maxDiff = max(latDiff, lngDiff);

    double zoom;
    if (maxDiff > 5) {
      zoom = 6;
    } else if (maxDiff > 2) {
      zoom = 7;
    } else if (maxDiff > 1) {
      zoom = 8;
    } else if (maxDiff > 0.5) {
      zoom = 9;
    } else if (maxDiff > 0.2) {
      zoom = 10;
    } else if (maxDiff > 0.1) {
      zoom = 11;
    } else if (maxDiff > 0.05) {
      zoom = 12;
    } else {
      zoom = 13;
    }

    _initialPosition = CameraPosition(
      target: LatLng(centerLat, centerLng),
      zoom: zoom,
    );
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
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _trackingData == null
                      ? const Center(child: Text("No tracking data found"))
                      : _isMapExpanded
                          ? _buildExpandedMapView(width, height)
                          : _buildDefaultView(width, height),
            ),
          ],
        ),
      ),
    );
  }

  /// Default view: Map fills top, draggable bottom sheet with details
  Widget _buildDefaultView(double width, double height) {
    return Stack(
      children: [
        /// ── Map fills entire background ──
        Column(
          children: [Expanded(child: _buildSmallMapSection(width, height))],
        ),

        /// ── Floating ETA pill on map ──
        if (_estimatedDuration.isNotEmpty)
          Positioned(
            top: height * 0.015,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.05,
                  vertical: width * 0.025,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: width * 0.02),
                    Text(
                      'Arriving in ',
                      style: TextStyle(
                        fontSize: width * 0.033,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    Text(
                      _estimatedDuration,
                      style: TextStyle(
                        fontSize: width * 0.038,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        /// ── Expand map button ──
        Positioned(
          top: height * 0.015,
          right: width * 0.04,
          child: GestureDetector(
            onTap: () => setState(() => _isMapExpanded = true),
            child: Container(
              padding: EdgeInsets.all(width * 0.025),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                Icons.fullscreen,
                size: width * 0.05,
                color: Colors.black87,
              ),
            ),
          ),
        ),

        /// ── Draggable Bottom Sheet ──
        DraggableScrollableSheet(
          initialChildSize: 0.42,
          minChildSize: 0.15,
          maxChildSize: 0.85,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.zero,
                children: [
                  /// Drag handle
                  Center(
                    child: Container(
                      margin: EdgeInsets.only(
                        top: height * 0.012,
                        bottom: height * 0.01,
                      ),
                      width: width * 0.1,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  /// Live status bar
                  _buildLiveStatusBar(width, height),

                  /// Driver card
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.04,
                      vertical: height * 0.008,
                    ),
                    child: _buildDriverCard(width, height),
                  ),

                  /// Vehicle status + delivery info
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: width * 0.04),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildVehicleStatus(width, height),
                        SizedBox(height: height * 0.008),
                        _buildDeliveryInfo(width, height),
                        SizedBox(height: height * 0.012),
                        _buildTravelCostRow(width),
                      ],
                    ),
                  ),

                  /// Divider
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: height * 0.012),
                    child: Divider(
                      color: Colors.grey.shade200,
                      thickness: 6,
                      height: 0,
                    ),
                  ),

                  /// Timeline
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: width * 0.04),
                    child: _buildLocationTimeline(width, height),
                  ),

                  SizedBox(height: height * 0.03),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  String _timeAgoText() {
    final diff = DateTime.now().difference(_lastRefreshedAt);
    if (diff.inSeconds < 60) return 'Updated just now';
    if (diff.inMinutes < 60) {
      return 'Updated ${diff.inMinutes} min${diff.inMinutes > 1 ? 's' : ''} ago';
    }
    return 'Updated ${diff.inHours} hour${diff.inHours > 1 ? 's' : ''} ago';
  }

  Widget _buildRefreshBar(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    final driverLoc = _trackingData!.driverLocation;
    final locationName = driverLoc.name.isNotEmpty
        ? driverLoc.name
        : 'Location not available';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.05,
        vertical: height * 0.015,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        border: Border(top: BorderSide(color: Colors.grey.shade300, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Arrived $locationName",
                  style: TextStyle(
                    fontSize: width * 0.037,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 2),
                Text(
                  _timeAgoText(),
                  style: TextStyle(
                    fontSize: width * 0.03,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: width * 0.03),
          GestureDetector(
            onTap: _isRefreshing ? null : _refreshData,
            child: Container(
              width: width * 0.12,
              height: width * 0.12,
              decoration: BoxDecoration(
                color: const Color(0xFF0077C8),
                shape: BoxShape.circle,
              ),
              child: _isRefreshing
                  ? Padding(
                      padding: EdgeInsets.all(width * 0.03),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      Icons.refresh,
                      color: Colors.white,
                      size: width * 0.06,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Expanded map view with Last Update card
  Widget _buildExpandedMapView(double width, double height) {
    return Stack(
      children: [
        // Full screen Google Map
        GoogleMap(
          mapType: MapType.normal,
          initialCameraPosition: _initialPosition,
          markers: _expandedMapMarkers,
          polylines: _polylines,
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: true,
          mapToolbarEnabled: true,
          scrollGesturesEnabled: true,
          zoomGesturesEnabled: true,
          rotateGesturesEnabled: true,
          tiltGesturesEnabled: true,
          padding: EdgeInsets.only(
            bottom: height * 0.16,
            right: width * 0.02,
            top: height * 0.02,
          ),
          onMapCreated: (GoogleMapController controller) {
            _expandedMapController = controller;
            Future.delayed(const Duration(milliseconds: 300), () {
              _fitExpandedMapToAllMarkers();
            });
          },
        ),

        // Loading indicator for route
        if (_isLoadingRoute)
          const Center(
            child: CircularProgressIndicator(color: Color(0xFF0077C8)),
          ),

        // Center on vehicle button
        Positioned(
          bottom: height * 0.3,
          right: width * 0.04,
          child: GestureDetector(
            onTap: _centerOnVehicle,
            child: Container(
              padding: EdgeInsets.all(width * 0.03),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                Icons.my_location,
                size: width * 0.06,
                color: const Color(0xFF0077C8),
              ),
            ),
          ),
        ),

        // Last Update Card at bottom
        Positioned(
          bottom: height * 0.02,
          left: width * 0.04,
          right: width * 0.04,
          child: _buildLastUpdateCard(width, height),
        ),
      ],
    );
  }

  /// Fit expanded map to show all markers
  void _fitExpandedMapToAllMarkers() {
    if (_expandedMapController == null) return;

    List<LatLng> allPoints = [];
    if (_pickupLatLng != null) allPoints.add(_pickupLatLng!);
    if (_currentLatLng != null) allPoints.add(_currentLatLng!);
    if (_destinationLatLng != null) allPoints.add(_destinationLatLng!);

    if (allPoints.isEmpty) return;

    try {
      double minLat = allPoints.first.latitude;
      double maxLat = minLat;
      double minLng = allPoints.first.longitude;
      double maxLng = minLng;

      for (final point in allPoints) {
        minLat = min(minLat, point.latitude);
        maxLat = max(maxLat, point.latitude);
        minLng = min(minLng, point.longitude);
        maxLng = max(maxLng, point.longitude);
      }

      // Add padding to bounds
      final latPadding = (maxLat - minLat) * 0.2;
      final lngPadding = (maxLng - minLng) * 0.2;

      // Ensure minimum padding
      const minPadding = 0.01;
      final actualLatPadding = max(latPadding, minPadding);
      final actualLngPadding = max(lngPadding, minPadding);

      _expandedMapController!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(
              minLat - actualLatPadding,
              minLng - actualLngPadding,
            ),
            northeast: LatLng(
              maxLat + actualLatPadding,
              maxLng + actualLngPadding,
            ),
          ),
          60,
        ),
      );
    } catch (e) {
      debugPrint('Error fitting expanded map to markers: $e');
    }
  }

  /// Fit small map to show all markers
  void _fitSmallMapToAllMarkers() {
    if (_smallMapController == null) return;

    List<LatLng> allPoints = [];
    if (_pickupLatLng != null) allPoints.add(_pickupLatLng!);
    if (_currentLatLng != null) allPoints.add(_currentLatLng!);
    if (_destinationLatLng != null) allPoints.add(_destinationLatLng!);

    if (allPoints.isEmpty) return;

    try {
      double minLat = allPoints.first.latitude;
      double maxLat = minLat;
      double minLng = allPoints.first.longitude;
      double maxLng = minLng;

      for (final point in allPoints) {
        minLat = min(minLat, point.latitude);
        maxLat = max(maxLat, point.latitude);
        minLng = min(minLng, point.longitude);
        maxLng = max(maxLng, point.longitude);
      }

      // Add padding to bounds
      final latPadding = (maxLat - minLat) * 0.2;
      final lngPadding = (maxLng - minLng) * 0.2;

      // Ensure minimum padding
      const minPadding = 0.01;
      final actualLatPadding = max(latPadding, minPadding);
      final actualLngPadding = max(lngPadding, minPadding);

      _smallMapController!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(
              minLat - actualLatPadding,
              minLng - actualLngPadding,
            ),
            northeast: LatLng(
              maxLat + actualLatPadding,
              maxLng + actualLngPadding,
            ),
          ),
          40,
        ),
      );
    } catch (e) {
      debugPrint('Error fitting small map to markers: $e');
    }
  }

  Widget _buildHeader(BuildContext context, double width, double height) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.04,
        vertical: height * 0.012,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (_isMapExpanded) {
                setState(() => _isMapExpanded = false);
              } else {
                Navigator.pop(context);
              }
            },
            child: Container(
              padding: EdgeInsets.all(width * 0.02),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_back_ios_new,
                size: width * 0.04,
                color: Colors.black87,
              ),
            ),
          ),
          SizedBox(width: width * 0.03),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Vehicle tracking',
                style: TextStyle(
                  fontSize: width * 0.045,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              Text(
                'Order #${widget.bookingId}',
                style: TextStyle(
                  fontSize: width * 0.03,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          RefreshButton(onTap: _refreshData),
        ],
      ),
    );
  }

  Widget _buildSmallMapSection(double width, double height) {
    return Stack(
      children: [
        GoogleMap(
          mapType: MapType.normal,
          initialCameraPosition: _initialPosition,
          markers: _smallMapMarkers,
          polylines: _polylines,
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          scrollGesturesEnabled: true,
          zoomGesturesEnabled: true,
          rotateGesturesEnabled: true,
          tiltGesturesEnabled: true,
          padding: EdgeInsets.only(bottom: height * 0.15),
          onMapCreated: (GoogleMapController controller) {
            _smallMapController = controller;
            Future.delayed(const Duration(milliseconds: 300), () {
              _fitSmallMapToAllMarkers();
            });
          },
        ),
        if (_isLoadingRoute)
          Container(
            color: Colors.white.withValues(alpha: 0.5),
            child: const Center(
              child: CircularProgressIndicator(color: Color(0xFF0077C8)),
            ),
          ),
      ],
    );
  }

  /// Live status bar with pulsing dot and location
  Widget _buildLiveStatusBar(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    final driverLoc = _trackingData!.driverLocation;
    final locationName = driverLoc.name.isNotEmpty
        ? driverLoc.name
        : 'Tracking...';

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: width * 0.04,
        vertical: height * 0.005,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.04,
        vertical: width * 0.03,
      ),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade100),
      ),
      child: Row(
        children: [
          // Pulsing live dot
          SizedBox(
            width: 12,
            height: 12,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Container(
                      width: 12 * _pulseAnimation.value * 0.6,
                      height: 12 * _pulseAnimation.value * 0.6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.green.withValues(
                          alpha:
                              (1.0 - (_pulseAnimation.value - 1.0) / 1.5) * 0.3,
                        ),
                      ),
                    );
                  },
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: width * 0.03),
          Text(
            'LIVE',
            style: TextStyle(
              fontSize: width * 0.028,
              fontWeight: FontWeight.w800,
              color: Colors.green.shade700,
              letterSpacing: 1.2,
            ),
          ),
          SizedBox(width: width * 0.03),
          Expanded(
            child: Text(
              locationName,
              style: TextStyle(
                fontSize: width * 0.033,
                color: Colors.green.shade800,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _timeAgoText(),
            style: TextStyle(
              fontSize: width * 0.028,
              color: Colors.green.shade600,
            ),
          ),
        ],
      ),
    );
  }

  /// Modern driver card with avatar, info, and call button
  Widget _buildDriverCard(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    final driver = _trackingData!.driverDetails;
    final driverName = driver.driverName.isNotEmpty
        ? driver.driverName
        : 'Not assigned';
    final vehicleNumber = driver.vehicleNumber.isNotEmpty
        ? driver.vehicleNumber
        : 'N/A';
    final driverPhone = driver.driverPhone;

    return Container(
      padding: EdgeInsets.all(width * 0.035),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Driver avatar
          Container(
            width: width * 0.13,
            height: width * 0.13,
            decoration: BoxDecoration(
              color: const Color(0xFF0077C8).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: driver.driverImage.isNotEmpty
                ? ClipOval(
                    child: Image.network(
                      driver.driverImage,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.person,
                        size: width * 0.07,
                        color: const Color(0xFF0077C8),
                      ),
                    ),
                  )
                : Icon(
                    Icons.person,
                    size: width * 0.07,
                    color: const Color(0xFF0077C8),
                  ),
          ),
          SizedBox(width: width * 0.035),
          // Driver info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  driverName,
                  style: TextStyle(
                    fontSize: width * 0.04,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.local_shipping_outlined,
                      size: width * 0.035,
                      color: Colors.grey.shade500,
                    ),
                    SizedBox(width: width * 0.015),
                    Text(
                      vehicleNumber,
                      style: TextStyle(
                        fontSize: width * 0.033,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Call button
          if (driverPhone.isNotEmpty)
            GestureDetector(
              onTap: () async {
                final uri = Uri(scheme: 'tel', path: driverPhone);
                if (await canLaunchUrl(uri)) await launchUrl(uri);
              },
              child: Container(
                padding: EdgeInsets.all(width * 0.03),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Icon(
                  Icons.phone,
                  size: width * 0.05,
                  color: Colors.green.shade700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDriverDetails(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    final driver = _trackingData!.driverDetails;
    final driverName = driver.driverName.isNotEmpty
        ? driver.driverName
        : 'Not assigned';
    final driverMobile = driver.driverPhone.isNotEmpty
        ? '+91${driver.driverPhone}'
        : 'N/A';
    final vehicleNumber = driver.vehicleNumber.isNotEmpty
        ? driver.vehicleNumber
        : 'N/A';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Driver Details',
          style: TextStyle(
            fontSize: width * 0.042,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: height * 0.015),
        Wrap(
          spacing: width * 0.08,
          runSpacing: height * 0.016,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _infoItem(
              icon: Icons.person_outline,
              text: driverName,
              width: width,
            ),
            _infoItem(
              icon: Icons.phone_outlined,
              text: driverMobile,
              width: width,
            ),
            _infoItem(
              icon: Icons.local_shipping_outlined,
              text: vehicleNumber,
              width: width,
            ),
          ],
        ),
      ],
    );
  }

  Widget _infoItem({
    required IconData icon,
    required String text,
    required double width,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: width * 0.05, color: Colors.grey.shade700),
        SizedBox(width: width * 0.02),
        Text(
          text,
          style: TextStyle(
            fontSize: width * 0.038,
            color: Colors.grey.shade800,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ],
    );
  }

  Widget _buildVehicleStatus(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    String statusMessage =
        _trackingData!.vehicleDescription ??
        (_trackingData!.deliveryUpdates.note.isNotEmpty
            ? _trackingData!.deliveryUpdates.note
            : 'We\'ve received your booking. Within a few days, we will assign your vehicle');

    return Container(
      padding: EdgeInsets.all(width * 0.035),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: width * 0.04,
                color: const Color(0xFF0077C8),
              ),
              SizedBox(width: width * 0.02),
              Text(
                'Status',
                style: TextStyle(
                  fontSize: width * 0.035,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.008),
          Text(
            statusMessage,
            style: TextStyle(
              fontSize: width * 0.033,
              color: Colors.grey.shade600,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeliveryInfo(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    final deliveryExpected = _trackingData!.deliveryUpdates.deliveryExpected;
    final expectedDelivery = _trackingData!.expectedDelivery;

    String deliveryText = '';

    if (deliveryExpected.isNotEmpty) {
      deliveryText = 'Delivery Expected on $deliveryExpected';
    } else if (expectedDelivery.isNotEmpty && expectedDelivery != 'N/A') {
      deliveryText = 'Delivery Expected on $expectedDelivery';
    }

    if (deliveryText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Text(
      deliveryText,
      style: TextStyle(fontSize: width * 0.036, color: Colors.grey.shade700),
    );
  }

  Widget _buildTravelCostRow(double width) {
    if (_trackingData == null) return const SizedBox.shrink();
    final travelCost = _trackingData!.travelCost;
    final expectedDelivery = _trackingData!.expectedDelivery;
    if (travelCost == 'N/A' &&
        (expectedDelivery == 'N/A' || expectedDelivery.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        if (travelCost != 'N/A')
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xffF6F6F6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Travel cost',
                    style: TextStyle(
                      color: const Color(0xff374151),
                      fontSize: width * 0.035,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '₹$travelCost',
                    style: TextStyle(
                      fontSize: width * 0.035,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (travelCost != 'N/A' &&
            expectedDelivery != 'N/A' &&
            expectedDelivery.isNotEmpty)
          const SizedBox(width: 8),
        if (expectedDelivery != 'N/A' && expectedDelivery.isNotEmpty)
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xffF6F6F6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Delivery Expected on',
                    style: TextStyle(
                      color: const Color(0xff374151),
                      fontSize: width * 0.035,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    expectedDelivery,
                    style: TextStyle(
                      fontSize: width * 0.035,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _addSplitPolylines(
    Set<Polyline> polylines,
    List<LatLng> routePoints,
    List<LatLng> waypoints,
  ) {
    if (routePoints.length < 2) return;

    polylines.add(
      Polyline(
        polylineId: const PolylineId('remaining'),
        points: routePoints,
        color: const Color(0xFF0077C8), // blue
        width: 5,
        patterns: [PatternItem.dash(20), PatternItem.gap(10)],
      ),
    );
  }

  /// Handle timeline item tap — expand/collapse sub-stops
  void _onTimelineTap(
    int segmentIndex,
    double prevFraction,
    double currentFraction,
  ) async {
    // Toggle if already expanded
    if (_expandedSegmentIndex == segmentIndex) {
      setState(() => _expandedSegmentIndex = null);
      return;
    }

    // If already cached, just expand
    if (_subStopsCache.containsKey(segmentIndex)) {
      setState(() => _expandedSegmentIndex = segmentIndex);
      return;
    }

    // Need to generate sub-stops
    if (_fullPolyline.isEmpty || _cumulativeDistances.isEmpty) return;

    setState(() {
      _loadingSegment = segmentIndex;
      _expandedSegmentIndex = segmentIndex;
    });

    final subStops = await GoogleMapsService.generateSubStops(
      fullPolyline: _fullPolyline,
      cumulativeDistances: _cumulativeDistances,
      startFraction: prevFraction,
      endFraction: currentFraction,
      totalDurationSeconds: _totalRouteDurationSeconds,
      count: 3,
    );

    if (mounted) {
      setState(() {
        _subStopsCache[segmentIndex] = subStops;
        _loadingSegment = null;
      });
    }
  }

  Widget _buildLocationTimeline(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    final pickup = _trackingData!.pickup;
    final driverLoc = _trackingData!.driverLocation;
    final destination = _trackingData!.drop;

    final hasCurrentLocation = driverLoc.lat != 0 && driverLoc.lng != 0;

    List<Widget> timelineItems = [];

    /// -------- Pickup (always green, always first) --------
    // Use journey start time for pickup, not driver's current updatedAt
    final pickupTime = (_trackingData!.inProgressAt != null && _trackingData!.inProgressAt!.isNotEmpty)
        ? _formatDateTime(_trackingData!.inProgressAt)
        : _formatDateTime(driverLoc.updatedAt);
    timelineItems.add(
      _buildTimelineItem(
        width,
        height,
        Icons.location_on,
        Colors.green,
        'Pickup started from',
        pickup.name.isNotEmpty ? pickup.name : 'N/A',
        pickupTime,
        isFirst: true,
        isPassed: true,
      ),
    );

    // Check if driver is AT a fixed stop (within threshold) — if so, merge into that stop
    bool driverAtFixedStop = false;
    if (hasCurrentLocation && _currentStopIndex >= 0 && _currentStopIndex < _fixedStops.length) {
      final currentStop = _fixedStops[_currentStopIndex];
      final stopLatLng = LatLng(currentStop['lat'] as double, currentStop['lng'] as double);
      final dist = _haversineDistance(_currentLatLng!, stopLatLng);
      driverAtFixedStop = dist < 10000; // within 10km = driver is at this stop
    }

    // Vehicle widget — only show as separate item if NOT at a fixed stop and NOT near pickup
    final bool driverNearPickup = hasCurrentLocation &&
        _pickupLatLng != null &&
        _haversineDistance(_currentLatLng!, _pickupLatLng!) < 10000; // within 10km
    Widget? vehicleWidget;
    if (hasCurrentLocation && !driverAtFixedStop && !driverNearPickup) {
      vehicleWidget = _buildTimelineItem(
        width,
        height,
        Icons.local_shipping,
        Colors.green,
        driverLoc.name.isNotEmpty ? driverLoc.name : 'Current Location',
        _formatDate(driverLoc.updatedAt),
        _formatDateTime(driverLoc.updatedAt),
        isPulsing: true,
        isPassed: true,
      );
    }

    bool vehicleInserted = false;

    /// -------- Fixed Stops (NEVER changes, only color updates) --------
    if (_isLoadingFixedStops && _fixedStops.isEmpty) {
      if (vehicleWidget != null) {
        timelineItems.add(vehicleWidget);
        vehicleInserted = true;
      }
      timelineItems.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: height * 0.01),
          child: Row(
            children: [
              SizedBox(width: width * 0.09, child: Center(child: Container(width: 2, height: height * 0.04, color: Colors.grey.shade300))),
              SizedBox(width: width * 0.04),
              SizedBox(width: width * 0.04, height: width * 0.04, child: const CircularProgressIndicator(strokeWidth: 1.5)),
              SizedBox(width: width * 0.02),
              Text('Loading route...', style: TextStyle(fontSize: width * 0.03, color: Colors.grey)),
            ],
          ),
        ),
      );
    } else {
      bool newTimesLocked = false;
      for (int i = 0; i < _fixedStops.length; i++) {
        final isPassed = i <= _currentStopIndex;

        // Insert vehicle AFTER the last passed stop (right before first grey stop)
        if (!vehicleInserted && vehicleWidget != null && !isPassed) {
          timelineItems.add(vehicleWidget);
          vehicleInserted = true;
        }

        final stop = _fixedStops[i];
        final name = stop['name'] as String? ?? 'Stop ${i + 1}';
        final isKeyStop = stop['is_key_stop'] == true;
        final isDriverHere = driverAtFixedStop && i == _currentStopIndex;

        final stopColor = isPassed ? Colors.green : Colors.black;
        String? subtitle;
        if (isDriverHere) {
          subtitle = _formatDate(driverLoc.updatedAt);
        } else if (isKeyStop) {
          subtitle = isPassed ? 'Passed' : 'Key Stop';
        } else if (isPassed) {
          subtitle = 'Passed';
        }

        // Calculate time: locked for passed stops, dynamic for future stops
        final stopFraction = _getStopFraction(i);
        String time;
        if (isDriverHere) {
          time = _formatDateTime(driverLoc.updatedAt);
        } else if (isPassed) {
          // Use locked time if available, otherwise lock the current estimated time
          if (_passedStopTimes.containsKey(i)) {
            time = _passedStopTimes[i]!;
          } else {
            time = _getTimeForFraction(stopFraction);
            if (time != '-') {
              _passedStopTimes[i] = time;
              newTimesLocked = true;
            }
          }
        } else {
          time = _getTimeForFraction(stopFraction);
        }

        // Fractions for sub-stop generation on tap
        final nextFraction = i < _fixedStops.length - 1
            ? _getStopFraction(i + 1)
            : 1.0;
        final segmentIndex = i + 1;

        timelineItems.add(
          GestureDetector(
            onTap: () {
              _onTimelineTap(segmentIndex, stopFraction, nextFraction);
            },
            child: _buildTimelineItem(
              width,
              height,
              isDriverHere ? Icons.local_shipping : Icons.circle,
              stopColor,
              name,
              subtitle,
              time,
              isKeyStop: isKeyStop,
              isPassed: isPassed,
              isPulsing: isDriverHere,
            ),
          ),
        );

        // ── Sub-stops expand on click ──
        final isExpanded = _expandedSegmentIndex == segmentIndex;
        final isLoading = _loadingSegment == segmentIndex;

        if (isExpanded) {
          timelineItems.add(
            _buildSubTimeline(
              width,
              height,
              segmentIndex,
              isLoading,
              isPassed ? Colors.green : Colors.grey,
            ),
          );
        }
      }

      // Vehicle after all stops if driver is past everything
      if (!vehicleInserted && vehicleWidget != null) {
        timelineItems.add(vehicleWidget);
        vehicleInserted = true;
      }

      // Persist any newly locked passed stop times
      if (newTimesLocked) _savePassedStopTimes();
    }

    /// -------- Destination --------
    // Use fraction=1.0 for destination to stay consistent with stop times
    final destinationTime = _getTimeForFraction(1.0);

    timelineItems.add(
      _buildTimelineItem(
        width,
        height,
        Icons.flag,
        Colors.black,
        'Destination',
        destination.name.isNotEmpty ? destination.name : 'N/A',
        destinationTime,
        isLast: true,
      ),
    );

    return Column(children: timelineItems);
  }

  // ══════════════════════════════════════════════════════════════════════
  // FIXED TIMELINE — Layer 1: Business milestones (NEVER changes)
  // ══════════════════════════════════════════════════════════════════════

  /// Haversine distance in meters between two LatLng points.
  double _haversineDistance(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(a.latitude * pi / 180) *
            cos(b.latitude * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return 2 * earthRadius * asin(sqrt(h));
  }

  /// Fetch only the full route polyline (no stop generation).
  /// Used when stops are loaded from cache but polyline is needed for time/sub-stops.
  Future<void> _fetchFullRoutePolyline() async {
    if (_pickupLatLng == null || _destinationLatLng == null) return;
    if (_fullRoutePolyline.isNotEmpty) return; // Already fetched

    final sortedWaypoints = (_trackingData?.routeWaypoints ?? [])
        .where((wp) => wp.lat != 0 && wp.lng != 0)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final allWaypoints = sortedWaypoints
        .map((wp) => LatLng(wp.lat, wp.lng))
        .toList();

    final routeData = await GoogleMapsService.getRouteWithStops(
      origin: _pickupLatLng!,
      destination: _destinationLatLng!,
      routeWaypoints: allWaypoints,
    );

    if (routeData.isNotEmpty) {
      final polylinePoints = routeData['polyline_points'] as List<LatLng>? ?? [];
      final remaining = routeData['remaining_points'] as List<LatLng>? ?? [];
      final completed = routeData['completed_points'] as List<LatLng>? ?? [];
      _fullRoutePolyline = polylinePoints.isNotEmpty
          ? polylinePoints
          : [...completed, ...remaining];

      _fullRouteCumulativeDistances = [0.0];
      for (int i = 1; i < _fullRoutePolyline.length; i++) {
        _fullRouteCumulativeDistances.add(
          _fullRouteCumulativeDistances.last +
              _haversineDistance(_fullRoutePolyline[i - 1], _fullRoutePolyline[i]),
        );
      }
      _fullRouteDurationSeconds = routeData['total_duration_seconds'] as int? ?? _totalRouteDurationSeconds;
    }
  }

  /// Fetch full pickup→destination route and generate fixed stops.
  /// Called ONCE — stops are then persisted and never regenerated.
  Future<void> _fetchFullRouteAndGenerateFixedStops() async {
    if (_pickupLatLng == null || _destinationLatLng == null) return;

    setState(() => _isLoadingFixedStops = true);

    // Include ALL waypoints for the full route, sorted by priority
    final sortedWps = (_trackingData?.routeWaypoints ?? [])
        .where((wp) => wp.lat != 0 && wp.lng != 0)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final allWaypoints = sortedWps
        .map((wp) => LatLng(wp.lat, wp.lng))
        .toList();

    final routeData = await GoogleMapsService.getRouteWithStops(
      origin: _pickupLatLng!,
      destination: _destinationLatLng!,
      routeWaypoints: allWaypoints,
    );

    if (routeData.isEmpty) {
      setState(() => _isLoadingFixedStops = false);
      return;
    }

    final polylinePoints = routeData['polyline_points'] as List<LatLng>? ?? [];
    final remaining = routeData['remaining_points'] as List<LatLng>? ?? [];
    final completed = routeData['completed_points'] as List<LatLng>? ?? [];
    final fullPolyline = polylinePoints.isNotEmpty
        ? polylinePoints
        : [...completed, ...remaining];
    final totalDuration = routeData['total_duration_seconds'] as int? ?? _totalRouteDurationSeconds;

    // Build cumulative distances
    List<double> cumDist = [0.0];
    for (int i = 1; i < fullPolyline.length; i++) {
      cumDist.add(cumDist.last + _haversineDistance(fullPolyline[i - 1], fullPolyline[i]));
    }

    _fullRoutePolyline = fullPolyline;
    _fullRouteCumulativeDistances = cumDist;
    _fullRouteDurationSeconds = totalDuration;

    // Calculate stop count: 1 stop per hour, min 3, max 20
    final totalHours = totalDuration / 3600.0;
    int stopCount;
    if (totalHours <= 1) {
      stopCount = 3;
    } else if (totalHours <= 3) {
      stopCount = 4;
    } else {
      stopCount = totalHours.round().clamp(5, 20);
    }

    // Build waypoint entries (key stops), sorted by priority
    final waypoints = (_trackingData?.routeWaypoints ?? [])
        ..sort((a, b) => a.priority.compareTo(b.priority));
    final List<Map<String, dynamic>> waypointStops = [];
    final Set<String> waypointNames = {};

    for (final wp in waypoints) {
      if (wp.lat == 0 && wp.lng == 0) continue;
      waypointStops.add({
        'name': wp.name.isNotEmpty ? wp.name : 'Waypoint',
        'lat': wp.lat,
        'lng': wp.lng,
        'is_key_stop': true,
      });
      if (wp.name.isNotEmpty) waypointNames.add(wp.name.toLowerCase());
    }

    // Generate auto stops along the full route
    final autoStops = await GoogleMapsService.generateSubStops(
      fullPolyline: fullPolyline,
      cumulativeDistances: cumDist,
      startFraction: 0.0,
      endFraction: 1.0,
      totalDurationSeconds: totalDuration,
      count: stopCount,
    );

    // Filter duplicates
    final filteredAutoStops = <Map<String, dynamic>>[];
    for (final stop in autoStops) {
      final name = (stop['name'] as String? ?? '').toLowerCase();
      if (waypointNames.contains(name) || name == 'unknown') continue;

      final loc = stop['location'] as LatLng?;
      if (loc == null) continue;

      // Skip if too close to any waypoint
      bool tooClose = false;
      for (final wp in waypointStops) {
        if (_haversineDistance(loc, LatLng(wp['lat'] as double, wp['lng'] as double)) < 5000) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;

      filteredAutoStops.add({
        'name': stop['name'],
        'lat': loc.latitude,
        'lng': loc.longitude,
        'is_key_stop': false,
      });
    }

    // Merge, order by position on the polyline
    final allStops = [...waypointStops, ...filteredAutoStops];

    // Sort by distance along full polyline
    for (final stop in allStops) {
      final sLat = stop['lat'] as double;
      final sLng = stop['lng'] as double;
      double minD = double.infinity;
      int bestIdx = 0;
      for (int i = 0; i < fullPolyline.length; i++) {
        final d = _haversineDistance(LatLng(sLat, sLng), fullPolyline[i]);
        if (d < minD) {
          minD = d;
          bestIdx = i;
        }
      }
      stop['_sortDist'] = cumDist[bestIdx];
    }
    allStops.sort((a, b) => (a['_sortDist'] as double).compareTo(b['_sortDist'] as double));
    // Remove sort key
    for (final stop in allStops) {
      stop.remove('_sortDist');
    }

    if (mounted) {
      setState(() {
        _fixedStops = allStops;
        _isLoadingFixedStops = false;
      });
    }
  }

  /// Uber-style progress: scan all FORWARD stops, find nearest within radius.
  /// Allows skipping stops (e.g., driver bypasses a city).
  /// Never moves backward. Cooldown prevents GPS jitter false triggers.
  void _updateProgress(LatLng currentLocation) {
    if (_fixedStops.isEmpty) return;

    // ── Cooldown: ignore updates within 20 seconds of last progress change ──
    if (_lastProgressUpdateTime != null) {
      final elapsed = DateTime.now().difference(_lastProgressUpdateTime!);
      if (elapsed.inSeconds < 20) return;
    }

    // ── Scan only FORWARD stops (never look backward) ──
    int bestIndex = -1;
    double bestDistance = double.infinity;

     debugPrint("📡 DRIVER LOCATION: ${currentLocation.latitude}, ${currentLocation.longitude}");
    for (int i = _currentStopIndex + 1; i < _fixedStops.length; i++) {
      final stop = _fixedStops[i];
      final stopLatLng = LatLng(stop['lat'] as double, stop['lng'] as double);
      
      final distance = _haversineDistance(currentLocation, stopLatLng);

      // ── Dynamic radius based on stop type ──
      final isKeyStop = stop['is_key_stop'] == true;
      final threshold = isKeyStop ? 8000.0 : 4000.0; // city: 8km, town: 4km

      if (distance < threshold && distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }

    // ── Update only if we found a valid forward stop ──
    if (bestIndex > _currentStopIndex) {
      // Lock the time for all newly passed stops
      final now = DateTime.now();
      for (int j = _currentStopIndex + 1; j <= bestIndex; j++) {
        if (!_passedStopTimes.containsKey(j)) {
          _passedStopTimes[j] = _formatDateTimeObj(now);
        }
      }
      setState(() => _currentStopIndex = bestIndex);
      _lastProgressUpdateTime = now;
      _saveCurrentStopIndex();
      _savePassedStopTimes();
    }
    
    debugPrint("🎯 BEST INDEX FOUND: $bestIndex");
  }

  /// Save current stop index to SharedPreferences.
  Future<void> _saveCurrentStopIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('stop_index_${widget.bookingId}', _currentStopIndex);
    } catch (e) {
      debugPrint('Error saving stop index: $e');
    }
  }

  /// Load current stop index from SharedPreferences.
  Future<void> _loadCurrentStopIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt('stop_index_${widget.bookingId}') ?? -1;
      setState(() => _currentStopIndex = idx);
      _loadPassedStopTimes();
    } catch (e) {
      debugPrint('Error loading stop index: $e');
    }
  }

  /// Save passed stop times to SharedPreferences.
  Future<void> _savePassedStopTimes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _passedStopTimes.map((k, v) => MapEntry(k.toString(), v));
      await prefs.setString(
        'passed_stop_times_${widget.bookingId}',
        jsonEncode(data),
      );
    } catch (e) {
      debugPrint('Error saving passed stop times: $e');
    }
  }

  /// Load passed stop times from SharedPreferences.
  Future<void> _loadPassedStopTimes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('passed_stop_times_${widget.bookingId}');
      if (json == null || json.isEmpty) return;
      final Map<String, dynamic> decoded = jsonDecode(json);
      setState(() {
        _passedStopTimes = decoded.map((k, v) => MapEntry(int.parse(k), v.toString()));
      });
    } catch (e) {
      debugPrint('Error loading passed stop times: $e');
    }
  }

  /// Save fixed stops to SharedPreferences.
  Future<void> _saveFixedStops() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serializable = _fixedStops.map((stop) {
        return {
          'name': stop['name'],
          'lat': stop['lat'],
          'lng': stop['lng'],
          'is_key_stop': stop['is_key_stop'],
        };
      }).toList();
      await prefs.setString(
        'fixed_stops_${widget.bookingId}',
        jsonEncode(serializable),
      );
    } catch (e) {
      debugPrint('Error saving fixed stops: $e');
    }
  }

  /// Load fixed stops from SharedPreferences. Returns true if loaded.
  Future<bool> _loadFixedStops() async {

    
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('fixed_stops_${widget.bookingId}');
      if (json == null || json.isEmpty) return false;

      final List<dynamic> decoded = jsonDecode(json);
      final stops = decoded.map((item) {
        return Map<String, dynamic>.from(item);
      }).toList();
debugPrint("📦 Loaded Fixed Stops from storage:");

for (var stop in stops) {
  debugPrint("→ ${stop['name']}");
}
      if (stops.isNotEmpty) {
        setState(() {
          _fixedStops = stops;
          _isLoadingFixedStops = false;
        });
        return true;
      }
    } catch (e) {
      debugPrint('Error loading fixed stops: $e');
    }
    return false;
  }

  /// Get the distance fraction of a fixed stop on the full route polyline.
  double _getStopFraction(int stopIndex) {
    if (stopIndex < 0 || stopIndex >= _fixedStops.length) return 0.0;
    if (_fullRoutePolyline.isEmpty || _fullRouteCumulativeDistances.isEmpty) return 0.0;

    final stop = _fixedStops[stopIndex];
    final stopLatLng = LatLng(stop['lat'] as double, stop['lng'] as double);

    double minDist = double.infinity;
    int closestIdx = 0;
    for (int i = 0; i < _fullRoutePolyline.length; i++) {
      final d = _haversineDistance(stopLatLng, _fullRoutePolyline[i]);
      if (d < minDist) {
        minDist = d;
        closestIdx = i;
      }
    }
    return _fullRouteCumulativeDistances[closestIdx] / _fullRouteCumulativeDistances.last;
  }

  String _getTimeForFraction(double fraction) {
    // Use full route duration for fraction-based time calculation
    // so each stop gets a distinct time proportional to its distance along the route
    final duration = _fullRouteDurationSeconds > 0
        ? _fullRouteDurationSeconds
        : _totalRouteDurationSeconds;
    if (duration == 0) return '-';

    // Use journey start time (inProgressAt) as base for full route times,
    // fallback to routeStartTime
    DateTime? baseTime;
    if (_trackingData?.inProgressAt != null && _trackingData!.inProgressAt!.isNotEmpty) {
      try {
        baseTime = DateTime.parse(_trackingData!.inProgressAt!);
      } catch (_) {}
    }
    baseTime ??= _routeStartTime;
    if (baseTime == null) return '-';

    final seconds = (fraction * duration).round();
    final dt = baseTime.add(Duration(seconds: seconds));

    return _formatDateTimeObj(dt);
  }

  /// Build the sub-timeline items between two main stops
  Widget _buildSubTimeline(
    double width,
    double height,
    int segmentIndex,
    bool isLoading,
    Color lineColor,
  ) {
    if (isLoading && !_subStopsCache.containsKey(segmentIndex)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column — same width as main timeline icon column
          SizedBox(
            width: width * 0.09,
            child: Center(
              child: Container(
                width: 2,
                height: height * 0.04,
                color: Colors.grey.shade300,
              ),
            ),
          ),
          SizedBox(width: width * 0.04),
          Padding(
            padding: EdgeInsets.only(top: height * 0.012),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: width * 0.04,
                  height: width * 0.04,
                  child: const CircularProgressIndicator(strokeWidth: 1.5),
                ),
                SizedBox(width: width * 0.02),
                Text(
                  'Loading...',
                  style: TextStyle(fontSize: width * 0.03, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final subStops = _subStopsCache[segmentIndex];
    if (subStops == null || subStops.isEmpty) return const SizedBox.shrink();

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Column(
        children: subStops.map((sub) {
          String subTime = '-';
          if (_routeStartTime != null) {
            final seconds = sub['estimated_seconds'] as int? ?? 0;
            final dt = _routeStartTime!.add(Duration(seconds: seconds));
            subTime = _formatDateTimeObj(dt);
          }
          return _buildSubTimelineItem(
            width,
            height,
            sub['name'],
            subTime,
            lineColor,
          );
        }).toList(),
      ),
    );
  }

  /// Single sub-timeline item (smaller dot, lighter style)
  Widget _buildSubTimelineItem(
    double width,
    double height,
    String name,
    String time,
    Color lineColor,
  ) {
    final dotSize = width * 0.025;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left column — same width as main timeline, centered line + dot
        SizedBox(
          width: width * 0.09,
          child: Column(
            children: [
              Container(
                width: 2,
                height: height * 0.015,
                color: Colors.grey.shade300,
              ),
              Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: lineColor.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                  color: Colors.white,
                ),
              ),
              Container(
                width: 2,
                height: height * 0.015,
                color: Colors.grey.shade300,
              ),
            ],
          ),
        ),
        SizedBox(width: width * 0.04),
        // Content — vertically centered with the dot
        Expanded(
          child: Container(
            height: height * 0.03 + dotSize,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: width * 0.033,
                      color: Colors.grey.shade600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(width: width * 0.02),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: width * 0.03,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatDateTime(String? dateTimeStr) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '-';
    // A date-only value (e.g. "2026-07-21") carries no real clock time; parsing
    // it yields midnight and would render a misleading "12:00 AM" default. Only
    // format when the source actually has a time component — otherwise the
    // caller shows the real start time (in_progress_at) or nothing.
    if (!dateTimeStr.contains(':')) return '-';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      final hour = dateTime.hour > 12
          ? dateTime.hour - 12
          : (dateTime.hour == 0 ? 12 : dateTime.hour);
      final amPm = dateTime.hour >= 12 ? 'PM' : 'AM';
      return '${hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} $amPm';
    } catch (e) {
      return '-';
    }
  }

  String _formatDate(String? dateTimeStr) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      return '${dateTime.day.toString().padLeft(2, '0')}/${dateTime.month.toString().padLeft(2, '0')}/${dateTime.year}';
    } catch (e) {
      return '';
    }
  }

  /// Convert "HH:mm" (24h) string to "hh:mm AM/PM" (12h) format
  String _format24to12(String time24) {
    try {
      final parts = time24.split(':');
      final hour24 = int.parse(parts[0]);
      final minute = parts[1];
      final hour = hour24 > 12 ? hour24 - 12 : (hour24 == 0 ? 12 : hour24);
      final amPm = hour24 >= 12 ? 'PM' : 'AM';
      return '${hour.toString().padLeft(2, '0')}:$minute $amPm';
    } catch (_) {
      return time24;
    }
  }

  String _formatDateTimeObj(DateTime dateTime) {
    final hour = dateTime.hour > 12
        ? dateTime.hour - 12
        : (dateTime.hour == 0 ? 12 : dateTime.hour);
    final amPm = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '${hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} $amPm';
  }

  String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) return '$hours hours $minutes mins';
    if (hours > 0) return '$hours hours';
    return '$minutes mins';
  }

  Widget _buildTimelineItem(
    double width,
    double height,
    IconData icon,
    Color iconColor,
    String title,
    String? subtitle,
    String time, {
    bool isFirst = false,
    bool isLast = false,
    bool etaLabel = false,
    bool isPulsing = false,
    bool isKeyStop = false,
    bool isPassed = false,
  }) {
    final isActive = iconColor == Colors.green || isPassed;
    final activeColor = Colors.green;
    final iconCircle = Container(
      width: width * 0.09,
      height: width * 0.09,
      decoration: BoxDecoration(
        color: isActive ? activeColor.shade50 : Colors.grey.shade100,
        shape: BoxShape.circle,
        border: Border.all(
          color: isActive ? activeColor : Colors.grey.shade300,
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: width * 0.04,
        color: isActive ? activeColor : Colors.grey.shade500,
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            isPulsing
                ? SizedBox(
                    width: width * 0.09,
                    height: width * 0.09,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: _pulseAnimation,
                          builder: (context, child) {
                            final size = width * 0.09 * _pulseAnimation.value;
                            final offset = (size - width * 0.09) / 2;
                            return Positioned(
                              left: -offset,
                              top: -offset,
                              child: Container(
                                width: size,
                                height: size,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.green.withValues(
                                    alpha:
                                        (1.0 -
                                            (_pulseAnimation.value - 1.0) /
                                                1.5) *
                                        0.4,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        // Solid icon circle
                        iconCircle,
                      ],
                    ),
                  )
                : iconCircle,
            if (!isLast)
              Builder(
                builder: (context) {
                  double lineHeight;
                  if (subtitle != null && subtitle.isNotEmpty) {
                    // Measure subtitle lines to adjust connecting line height
                    final textSpan = TextSpan(
                      text: subtitle,
                      style: TextStyle(fontSize: width * 0.034),
                    );
                    final tp = TextPainter(
                      text: textSpan,
                      textDirection: TextDirection.ltr,
                      maxLines: 2,
                    );
                    tp.layout(maxWidth: width * 0.55);
                    final lines = tp.computeLineMetrics().length;
                    if (lines >= 2) {
                      lineHeight = height * 0.04;
                    } else {
                      lineHeight = height * 0.061;
                    }
                  } else {
                    lineHeight = height * 0.035;
                  }
                  return Container(
                    width: isPassed ? 3 : 2,
                    height: lineHeight,
                    color: isPassed ? Colors.green : Colors.grey.shade300,
                  );
                },
              ),
          ],
        ),
        SizedBox(width: width * 0.04),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: isKeyStop ? width * 0.042 : width * 0.038,
                            fontWeight: isKeyStop ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                        if (subtitle != null && subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: width * 0.034,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  SizedBox(width: width * 0.02),
                  etaLabel
                      ? Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: width * 0.025,
                            vertical: width * 0.012,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF0077C8,
                            ).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Deliver in',
                                style: TextStyle(
                                  fontSize: width * 0.028,
                                  color: const Color(0xFF0077C8),
                                ),
                              ),
                              SizedBox(height: width * 0.005),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.access_time,
                                    size: width * 0.035,
                                    color: const Color(0xFF0077C8),
                                  ),
                                  SizedBox(width: width * 0.01),
                                  Text(
                                    time,
                                    style: TextStyle(
                                      fontSize: width * 0.032,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF0077C8),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        )
                      : Text(
                          time,
                          style: TextStyle(
                            fontSize: width * 0.036,
                            color: Colors.grey.shade600,
                          ),
                        ),
                ],
              ),
              if (!isLast) SizedBox(height: height * 0.0),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLastUpdateCard(double width, double height) {
    if (_trackingData == null) return const SizedBox.shrink();

    final driverLoc = _trackingData!.driverLocation;
    final hasCurrentLocation = driverLoc.lat != 0 && driverLoc.lng != 0;

    // Get last update from driverLocation.updatedAt
    String lastUpdateTime = _formatDateTime(driverLoc.updatedAt);
    String lastUpdateDate = _formatDate(driverLoc.updatedAt);
    print("checking for last update $lastUpdateDate");
    print("checking for last update $lastUpdateTime");
    // Get location name from API response
    String locationName = driverLoc.name.isNotEmpty
        ? driverLoc.name
        : 'Location not available';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.04,
        vertical: width * 0.035,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Live indicator
          Container(
            padding: EdgeInsets.all(width * 0.025),
            decoration: BoxDecoration(
              color: hasCurrentLocation
                  ? Colors.green.shade50
                  : Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.local_shipping,
              size: width * 0.045,
              color: hasCurrentLocation ? Colors.green : Colors.grey,
            ),
          ),
          SizedBox(width: width * 0.03),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  locationName,
                  style: TextStyle(
                    fontSize: width * 0.036,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 2),
                Text(
                  '$lastUpdateTime, $lastUpdateDate',
                  style: TextStyle(
                    fontSize: width * 0.03,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          // Center on vehicle
          GestureDetector(
            onTap: _centerOnVehicle,
            child: Container(
              padding: EdgeInsets.all(width * 0.025),
              decoration: BoxDecoration(
                color: const Color(0xFF0077C8).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.my_location,
                size: width * 0.045,
                color: const Color(0xFF0077C8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _centerOnVehicle() {
    if (_expandedMapController == null) {
      debugPrint('Expanded map controller is null');
      return;
    }

    // If no current location, fit to all markers instead
    if (_currentLatLng == null) {
      _fitExpandedMapToAllMarkers();
      return;
    }

    try {
      _expandedMapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _currentLatLng!, zoom: 15.0),
        ),
      );
    } catch (e) {
      debugPrint('Error centering on vehicle: $e');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _timeAgoTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _liveTrackingTimer?.cancel();
    _markerAnimationTimer?.cancel();
    _smallMapController?.dispose();
    _expandedMapController?.dispose();
    super.dispose();
  }
}
