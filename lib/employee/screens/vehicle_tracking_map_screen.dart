import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/widgets/refresh_button.dart';
import 'package:bestseeds/utils/custom_marker_helper.dart';
import 'package:bestseeds/utils/google_maps_service.dart';
import 'package:bestseeds/driver/models/specific_vehicle_tracking_response.dart';
import 'package:bestseeds/driver/service/auth_service.dart';

class VehicleTrackingMapScreen extends StatefulWidget {
  final Booking booking;

  const VehicleTrackingMapScreen({super.key, required this.booking});

  @override
  State<VehicleTrackingMapScreen> createState() =>
      _VehicleTrackingMapScreenState();
}

class _VehicleTrackingMapScreenState extends State<VehicleTrackingMapScreen>
    with TickerProviderStateMixin {
  final AuthService _authService = AuthService();
  final StorageService _storageService = StorageService();

  // Separate controllers for small and expanded maps
  GoogleMapController? _smallMapController;
  GoogleMapController? _expandedMapController;

  // Default location (Hyderabad, India)
  static const LatLng _defaultLocation = LatLng(17.3850, 78.4867);
  static const Duration _liveTrackingPollInterval = Duration(seconds: 7);
  static const Duration _routeRefreshInterval = Duration(minutes: 2);
  // Minimum gap between two reroute API calls. 15 seconds is the
  // responsive-but-safe lower bound: prevents a flickering GPS from
  // firing back-to-back reroutes while still letting a real deviation
  // produce a fresh blue route within ~1 poll interval.
  static const Duration _rerouteCooldown = Duration(seconds: 15);
  static const Duration _markerAnimationStepDuration = Duration(
    milliseconds: 40,
  );
  static const int _markerAnimationSteps = 25; // 25 × 40ms = 1 second
  // Driver is considered "off route" the moment their perpendicular
  // distance to the blue polyline exceeds this. 100 m is below the
  // width of any parallel road, so legitimate lane drift won't trigger
  // it, but a genuine wrong turn onto a different road will.
  static const double _polylineRerouteThresholdMeters = 100;
  static const double _timelinePointMinDistanceMeters = 8;

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

  // Last snap rendered to the polyline. Used as the anchor for the live
  // gap-protection check, and reset on every refresh so the protection
  // can't latch and freeze the green line behind the truck.
  LatLng? _lastRenderedSnap;

  // Follow mode: camera tracks vehicle. Default ON.
  bool _isFollowingVehicle = true;
  bool _isProgrammaticCameraMove = false; // distinguish user drag vs animateCamera
  static const double _followZoom = 16.5;
  static const double _followTilt = 45.0; // 3D perspective tilt
  // Auto-resume follow mode after the user stops touching the map for this
  // long. Without this a single accidental pinch / pan abandons the truck
  // off-screen for the rest of a long trip.
  static const Duration _followAutoResumeDelay = Duration(seconds: 8);
  Timer? _followResumeTimer;

  // Segment-based snapping: track which polyline segment the vehicle is on.
  // Only search nearby segments (forward) instead of entire route.
  int _currentSegmentIndex = 0;

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

  // Actual GPS breadcrumbs — the real path the driver took.
  // Used for the green completed polyline instead of Directions API route.
  List<LatLng> _driverBreadcrumbs = [];
  DateTime? _lastBreadcrumbTime;

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
  Map<int, String> _passedStopTimes = {}; // Locked times for passed stops

  // Full pickup→destination polyline (for fixed stop generation)
  List<LatLng> _fullRoutePolyline = [];
  List<double> _fullRouteCumulativeDistances = [];
  int _fullRouteDurationSeconds = 0;

  // Live "remaining duration to drop" from Google. Refreshed on every
  // route fetch / reroute. Used by `_getTimeForFraction` to anchor
  // FUTURE stop ETAs on `now + remainingDuration` so a halt at any stop
  // pushes every downstream stop forward by the halt duration.
  int _remainingDurationSeconds = 0;

  // Locally-computed driver speed (exponentially smoothed). Computed
  // from successive poll positions, NOT trusted from the backend's
  // pre-baked `speed_kmh` field — the backend value can be stale or
  // miscomputed. We measure the actual distance traveled between polls
  // and divide by elapsed seconds, then smooth to prevent a single GPS
  // spike from flipping the value.
  // Used by `_adaptiveRemainingSeconds()` to scale Google's static
  // total-route duration into a real-time ETA.
  double _estimatedSpeedKmh = 0;
  LatLng? _lastSpeedCalcPos;
  DateTime? _lastSpeedCalcTime;

  // Preserved historical green path — the portion of the journey the
  // truck has already driven, as it was BEFORE the most recent reroute.
  // Prepended to the segment-slice green on every render so the
  // travelled line never collapses back to a stub after a route change.
  // See customer file (`Bestseeds-user/...`) for full rationale.
  final List<LatLng> _preservedGreenPath = [];

  // Admin pickup marker (shown where admin set the start, may differ from driver pickup)
  LatLng? _homeMarkerLatLng;
  // Approach polyline: admin_pickup → driver start (fetched once via Directions API)
  List<LatLng> _approachPolyline = [];

  // Snap pipeline state
  LatLng? _lastAcceptedSnap;
  LatLng? _lastAcceptedRaw;
  LatLng? _snapCacheInput;
  LatLng? _snapCacheOutput;

  // Reroute deviation counter
  int _consecutiveDeviations = 0;

  // Granular driver status (5-state). Gate 0 freezes only on 'idle'.
  DriverStatus _driverStatus = DriverStatus.moving;

  // Speed-based dynamic mode: 0=city, 1=suburban, 2=highway
  int _currentMode = 0;
  int _pendingMode = 0;
  int _pendingModeCount = 0;
  static const int _modeChangeThreshold = 3;

  // Point buffer: hold 3+ points before committing to breadcrumbs.
  // Only commit when direction is confirmed across 3 consecutive consistent samples.
  List<LatLng> _pointBuffer = [];
  static const int _minBufferCommitPoints = 3;

  // Multi-drop active-drop gating (always true for employee — employee sees all drops)
  bool _isActiveDrop = true;

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

    // Update "Updated X mins ago" text every 30 seconds
    _timeAgoTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    // Start polling only after init completes to prevent race condition
    _initializeMap().whenComplete(() {
      if (!mounted) return;
      _liveTrackingTimer = Timer.periodic(_liveTrackingPollInterval, (_) {
        if (mounted && !_isRefreshing) _refreshData();
      });
      _autoRefreshTimer = Timer.periodic(_routeRefreshInterval, (_) {
        if (mounted && !_isRefreshing) _refreshData(forceRouteRefresh: true);
      });
    });
  }

  Future<void> _fetchTrackingData() async {
    final token = _storageService.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Session expired. Please login again.');
    }

    final response = await _authService.getBookingTracking(
      token: token,
      bookingId: widget.booking.bookingId,
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
          final newPos = LatLng(driverLoc.lat, driverLoc.lng);

          // ── STALE-POLL GUARD ──
          // Backend hasn't updated driver_lat since last poll — skip
          // processing to prevent breadcrumb noise and marker flicker.
          if (previousVehiclePosition != null &&
              _haversineMeters(previousVehiclePosition, newPos) < 2) {
            _lastRefreshedAt = DateTime.now();
            return;
          }

          _currentVehiclePosition = newPos;
          _currentLatLng = newPos;
          _driverStatus = newData.driverLocation.driverStatus;

          // ── Locally compute the smoothed driver speed ──
          _updateSpeedEstimate(newPos);

          // ── Collect GPS breadcrumb (actual path driven) ──
          // Pipeline: filter → validate → buffer → snap → commit
          // CITY: strict snapping, never raw GPS, higher thresholds
          // HIGHWAY: relaxed snapping, allow raw GPS, lower thresholds
          final now = DateTime.now();
          final secSinceLast = _lastBreadcrumbTime != null
              ? now.difference(_lastBreadcrumbTime!).inSeconds
              : 999;
          if (_driverBreadcrumbs.isEmpty) {
            // Seed with pickup + current position (always snapped)
            if (_pickupLatLng != null) {
              _driverBreadcrumbs.add(_pickupLatLng!);
            }
            _driverBreadcrumbs.add(_snapToRoute(newPos));
            _lastBreadcrumbTime = now;
            _pointBuffer.clear();
          } else if (_driverStatus == DriverStatus.idle) {
            // ── IDLE: driver stopped (toll/traffic) — skip breadcrumb ──
            // Prevents GPS drift noise from advancing the green line while parked.
            _pointBuffer.clear();
          } else {
            final lastPos = _driverBreadcrumbs.last;
            final meters = _haversineMeters(lastPos, newPos);

            // ── STEP 1: Filter — skip if not real movement ──
            if (meters < _breadcrumbMinDistance) {
              // Below noise floor — skip entirely
            }
            // ── STEP 2: Validate — reject impossible movements ──
            else {
              // Speed gate: 56 m/s ≈ 200 km/h, matches the backend cap.
              // Was 28 m/s (~100 km/h) which falsely flagged cars/buses
              // doing 130-150 km/h on expressways as spikes.
              final isSpeedSpike = secSinceLast > 0 && secSinceLast <= 60 && meters / secSinceLast > 56;
              final isAbsoluteSpike = meters > 500 && secSinceLast < 5;

              // Direction jitter: reject sharp reversals (>120°) on short hops
              bool isJitter = false;
              if (_driverBreadcrumbs.length >= 2 && meters < 200) {
                final prev = _driverBreadcrumbs[_driverBreadcrumbs.length - 2];
                final curr = _driverBreadcrumbs.last;
                final anglePrev = _getBearing(prev, curr);
                final angleNext = _getBearing(curr, newPos);
                var diff = (angleNext - anglePrev).abs();
                if (diff > 180) diff = 360 - diff;
                // CITY: reject >100° reversals (tighter), HIGHWAY: >140° (more lenient for curves)
                const jitterThreshold = 100.0; // city-mode strictness everywhere — highways/villages had looser 140° which let GPS noise through
                if (diff > jitterThreshold) isJitter = true;
              }

              // Backward movement rejection: ignore backward moves <30m
              bool isBackward = false;
              if (_driverBreadcrumbs.length >= 2 && meters < 30) {
                final prev = _driverBreadcrumbs[_driverBreadcrumbs.length - 2];
                final prevToCurr = _getBearing(prev, _driverBreadcrumbs.last);
                final currToNew = _getBearing(_driverBreadcrumbs.last, newPos);
                var diff = (currToNew - prevToCurr).abs();
                if (diff > 180) diff = 360 - diff;
                if (diff > 150) isBackward = true; // going backwards
              }

              // Multi-point cluster suppression: check last 3 points, not just last 1
              bool isZigZag = false;
              if (_driverBreadcrumbs.length >= 3 && meters < 50) {
                // Check if returning to 2-points-ago position
                final pt2 = _driverBreadcrumbs[_driverBreadcrumbs.length - 2];
                final pt3 = _driverBreadcrumbs[_driverBreadcrumbs.length - 3];
                final distBackTo2 = _haversineMeters(newPos, pt2);
                final distBackTo3 = _haversineMeters(newPos, pt3);
                if (distBackTo2 < 15 || distBackTo3 < 15) isZigZag = true;
              }

              // Freeze near pickup: first 50m from pickup, GPS is unstable
              bool isTooCloseToPickup = false;
              if (_pickupLatLng != null && _driverBreadcrumbs.length <= 3) {
                final distFromPickup = _haversineMeters(newPos, _pickupLatLng!);
                if (distFromPickup < 50) isTooCloseToPickup = true;
              }

              // ── LARGE-DISTANCE GUARD ──
              // If this point is far from the last committed breadcrumb
              // (e.g. >120m city / >250m highway), do NOT trust it on its
              // own. Force it through the buffer so the next point can
              // confirm the direction. A single far point with no
              // confirmation = either GPS spike or driver teleport.
              final double largeJumpThreshold = _currentMode == 0 ? 120.0 : (_currentMode == 1 ? 200.0 : 350.0);
              final bool isLargeJump = meters > largeJumpThreshold;

              if (isSpeedSpike || isAbsoluteSpike || isJitter || isZigZag || isBackward) {
                debugPrint('🚫 GPS filter: ${meters.toStringAsFixed(0)}m in ${secSinceLast}s '
                    'spike=$isSpeedSpike jitter=$isJitter zigzag=$isZigZag backward=$isBackward');
                _pointBuffer.clear(); // bad point invalidates buffer
              } else if (isLargeJump && _pointBuffer.isEmpty) {
                // First sighting of a large jump — buffer it but don't
                // commit. The next point must confirm the direction.
                debugPrint('⏳ Large jump (${meters.toStringAsFixed(0)}m) '
                    '— buffering, waiting for confirmation');
                _pointBuffer.add(newPos);
              } else if (isTooCloseToPickup) {
                // Don't draw breadcrumbs yet — GPS still settling
              } else {
                // ── STEP 3: Buffer — delay commit until 3 consistent points ──
                _pointBuffer.add(newPos);

                // Wait for at least [_minBufferCommitPoints] (3) buffered
                // points before committing anything. Two points alone weren't
                // enough to filter the small "square loop" jitter we saw in
                // bookings 547/548 — three is the sweet spot.
                if (_pointBuffer.length >= _minBufferCommitPoints) {
                  // Check buffer consistency: all points should flow in same direction
                  bool bufferConsistent = true;
                  for (int i = 1; i < _pointBuffer.length; i++) {
                    final d = _haversineMeters(_pointBuffer[i - 1], _pointBuffer[i]);
                    if (d < 5) { bufferConsistent = false; break; } // clustered
                  }
                  if (_pointBuffer.length >= 3) {
                    final b1 = _getBearing(_pointBuffer[0], _pointBuffer[1]);
                    final b2 = _getBearing(_pointBuffer[1], _pointBuffer[2]);
                    var angleDiff = (b2 - b1).abs();
                    if (angleDiff > 180) angleDiff = 360 - angleDiff;
                    if (angleDiff > 90) bufferConsistent = false;
                  }

                  if (bufferConsistent) {
                    // ── STEP 4: Snap — mode-dependent strategy ──
                    for (final bufferedPos in _pointBuffer) {
                      final snapped = _snapToRoute(bufferedPos);
                      final snapDist = _haversineMeters(bufferedPos, snapped);

                      // ── ALL MODES: city-mode rule everywhere ──
                      // Only add snapped points. NEVER add raw GPS regardless of
                      // mode (highway/suburban/village). Raw GPS is what causes
                      // zigzag lines, double lines, and cuts through buildings
                      // outside of cities. Snap failure → hold last good position.
                      if (snapDist <= _snapThreshold) {
                        _driverBreadcrumbs.add(snapped);
                      }
                      // else: snap failed → hold position, don't add raw
                    }
                    _lastBreadcrumbTime = now;
                    _pointBuffer.clear();
                  } else {
                    // Buffer inconsistent — keep only latest point, discard old noise
                    _pointBuffer = [_pointBuffer.last];
                  }
                }

                if (_driverBreadcrumbs.length > 500) {
                  _downsampleBreadcrumbs();
                }
              }
            }
          }
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
          _currentSegmentIndex = 0;
          // Historical reroute snapshots belong to the previous journey.
          // New pickup/drop invalidates them.
          _preservedGreenPath.clear();
          // Same for the fraction watermark — new route starts at 0.
          _maxDriverFractionReached = 0.0;
          _driverBreadcrumbs = [];
          _lastBreadcrumbTime = null;
          _pointBuffer.clear();
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
          _approachPolyline = [];
          _lastAcceptedSnap = null;
          _lastAcceptedRaw = null;
          _lastRenderedSnap = null;
          _snapCacheInput = null;
          _snapCacheOutput = null;
          _consecutiveDeviations = 0;
          _homeMarkerLatLng = null;
          // Clear cached stops so they regenerate
          SharedPreferences.getInstance().then((prefs) {
            prefs.remove('fixed_stops_${widget.booking.bookingId}');
            prefs.remove('stop_index_${widget.booking.bookingId}');
            prefs.remove('passed_stop_times_${widget.booking.bookingId}');
          });

          await _setupMarkersAndPolylines();
        } else {
          // Silent update — only move vehicle marker, keep existing polylines
          // Use _lastVehicleMarkerLatLng as 'from' — it's the actual rendered
          // position (may be mid-animation, not the previous poll target).
          final animateFrom = _lastVehicleMarkerLatLng ?? previousVehiclePosition;
          if (animateFrom != null && _currentLatLng != null) {
            _animateVehicleMarker(animateFrom, _currentLatLng!);
          } else {
            _buildMarkers();
            _refreshCompletedPolylineFromTimeline();
          }

          // Update driver location timestamp for route start recalculation
          if (driverLoc.updatedAt != null && driverLoc.updatedAt!.isNotEmpty) {
            try {
              _routeStartTime = DateTime.parse(driverLoc.updatedAt!);
            } catch (_) {}
          }

          // ── REROUTE DETECTION ──
          if (_currentLatLng != null) {
            final polylinePoints = _polylines
                .where((p) => p.polylineId.value != 'completed' && p.polylineId.value != 'approach')
                .expand((p) => p.points)
                .toList();
            if (polylinePoints.isNotEmpty) {
              final deviation = _minDistanceToPolyline(_currentLatLng!, polylinePoints);
              final bool tooSlowToReroute = _estimatedSpeedKmh < 5;
              if (deviation > _rerouteThreshold && !tooSlowToReroute) {
                _consecutiveDeviations++;
                final shouldReroute = (deviation > _rerouteThreshold * 1.5 ||
                    _consecutiveDeviations >= 2) &&
                    _shouldRefreshRoute(forceRefresh: forceRouteRefresh);
                if (shouldReroute) {
                  _consecutiveDeviations = 0;
                  await _rerouteFromDriverPosition();
                }
              } else {
                _consecutiveDeviations = 0;
              }
            }
          }

          // Check if driver reached the next stop (sequential progression)
          if (_currentLatLng != null) _updateProgress(_currentLatLng!);
        }
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
    if (_trackingData == null) return;
    _markerAnimationTimer?.cancel();

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

    // Resolve HOME MARKER (admin pickup if set, else driver pickup)
    final adminPickup = _trackingData?.adminPickup;
    if (adminPickup != null && adminPickup.lat != 0 && adminPickup.lng != 0) {
      _homeMarkerLatLng = LatLng(adminPickup.lat, adminPickup.lng);
    } else {
      _homeMarkerLatLng = _pickupLatLng;
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

    // APPROACH POLYLINE: admin pickup → driver start
    if (adminPickup != null && _currentLatLng != null && _approachPolyline.isEmpty) {
      LatLng? adminLatLng;
      if (adminPickup.lat != 0 && adminPickup.lng != 0) {
        final candidate = LatLng(adminPickup.lat, adminPickup.lng);
        if (_haversineMeters(candidate, _currentLatLng!) > 20) adminLatLng = candidate;
      }
      if (adminLatLng == null && adminPickup.name.isNotEmpty) {
        final pickupName = _trackingData?.pickup.name ?? '';
        if (adminPickup.name.trim().toLowerCase() != pickupName.trim().toLowerCase()) {
          try {
            final geocoded = await GoogleMapsService.geocodeAddress(adminPickup.name);
            if (geocoded != null && _haversineMeters(geocoded, _currentLatLng!) > 20) {
              adminLatLng = geocoded;
            }
          } catch (e) { debugPrint('⚠️ Admin pickup geocoding failed: $e'); }
        }
      }
      if (adminLatLng != null) {
        try {
          final approach = await GoogleMapsService.getDirectionsHighRes(
            origin: adminLatLng,
            destination: _currentLatLng!,
          );
          if (approach.length >= 2) _approachPolyline = approach;
        } catch (e) { debugPrint('⚠️ Approach polyline fetch failed: $e'); }
      }
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

      // Always route from pickup so _fullPolyline covers pickup→destination.
      // The green/blue split uses _currentSegmentIndex which is initialized
      // from the driver's actual position — so geometry is correct even
      // though we fetch from pickup origin.
      final routeOrigin = _pickupLatLng!;

      debugPrint(
        '🗺️ Route params: origin=$routeOrigin (pickup), '
        'dest=$_destinationLatLng, remainingWaypoints=${remainingWaypoints.length}, '
        'totalWaypoints=${allWaypoints.length}',
      );

      final routeData = await GoogleMapsService.getRouteWithStops(
        origin: routeOrigin,
        destination: _destinationLatLng!,
        driverPosition: _currentLatLng,
        routeWaypoints: remainingWaypoints,
      );

      if (routeData.isNotEmpty) {
        _routeStops = routeData['stops'] as List<Map<String, dynamic>>? ?? [];
        _totalRouteDurationSeconds =
            routeData['total_duration_seconds'] as int? ?? 0;
        _fullPolyline = routeData['polyline_points'] as List<LatLng>? ?? [];
        _cumulativeDistances =
            (routeData['cumulative_distances'] as List?)?.cast<double>() ?? [];

        final remainingSeconds =
            routeData['remaining_duration_seconds'] as int? ?? 0;
        _remainingDurationSeconds = remainingSeconds; // actual time left from driver's current position, not total trip duration

        // Route start time = driver's last update
        if (driverLoc.updatedAt != null && driverLoc.updatedAt!.isNotEmpty) {
          try {
            _routeStartTime = DateTime.parse(driverLoc.updatedAt!);
          } catch (_) {}
        }

        // ── IN TRANSIT or ARRIVED ──
        final bool driverAtDestination = _currentLatLng != null &&
            _destinationLatLng != null &&
            _haversineMeters(_currentLatLng!, _destinationLatLng!) < 30;

        if (driverAtDestination && _fullPolyline.length >= 2) {
          polylines.add(Polyline(
            polylineId: const PolylineId('completed'),
            points: List<LatLng>.from(_fullPolyline),
            color: const Color(0xFF34A853),
            width: 5,
          ));
          _estimatedDuration = '';
        } else if (_currentLatLng != null && _fullPolyline.length >= 2) {
          // Warm up segment index on first load
          if (_trackingData?.timeline.isNotEmpty ?? false) {
            _replayTimelineThroughPipeline();
          } else if (_currentLatLng != null) {
            _initializeSegmentIndex(_currentLatLng!);
          }

          // Seed breadcrumbs
          if (_driverBreadcrumbs.isEmpty) {
            if (_pickupLatLng != null) _driverBreadcrumbs.add(_pickupLatLng!);
            _driverBreadcrumbs.add(_snapToRoute(_currentLatLng!));
            _lastBreadcrumbTime = DateTime.now();
          }

          final snappedDriver = _snapToRoute(_currentLatLng!);
          final double gapMax = _currentMode == 0 ? 130 : (_currentMode == 1 ? 350 : 700);
          final bool gapViolation = _lastRenderedSnap != null &&
              _haversineMeters(_lastRenderedSnap!, snappedDriver) > gapMax;

          if (gapViolation) {
            polylines = Set<Polyline>.from(_polylines);
          } else {
            _lastRenderedSnap = snappedDriver;

            // ── APPROACH (green) — admin pickup → driver start ──
            // Road-following line fetched via Directions API (same as blue line).
            if (_approachPolyline.length >= 2) {
              polylines.add(Polyline(
                polylineId: const PolylineId('approach'),
                points: List<LatLng>.from(_approachPolyline),
                color: const Color(0xFF34A853),
                width: 5,
              ));
            }

            final splitAt = _currentSegmentIndex.clamp(0, _fullPolyline.length - 1);
            final greenPoints = <LatLng>[
              ..._preservedGreenPath,
              ..._fullPolyline.sublist(0, splitAt + 1),
              snappedDriver,
            ];
            if (greenPoints.length >= 2) {
              polylines.add(Polyline(
                polylineId: const PolylineId('completed'),
                points: greenPoints,
                color: const Color(0xFF34A853),
                width: 5,
              ));
            }

            final bluePoints = <LatLng>[
              snappedDriver,
              if (splitAt + 1 < _fullPolyline.length)
                ..._fullPolyline.sublist(splitAt + 1),
            ];
            if (bluePoints.length >= 2) {
              polylines.add(Polyline(
                polylineId: const PolylineId('remaining'),
                points: bluePoints,
                color: const Color(0xFF1A73E8),
                width: 5,
              ));
            }
          }
          _estimatedDuration = _formatDuration(remainingSeconds);
        } else if (_fullPolyline.length >= 2) {
          _estimatedDuration = _formatDuration(remainingSeconds);
          polylines.add(Polyline(
            polylineId: const PolylineId('full_route'),
            points: _fullPolyline,
            color: const Color(0xFF1A73E8),
            width: 5,
          ));
        }
      } else {
        debugPrint('❌ Directions API failed — keeping previous polylines');
        if (_polylines.isNotEmpty) {
          polylines = Set<Polyline>.from(_polylines);
        } else if (_currentLatLng != null && _destinationLatLng != null) {
          polylines.add(Polyline(
            polylineId: const PolylineId('remaining'),
            points: [_currentLatLng!, _destinationLatLng!],
            color: const Color(0xFF1A73E8),
            width: 5,
          ));
        }
      }
    }

    // Calculate initial camera position to show full route
    _calculateInitialCameraPosition();

    setState(() {
      _polylines = polylines;
      _isLoadingRoute = false;
      // NOTE: do NOT seed `_lastRouteRefreshAt` here. If we do, the
      // cooldown gate would block the first reroute for 15 s after
      // setup — so opening the screen mid-trip when the driver is
      // already off-route would silently delay the redraw. Let the
      // first actual reroute set the timestamp.
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

  bool _shouldRefreshRoute({bool forceRefresh = false}) {
    if (forceRefresh) return true;
    if (_lastRouteRefreshAt == null) return true;
    return DateTime.now().difference(_lastRouteRefreshAt!) >= _rerouteCooldown;
  }

  double get _snapThreshold {
    switch (_currentMode) {
      case 2: return 60;
      case 1: return 40;
      default: return 25;
    }
  }

  double get _rerouteThreshold {
    switch (_currentMode) {
      case 2: return 150;
      case 1: return 120;
      default: return _polylineRerouteThresholdMeters;
    }
  }

  double get _breadcrumbMinDistance {
    switch (_currentMode) {
      case 2: return 50;
      case 1: return 30;
      default: return 20;
    }
  }

  int get _segmentSearchWindow {
    switch (_currentMode) {
      case 2: return 50;
      case 1: return 20;
      default: return 10;
    }
  }

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
            _haversineMeters(points.last, nextPoint) >=
                _timelinePointMinDistanceMeters) {
          points.add(nextPoint);
        }
      }
    }

    if (_currentLatLng != null &&
        (points.isEmpty ||
            _haversineMeters(points.last, _currentLatLng!) >=
                _timelinePointMinDistanceMeters)) {
      points.add(_currentLatLng!);
    }

    if (points.length >= 2) {
      return points;
    }

    if (fallbackPoints.isNotEmpty) {
      return fallbackPoints;
    }

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

    final updatedPolylines = _polylines
        .where((p) =>
            p.polylineId.value != 'completed' &&
            p.polylineId.value != 'remaining')
        .toSet();

    if (_fullPolyline.length >= 5) {
      final snappedPos = _snapToRoute(_currentLatLng!);

      // ── GAP PROTECTION ──
      // Hold the segment-slice frame when the snap jumps further than the
      // protection threshold (avoids drawing a long shortcut chord). BUT
      // always advance `_lastRenderedSnap` to the new snap before bailing,
      // otherwise the comparison anchor stays frozen at the OLD position
      // and every subsequent poll re-fires the same gap check, leaving
      // the green line stuck behind the truck until the user hot-reloads.
      // Also still fire the live Directions override on the way out so
      // the green continues to grow even when the segment slice is held.
      // 700 m highway-friendly threshold — covers a 14 s poll drop at
      // sustained 180 km/h plus headroom. Matches the 200 km/h backend cap
      // so cars/buses on expressways aren't held by the gap filter.
      final double gapMax = _currentMode == 0 ? 130 : (_currentMode == 1 ? 350 : 700);
      final bool gapHold = _lastRenderedSnap != null &&
          _haversineMeters(_lastRenderedSnap!, snappedPos) > gapMax;
      _lastRenderedSnap = snappedPos;
      if (gapHold) {
        debugPrint('🚫 Gap protection (live): snap jumped >${gapMax.toStringAsFixed(0)}m, '
            'holding frame — segment slice will resume next poll');
        if (!mounted) return;
        setState(() => _polylines = updatedPolylines);
        return;
      }

      final splitIndex = _currentSegmentIndex.clamp(0, _fullPolyline.length - 1);

      // Green: historical reroute snapshots + pickup → driver (on-road).
      // See `_preservedGreenPath` doc for why we prepend the snapshot
      // list — it keeps the pre-reroute travelled line visible after a
      // route change instead of collapsing to a stub at the truck.
      final greenPoints = [
        ..._preservedGreenPath,
        ..._fullPolyline.sublist(0, splitIndex + 1),
        snappedPos,
      ];
      if (greenPoints.length >= 2) {
        updatedPolylines.add(
          Polyline(
            polylineId: const PolylineId('completed'),
            points: greenPoints,
            color: const Color(0xFF34A853),
            width: 5,
          ),
        );
      }

      // Blue: driver → destination (on-road)
      final List<LatLng> bluePoints;
      if (splitIndex >= _fullPolyline.length - 2) {
        bluePoints = [snappedPos, _fullPolyline.last];
      } else {
        bluePoints = [snappedPos, ..._fullPolyline.sublist(splitIndex + 1)];
      }
      if (bluePoints.length >= 2) {
        updatedPolylines.add(
          Polyline(
            polylineId: const PolylineId('remaining'),
            points: bluePoints,
            color: const Color(0xFF1A73E8),
            width: 5,
          ),
        );
      }
    } else if (_driverBreadcrumbs.length >= 2) {
      updatedPolylines.add(
        Polyline(
          polylineId: const PolylineId('completed'),
          points: List<LatLng>.from(_driverBreadcrumbs),
          color: const Color(0xFF34A853),
          width: 5,
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _polylines = updatedPolylines;
    });

    // NOTE: The live `_maybeRefreshLiveGreenFromDirections` override used
    // to fire here. After the gap-protection latching fix, the segment
    // slice path advances reliably on every poll, so the override is no
    // longer needed AND it was causing the green line to visibly flicker
    // because the segment-slice and the override produced slightly
    // different geometries that swapped on each poll. Removed.
  }

  // Cubic ease-in-out for smooth acceleration/deceleration
  double _easeInOutCubic(double t) {
    return t < 0.5 ? 4 * t * t * t : 1 - ((-2 * t + 2) * (-2 * t + 2) * (-2 * t + 2)) / 2;
  }

  /// Animate camera to follow vehicle with bearing rotation and tilt.
  /// Only called when `_isFollowingVehicle` is true (user hasn't dragged
  /// the map). Pans + zooms + tilts in one animation step.
  void _animateCameraToVehicle() {
    if (_currentLatLng == null) return;

    final controller =
        _isMapExpanded ? _expandedMapController : _smallMapController;
    if (controller == null) return;

    try {
      _isProgrammaticCameraMove = true;
      controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _currentLatLng!,
            zoom: _followZoom,
            bearing: _lastVehicleBearing,
            tilt: _followTilt,
          ),
        ),
      ).then((_) {
        _isProgrammaticCameraMove = false;
      });
    } catch (e) {
      _isProgrammaticCameraMove = false;
      debugPrint('Error animating camera to vehicle: $e');
    }
  }

  /// Re-arm the auto-resume timer every time the user touches the map.
  /// After `_followAutoResumeDelay` of no further interaction, follow mode
  /// turns back on and the camera snaps to the truck on the next frame.
  void _scheduleFollowAutoResume() {
    _followResumeTimer?.cancel();
    _followResumeTimer = Timer(_followAutoResumeDelay, () {
      if (!mounted) return;
      if (_isFollowingVehicle) return;
      setState(() => _isFollowingVehicle = true);
      _animateCameraToVehicle();
    });
  }

  /// Edge-detection safety net. Even if the user has follow mode off, if
  /// the truck is about to leave the visible map area, force a one-shot
  /// recenter so it never drifts off-screen. The follow flag is NOT
  /// flipped on — only the lat/lng moves, the user's zoom/tilt/bearing
  /// are preserved.
  Future<void> _ensureVehicleVisible() async {
    if (_currentLatLng == null) return;
    if (_isFollowingVehicle) return; // already following — nothing to do

    final controller =
        _isMapExpanded ? _expandedMapController : _smallMapController;
    if (controller == null) return;

    try {
      final region = await controller.getVisibleRegion();
      final lat = _currentLatLng!.latitude;
      final lng = _currentLatLng!.longitude;
      final inside = lat >= region.southwest.latitude &&
          lat <= region.northeast.latitude &&
          lng >= region.southwest.longitude &&
          lng <= region.northeast.longitude;
      if (inside) return;

      _isProgrammaticCameraMove = true;
      await controller.animateCamera(
        CameraUpdate.newLatLng(_currentLatLng!),
      );
      _isProgrammaticCameraMove = false;
    } catch (e) {
      _isProgrammaticCameraMove = false;
      debugPrint('ensureVehicleVisible failed: $e');
    }
  }

  void _animateVehicleMarker(LatLng from, LatLng to) {
    _markerAnimationTimer?.cancel();
    _lastVehicleMarkerLatLng = from;

    if (_haversineMeters(from, to) < 2) {
      _buildMarkers();
      if (mounted) setState(() {});
      return;
    }

    final startBearing = _lastVehicleBearing;
    final endBearing = _getBearing(from, to);

    int step = 0;
    _markerAnimationTimer = Timer.periodic(_markerAnimationStepDuration, (timer) {
      step++;
      final linearT = step / _markerAnimationSteps;
      final easedT = _easeInOutCubic(linearT);

      final interpolated = LatLng(
        from.latitude + (to.latitude - from.latitude) * easedT,
        from.longitude + (to.longitude - from.longitude) * easedT,
      );
      _currentLatLng = _snapToRoute(interpolated, updateSegmentIndex: false);

      double bearingDiff = endBearing - startBearing;
      if (bearingDiff > 180) bearingDiff -= 360;
      if (bearingDiff < -180) bearingDiff += 360;
      _lastVehicleBearing = (startBearing + bearingDiff * easedT) % 360;

      _buildMarkers();
      _lastVehicleMarkerLatLng = _currentLatLng;
      if (mounted) setState(() {});

      if (step >= _markerAnimationSteps) {
        timer.cancel();
        _currentLatLng = _snapToRoute(to);
        _lastVehicleBearing = endBearing;
        _buildMarkers();
        _lastVehicleMarkerLatLng = _currentLatLng;
        _refreshCompletedPolylineFromTimeline();

        // Follow mode: animate camera ONCE after marker animation completes.
        // NOT on every step — that overwhelms tile loader and causes blank
        // map. If user disabled follow mode but the truck is about to leave
        // the viewport, fall through to the edge-detection nudge so the
        // marker can never silently drift off-screen.
        if (_isFollowingVehicle) {
          _animateCameraToVehicle();
        } else {
          _ensureVehicleVisible();
        }
      }
    });
  }

  double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * R * asin(sqrt(h));
  }

  double _minDistanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return double.infinity;
    double minDist = double.infinity;
    for (final p in polyline) {
      final d = _haversineMeters(point, p);
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

  /// Downsample breadcrumbs to prevent memory/render issues on long trips.
  void _downsampleBreadcrumbs() {
    final total = _driverBreadcrumbs.length;
    final halfIdx = total ~/ 2;
    final older = <LatLng>[];
    for (int i = 0; i < halfIdx; i++) {
      if (i % 3 == 0) {
        older.add(_driverBreadcrumbs[i]);
      } else if (i >= 1 && i < halfIdx - 1) {
        final prev = _driverBreadcrumbs[i - 1];
        final curr = _driverBreadcrumbs[i];
        final next = _driverBreadcrumbs[i + 1];
        final b1 = _getBearing(prev, curr);
        final b2 = _getBearing(curr, next);
        var diff = (b2 - b1).abs();
        if (diff > 180) diff = 360 - diff;
        if (diff > 25) older.add(curr);
      }
    }
    final recent = _driverBreadcrumbs.sublist(halfIdx);
    _driverBreadcrumbs = [...older, ...recent];
  }

  /// Project point P onto line segment A→B.
  LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.latitude - a.latitude;
    final dy = b.longitude - a.longitude;
    if (dx == 0 && dy == 0) return a;
    var t = ((p.latitude - a.latitude) * dx + (p.longitude - a.longitude) * dy) /
        (dx * dx + dy * dy);
    t = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + t * dx, a.longitude + t * dy);
  }

  /// Segment-based route snapping with 7-gate pipeline.
  LatLng _snapToRoute(LatLng raw, {bool updateSegmentIndex = true}) {
    if (_fullPolyline.length < 2) return raw;

    // ── IDEMPOTENCY CACHE ──
    if (_snapCacheInput != null && _snapCacheOutput != null) {
      if ((_snapCacheInput!.latitude - raw.latitude).abs() < 1e-7 &&
          (_snapCacheInput!.longitude - raw.longitude).abs() < 1e-7) {
        return _snapCacheOutput!;
      }
    }

    final threshold = _snapThreshold;
    final windowSize = _segmentSearchWindow;
    final searchStart = _currentSegmentIndex;
    final searchEnd = (_currentSegmentIndex + windowSize).clamp(0, _fullPolyline.length - 1);

    double minDist = double.infinity;
    LatLng snapped = raw;
    int bestIndex = _currentSegmentIndex;

    for (int i = searchStart; i < searchEnd; i++) {
      final projected = _projectOntoSegment(raw, _fullPolyline[i], _fullPolyline[i + 1]);
      final dist = _haversineMeters(raw, projected);
      if (dist < minDist) {
        minDist = dist;
        snapped = projected;
        bestIndex = i;
      }
    }

    if (minDist > threshold) {
      final wideEnd = (_currentSegmentIndex + windowSize * 3).clamp(0, _fullPolyline.length - 1);
      for (int i = searchEnd; i < wideEnd; i++) {
        final projected = _projectOntoSegment(raw, _fullPolyline[i], _fullPolyline[i + 1]);
        final dist = _haversineMeters(raw, projected);
        if (dist < minDist) {
          minDist = dist;
          snapped = projected;
          bestIndex = i;
        }
      }
    }

    // ── GATE 0: Stop filter ──
    // Only freeze for genuine idle (fresh GPS, speed ≈ 0).
    if (_driverStatus == DriverStatus.idle) {
      final hold = _lastAcceptedSnap
          ?? (_driverBreadcrumbs.isNotEmpty ? _driverBreadcrumbs.last : raw);
      _snapCacheInput = raw;
      _snapCacheOutput = hold;
      return hold;
    }

    // ── GATE 1: Snap quality ──
    if (minDist > threshold) {
      final hold = _lastAcceptedSnap
          ?? (_driverBreadcrumbs.isNotEmpty ? _driverBreadcrumbs.last : raw);
      _snapCacheInput = raw;
      _snapCacheOutput = hold;
      return hold;
    }

    // ── GATE 2: Bearing/direction agreement ──
    if (_lastAcceptedSnap != null) {
      final rawHop = _haversineMeters(_lastAcceptedSnap!, raw);
      if (rawHop > 15) {
        final rawBearing = _getBearing(_lastAcceptedSnap!, raw);
        final snapBearing = _getBearing(_lastAcceptedSnap!, snapped);
        var diff = (rawBearing - snapBearing).abs();
        if (diff > 180) diff = 360 - diff;
        final double maxBearingDiff = _currentMode == 0
            ? 75
            : (_currentMode == 1 ? 90 : 110);
        if (diff > maxBearingDiff) {
          _snapCacheInput = raw;
          _snapCacheOutput = _lastAcceptedSnap!;
          return _lastAcceptedSnap!;
        }
      }
    }

    // ── GATE 3: Parallel-road filter ──
    if (_lastAcceptedSnap != null && _lastAcceptedRaw != null) {
      final rawHop = _haversineMeters(_lastAcceptedRaw!, raw);
      final snapHop = _haversineMeters(_lastAcceptedSnap!, snapped);
      if (rawHop < 30 && snapHop > 80) {
        _snapCacheInput = raw;
        _snapCacheOutput = _lastAcceptedSnap!;
        return _lastAcceptedSnap!;
      }
    }

    // ── ALL GATES PASSED — commit ──
    // Animation steps pass updateSegmentIndex: false so straight-line
    // interpolation on curves can't corrupt _currentSegmentIndex mid-animation
    // and cause zigzag/double lines on highways and villages.
    if (updateSegmentIndex) {
      _currentSegmentIndex = bestIndex;
      _lastAcceptedSnap = snapped;
      _lastAcceptedRaw = raw;
    }
    _snapCacheInput = raw;
    _snapCacheOutput = snapped;
    return snapped;
  }

  void _initializeSegmentIndex(LatLng driverPos) {
    if (_fullPolyline.length < 2) return;
    double minDist = double.infinity;
    int bestIdx = 0;
    for (int i = 0; i < _fullPolyline.length - 1; i++) {
      final projected = _projectOntoSegment(driverPos, _fullPolyline[i], _fullPolyline[i + 1]);
      final d = _haversineMeters(driverPos, projected);
      if (d < minDist) { minDist = d; bestIdx = i; }
    }
    _currentSegmentIndex = bestIdx;
  }

  void _replayTimelineThroughPipeline() {
    if (_trackingData == null || _fullPolyline.length < 2 || _currentLatLng == null) return;
    _initializeSegmentIndex(_currentLatLng!);
    LatLng snappedCurrent = _currentLatLng!;
    if (_currentSegmentIndex < _fullPolyline.length - 1) {
      snappedCurrent = _projectOntoSegment(
        _currentLatLng!,
        _fullPolyline[_currentSegmentIndex],
        _fullPolyline[_currentSegmentIndex + 1],
      );
    }
    final timelinePoints = <LatLng>[];
    for (final t in _trackingData!.timeline) {
      final lat = t.lat; final lng = t.lng;
      if (lat != null && lng != null && lat != 0 && lng != 0) {
        timelinePoints.add(LatLng(lat, lng));
      }
    }
    _lastAcceptedSnap = snappedCurrent;
    _lastAcceptedRaw = timelinePoints.isNotEmpty ? timelinePoints.last : _currentLatLng;
    _snapCacheInput = null;
    _snapCacheOutput = null;
  }

  Future<void> _rerouteFromDriverPosition() async {
    if (_currentLatLng == null || _destinationLatLng == null) return;
    final remainingWaypoints = (_trackingData?.routeWaypoints ?? [])
        .where((wp) => wp.lat != 0 && wp.lng != 0 && !wp.isCompleted)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final wpLatLngs = remainingWaypoints.map((wp) => LatLng(wp.lat, wp.lng)).toList();
    final routeData = await GoogleMapsService.getRouteWithStops(
      origin: _currentLatLng!,
      destination: _destinationLatLng!,
      routeWaypoints: wpLatLngs,
    );
    if (routeData.isEmpty) return;

    if (_fullPolyline.length >= 2) {
      final oldSplit = _currentSegmentIndex.clamp(0, _fullPolyline.length - 1);
      if (oldSplit > 0) _preservedGreenPath.addAll(_fullPolyline.sublist(0, oldSplit + 1));
      if (_currentLatLng != null) _preservedGreenPath.add(_currentLatLng!);
    }

    _fullPolyline = routeData['polyline_points'] as List<LatLng>? ?? [];
    _cumulativeDistances = (routeData['cumulative_distances'] as List?)?.cast<double>() ?? [];
    _totalRouteDurationSeconds = routeData['total_duration_seconds'] as int? ?? 0;
    _remainingDurationSeconds = _totalRouteDurationSeconds;
    _currentSegmentIndex = 0;
    _lastAcceptedSnap = null;
    _lastAcceptedRaw = null;
    _lastRenderedSnap = null;
    _snapCacheInput = null;
    _snapCacheOutput = null;
    if (_currentLatLng != null && _fullPolyline.length >= 2) {
      _initializeSegmentIndex(_currentLatLng!);
    }
    _estimatedDuration = _formatDuration(_totalRouteDurationSeconds);

    final updatedPolylines = _polylines
        .where((p) => p.polylineId.value != 'remaining')
        .toSet();
    if (_fullPolyline.length >= 2) {
      updatedPolylines.add(Polyline(
        polylineId: const PolylineId('remaining'),
        points: List<LatLng>.from(_fullPolyline),
        color: const Color(0xFF1A73E8),
        width: 5,
      ));
    }
    if (mounted) setState(() { _polylines = updatedPolylines; _lastRouteRefreshAt = DateTime.now(); });

    // Regenerate timeline stops for the new route so the location list
    // reflects the actual path the driver is now taking.
    await _regenerateFixedStopsFromPolyline(_fullPolyline, _totalRouteDurationSeconds);
  }

  int _getClosestPolylineIndex(LatLng current) {
    if (_fullPolyline.isEmpty) return 0;
    final searchEnd = (_currentSegmentIndex + 30).clamp(0, _fullPolyline.length);
    double minDist = double.infinity;
    int index = _currentSegmentIndex;
    for (int i = _currentSegmentIndex; i < searchEnd; i++) {
      final d = _haversineMeters(_fullPolyline[i], current);
      if (d < minDist) { minDist = d; index = i; }
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
          position: _homeMarkerLatLng ?? _pickupLatLng!,
          icon:
              _smallPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Pickup', snippet: pickup.name),
        ),
      );

      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: _homeMarkerLatLng ?? _pickupLatLng!,
          icon:
              _expandedPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Pickup', snippet: pickup.name),
        ),
      );
    }

    /// -------- Vehicle (only shown when this is the active drop) --------
    if (_currentLatLng != null && _isActiveDrop) {
      final snappedPos = _snapToRoute(_currentLatLng!);
      final rotationAngle = _fullPolyline.isNotEmpty
          ? _getRouteBearing(snappedPos)
          : 0.0;

      smallMarkers.add(
        Marker(
          markerId: const MarkerId('vehicle'),
          position: snappedPos,
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
          position: snappedPos,
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
          onCameraMoveStarted: () {
            // Only disable follow mode for USER gestures (drag/zoom/rotate),
            // not for our programmatic animateCamera calls.
            if (_isFollowingVehicle && !_isProgrammaticCameraMove) {
              setState(() => _isFollowingVehicle = false);
            }
            _scheduleFollowAutoResume();
          },
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
                'Order #${widget.booking.bookingId}',
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
          onCameraMoveStarted: () {
            // Only disable follow mode for USER gestures (drag/zoom/rotate),
            // not for our programmatic animateCamera calls.
            if (_isFollowingVehicle && !_isProgrammaticCameraMove) {
              setState(() => _isFollowingVehicle = false);
            }
            _scheduleFollowAutoResume();
          },
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
        color: const Color(0xFF1A73E8),
        width: 5,
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

    // Use admin-set pickup name (e.g. Kanyakumari) when available,
    // otherwise fall back to the driver's actual pickup name.
    final adminPickupName = _trackingData?.adminPickup?.name ?? '';
    final displayPickupName = adminPickupName.isNotEmpty ? adminPickupName : pickup.name;

    final hasCurrentLocation = driverLoc.lat != 0 && driverLoc.lng != 0;

    List<Widget> timelineItems = [];

    /// -------- Pickup (always green, always first) --------
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
    final bool willInsertVehicleWidget =
        hasCurrentLocation && !driverAtFixedStop && !driverNearPickup;

    /// -------- Pickup (always green, always first) --------
    // Use journey start time for pickup, not driver's current updatedAt
    final pickupTime = (_trackingData!.inProgressAt != null && _trackingData!.inProgressAt!.isNotEmpty)
        ? _formatDateTime(_trackingData!.inProgressAt)
        : _formatDateTime(driverLoc.updatedAt);
    // Pickup's connector is green only when the next visible item is
    // also passed. Without this, the green connector below pickup
    // always reached down into the next stop's icon.
    final bool pickupNextIsPassed = willInsertVehicleWidget
        ? true
        : (_fixedStops.isNotEmpty && _currentStopIndex >= 0);
    timelineItems.add(
      _buildTimelineItem(
        width,
        height,
        Icons.location_on,
        Colors.green,
        'Pickup started from',
        displayPickupName.isNotEmpty ? displayPickupName : 'N/A',
        pickupTime,
        isFirst: true,
        isPassed: true,
        isNextPassed: pickupNextIsPassed,
      ),
    );

    Widget? vehicleWidget;
    if (willInsertVehicleWidget) {
      // Vehicle's connector goes to the next unpassed stop → grey.
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
        isNextPassed: false,
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
      // Pre-compute destination DateTime so every intermediate stop can be
      // clamped to never show a time later than the destination ETA.
      final DateTime? destDt = _computeDateTimeForFraction(1.0);
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

        // Calculate time: locked for passed stops, dynamic for future stops.
        // destDt is pre-computed before this loop so every intermediate stop
        // can be clamped to never exceed the destination ETA — regardless of
        // which branch (passed/future) _computeDateTimeForFraction takes.
        final stopFraction = _getStopFraction(i);
        String time;
        if (isDriverHere) {
          time = _formatDateTime(driverLoc.updatedAt);
        } else if (isPassed) {
          // Use locked time if available, otherwise use backend passed_at, then compute.
          if (_passedStopTimes.containsKey(i)) {
            time = _passedStopTimes[i]!;
          } else {
            // Prefer backend-provided passed_at ISO timestamp — exact, no math needed.
            final passedAt = stop['passed_at'] as String?;
            if (passedAt != null && passedAt.isNotEmpty) {
              time = _formatDateTime(passedAt);
            } else {
              final dt = _computeDateTimeForFraction(stopFraction);
              final clamped = (dt != null && destDt != null && dt.isAfter(destDt))
                  ? destDt
                  : dt;
              time = clamped != null ? _formatDateTimeObj(clamped) : '-';
            }
            if (time != '-') {
              _passedStopTimes[i] = time;
              newTimesLocked = true;
            }
          }
        } else {
          // Future (grey) stop — clamp to destination ETA
          final dt = _computeDateTimeForFraction(stopFraction);
          final clamped = (dt != null && destDt != null && dt.isAfter(destDt))
              ? destDt
              : dt;
          time = clamped != null ? _formatDateTimeObj(clamped) : '-';
        }

        // Fractions for sub-stop generation on tap
        final nextFraction = i < _fixedStops.length - 1
            ? _getStopFraction(i + 1)
            : 1.0;
        final segmentIndex = i + 1;

        // Connector below this stop is green only when the next
        // visible item is also passed. See customer file for full
        // rationale.
        final bool nextIsPassed = (i < _fixedStops.length - 1)
            ? (i + 1) <= _currentStopIndex
            : _currentStopIndex >= _fixedStops.length;

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
              isNextPassed: nextIsPassed,
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

    // Calculate stop count — extended for multi-day journeys (5–10 days).
    // Short trips: 3–4 stops. Day trips: 1/hour up to 30. Multi-day: 1 per 8h up to 50.
    final totalHours = totalDuration / 3600.0;
    int stopCount;
    if (totalHours <= 1) {
      stopCount = 3;
    } else if (totalHours <= 3) {
      stopCount = 4;
    } else if (totalHours <= 48) {
      stopCount = totalHours.round().clamp(5, 30);
    } else {
      // Multi-day: 1 stop per 8 hours, max 50 (e.g. 10-day trip → ~30 stops)
      stopCount = (totalHours / 8).round().clamp(6, 50);
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
      if (wp.name.isNotEmpty) waypointNames.add(_firstNameComponent(wp.name));
    }

    // Use server-provided auto stops if available (identical across all apps).
    // Fall back to client-side generation only when the server didn't return any.
    final serverAutoPoints = _trackingData?.autoTimelinePoints ?? [];
    final List<Map<String, dynamic>> filteredAutoStops;

    if (serverAutoPoints.isNotEmpty) {
      filteredAutoStops = serverAutoPoints
          .where((s) {
            final first = _firstNameComponent(s['name'] as String? ?? '');
            return first.isNotEmpty && !waypointNames.contains(first);
          })
          .map((s) => {
                'name': s['name'] as String,
                'lat': (s['lat'] as num).toDouble(),
                'lng': (s['lng'] as num).toDouble(),
                'is_key_stop': false,
                if (s['passed_at'] != null) 'passed_at': s['passed_at'] as String,
              })
          .toList();
    } else {
      final autoStops = await GoogleMapsService.generateSubStops(
        fullPolyline: fullPolyline,
        cumulativeDistances: cumDist,
        startFraction: 0.0,
        endFraction: 1.0,
        totalDurationSeconds: totalDuration,
        count: stopCount,
      );

      final fallbackStops = <Map<String, dynamic>>[];
      for (final stop in autoStops) {
        final name = (stop['name'] as String? ?? '').toLowerCase().trim();
        if (waypointNames.contains(name) || name == 'unknown') continue;
        final loc = stop['location'] as LatLng?;
        if (loc == null) continue;
        bool tooClose = false;
        for (final wp in waypointStops) {
          if (_haversineDistance(loc, LatLng(wp['lat'] as double, wp['lng'] as double)) < 5000) {
            tooClose = true;
            break;
          }
        }
        if (tooClose) continue;
        fallbackStops.add({
          'name': stop['name'],
          'lat': loc.latitude,
          'lng': loc.longitude,
          'is_key_stop': false,
        });
      }
      filteredAutoStops = fallbackStops;
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

    final dedupedStops = _deduplicateStops(allStops);

    if (mounted) {
      setState(() {
        _fixedStops = dedupedStops;
        _isLoadingFixedStops = false;
      });
    }
  }

  /// Regenerate fixed timeline stops directly from an already-fetched polyline.
  /// Used after a reroute so the timeline reflects the new path without a
  /// redundant API call.
  Future<void> _regenerateFixedStopsFromPolyline(
    List<LatLng> polyline,
    int totalDurationSeconds,
  ) async {
    if (polyline.length < 2) return;

    // Reset stop state
    _fixedStopsGenerated = false;
    _fixedStops = [];
    _currentStopIndex = -1;
    _passedStopTimes = {};
    _fullRoutePolyline = polyline;
    _fullRouteDurationSeconds = totalDurationSeconds;

    // Build cumulative distances
    final List<double> cumDist = [0.0];
    for (int i = 1; i < polyline.length; i++) {
      cumDist.add(cumDist.last + _haversineDistance(polyline[i - 1], polyline[i]));
    }
    _fullRouteCumulativeDistances = cumDist;

    if (mounted) setState(() => _isLoadingFixedStops = true);

    // Stop count: same formula as _fetchFullRouteAndGenerateFixedStops
    final totalHours = totalDurationSeconds / 3600.0;
    int stopCount;
    if (totalHours <= 1) {
      stopCount = 3;
    } else if (totalHours <= 3) {
      stopCount = 4;
    } else {
      stopCount = totalHours.round().clamp(5, 20);
    }

    // Include only remaining (uncompleted) waypoints
    final remainingWps = (_trackingData?.routeWaypoints ?? [])
        .where((wp) => wp.lat != 0 && wp.lng != 0 && !wp.isCompleted)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));

    final List<Map<String, dynamic>> waypointStops = [];
    final Set<String> waypointNames = {};
    for (final wp in remainingWps) {
      waypointStops.add({
        'name': wp.name.isNotEmpty ? wp.name : 'Waypoint',
        'lat': wp.lat,
        'lng': wp.lng,
        'is_key_stop': true,
      });
      if (wp.name.isNotEmpty) waypointNames.add(wp.name.toLowerCase().trim());
    }

    final autoStops = await GoogleMapsService.generateSubStops(
      fullPolyline: polyline,
      cumulativeDistances: cumDist,
      startFraction: 0.0,
      endFraction: 1.0,
      totalDurationSeconds: totalDurationSeconds,
      count: stopCount,
    );

    final filteredAutoStops = <Map<String, dynamic>>[];
    for (final stop in autoStops) {
      final name = (stop['name'] as String? ?? '').toLowerCase().trim();
      if (waypointNames.contains(name) || name == 'unknown') continue;
      final loc = stop['location'] as LatLng?;
      if (loc == null) continue;
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

    final allStops = [...waypointStops, ...filteredAutoStops];
    for (final stop in allStops) {
      final sLat = stop['lat'] as double;
      final sLng = stop['lng'] as double;
      double minD = double.infinity;
      int bestIdx = 0;
      for (int i = 0; i < polyline.length; i++) {
        final d = _haversineDistance(LatLng(sLat, sLng), polyline[i]);
        if (d < minD) { minD = d; bestIdx = i; }
      }
      stop['_sortDist'] = cumDist[bestIdx];
    }
    allStops.sort((a, b) => (a['_sortDist'] as double).compareTo(b['_sortDist'] as double));
    for (final stop in allStops) { stop.remove('_sortDist'); }

    final dedupedStops = _deduplicateStops(allStops);

    // Clear old cache and persist new stops
    final prefs = await SharedPreferences.getInstance();
    prefs.remove('fixed_stops_${widget.booking.bookingId}');
    prefs.remove('stop_index_${widget.booking.bookingId}');
    prefs.remove('passed_stop_times_${widget.booking.bookingId}');

    if (mounted) {
      setState(() {
        _fixedStops = dedupedStops;
        _isLoadingFixedStops = false;
      });
    }

    _fixedStopsGenerated = true;
    await _saveFixedStops();

    debugPrint('✅ Timeline regenerated after reroute: ${allStops.length} stops');
  }

  /// Progress detection — fraction-based, authoritative recompute.
  /// A stop is "passed" only when the driver's progress fraction along
  /// the full route actually reaches/exceeds the stop's fraction. The
  /// old radius-only check flipped stops to "Passed" from up to 8 km
  /// away. Recomputed from scratch each call so a stale persisted
  /// `_currentStopIndex` (from before this fix) auto-corrects on the
  /// next live poll.
  void _updateProgress(LatLng currentLocation) {
    if (_fixedStops.isEmpty) return;

    final currentFraction = _currentDriverFraction();
    if (currentFraction <= 0 || _fullRoutePolyline.isEmpty) {
      // Polyline not loaded yet — leave the index alone.
      return;
    }

    int recomputedIndex = -1;
    for (int i = 0; i < _fixedStops.length; i++) {
      final stopFraction = _getStopFraction(i);
      if (stopFraction > 0 && currentFraction >= stopFraction) {
        recomputedIndex = i;
      }
    }

    debugPrint("📡 DRIVER LOCATION: ${currentLocation.latitude}, ${currentLocation.longitude} "
        "(fraction=${currentFraction.toStringAsFixed(3)})");
    debugPrint("🎯 STOP INDEX recomputed=$recomputedIndex (was=$_currentStopIndex)");

    if (recomputedIndex == _currentStopIndex) return;

    final now = DateTime.now();
    if (recomputedIndex > _currentStopIndex) {
      // Forward progress — lock arrival times for newly passed stops.
      // Priority: (1) backend passed_at, (2) interpolated fraction time,
      // (3) DateTime.now() fallback. Avoids all stops showing the same time
      // when the screen first loads with the driver already past N stops.
      for (int j = _currentStopIndex + 1; j <= recomputedIndex; j++) {
        if (!_passedStopTimes.containsKey(j)) {
          final stopData = _fixedStops[j];
          final passedAt = stopData['passed_at'] as String?;
          if (passedAt != null && passedAt.isNotEmpty) {
            final formatted = _formatDateTime(passedAt);
            _passedStopTimes[j] = formatted != '-' ? formatted : _formatDateTimeObj(now);
          } else {
            final stopFraction = _getStopFraction(j);
            final dt = _computeDateTimeForFraction(stopFraction);
            _passedStopTimes[j] = dt != null ? _formatDateTimeObj(dt) : _formatDateTimeObj(now);
          }
        }
      }
    } else {
      // Backward correction (stale persisted state, or genuine U-turn).
      // Purge locked times for stops that are no longer passed so the
      // next forward crossing locks the correct time.
      for (int j = recomputedIndex + 1; j <= _currentStopIndex; j++) {
        _passedStopTimes.remove(j);
      }
      debugPrint("↩ STOP INDEX corrected backward: $_currentStopIndex → $recomputedIndex");
    }

    setState(() => _currentStopIndex = recomputedIndex);
    _saveCurrentStopIndex();
    _savePassedStopTimes();
  }

  /// Save current stop index to SharedPreferences.
  Future<void> _saveCurrentStopIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('stop_index_${widget.booking.bookingId}', _currentStopIndex);
    } catch (e) {
      debugPrint('Error saving stop index: $e');
    }
  }

  /// Load current stop index from SharedPreferences.
  Future<void> _loadCurrentStopIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt('stop_index_${widget.booking.bookingId}') ?? -1;
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
        'passed_stop_times_${widget.booking.bookingId}',
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
      final json = prefs.getString('passed_stop_times_${widget.booking.bookingId}');
      if (json == null || json.isEmpty) return;
      final Map<String, dynamic> decoded = jsonDecode(json);
      final loaded = decoded.map((k, v) => MapEntry(int.parse(k), v.toString()));
      // Discard cached times when all entries share the same value — this is
      // the signature of the old bug where every stop was bulk-locked with
      // DateTime.now() in a single pass (e.g. all "2:56 PM"). Discarding
      // lets _updateProgress recompute distinct, interpolated times instead.
      if (loaded.length > 1 && loaded.values.toSet().length == 1) return;
      setState(() {
        _passedStopTimes = loaded;
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
          if (stop['passed_at'] != null) 'passed_at': stop['passed_at'],
        };
      }).toList();
      await prefs.setString(
        'fixed_stops_${widget.booking.bookingId}',
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
      final json = prefs.getString('fixed_stops_${widget.booking.bookingId}');
      if (json == null || json.isEmpty) return false;

      final List<dynamic> decoded = jsonDecode(json);
      final stops = decoded.map((item) {
        return Map<String, dynamic>.from(item);
      }).toList();
debugPrint("📦 Loaded Fixed Stops from storage:");

for (var stop in stops) {
  debugPrint("→ ${stop['name']}");
}
      final deduped = _deduplicateStops(stops);
      if (deduped.isNotEmpty) {
        setState(() {
          _fixedStops = deduped;
          _isLoadingFixedStops = false;
        });
        return true;
      }
    } catch (e) {
      debugPrint('Error loading fixed stops: $e');
    }
    return false;
  }

  /// First place-name component before the first comma, lowercased.
  /// Mirrors the PHP server dedup logic so "Kamareddy, Telangana" == "Kamareddy".
  String _firstNameComponent(String name) => name.split(',')[0].toLowerCase().trim();

  /// Remove auto-generated stops that share a name with any key stop, and
  /// remove auto-generated stops with duplicate names among themselves.
  /// Also removes auto-stops that are geographically close to a key stop —
  /// this handles the common case where the key stop name is a full address
  /// ("75, Main Road, Bendapudi, AP") while the auto-stop geocodes to just
  /// "Bendapudi": the first-component names don't match, but they represent
  /// the same location and only the key stop should be shown.
  List<Map<String, dynamic>> _deduplicateStops(List<Map<String, dynamic>> stops) {
    final keyStops = stops.where((s) => s['is_key_stop'] == true).toList();
    final keyNames = keyStops
        .map((s) => _firstNameComponent(s['name'] as String))
        .toSet();
    final seenAutoNames = <String>{};
    return stops.where((s) {
      if (s['is_key_stop'] == true) return true;
      final first = _firstNameComponent(s['name'] as String);
      if (first.isEmpty || keyNames.contains(first)) return false;
      // Proximity check: remove auto-stop if it is within 10 km of any key stop.
      // Catches the case where names differ (full address vs locality name) but
      // both refer to the same place — avoids duplicate entries like two
      // "Bendapudi" rows when one is a key stop with a long address.
      final aLat = s['lat'] as double;
      final aLng = s['lng'] as double;
      for (final ks in keyStops) {
        if (_haversineDistance(
              LatLng(aLat, aLng),
              LatLng(ks['lat'] as double, ks['lng'] as double),
            ) <
            10000) {
          return false;
        }
      }
      if (seenAutoNames.contains(first)) return false;
      seenAutoNames.add(first);
      return true;
    }).toList();
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

  /// Highest fraction the driver has ever reached on `_fullRoutePolyline`.
  /// Used to bias future fraction calculations forward — see customer
  /// file (`Bestseeds-user/...`) for full rationale on self-intersecting
  /// routes (out-and-back via a priority waypoint).
  double _maxDriverFractionReached = 0.0;

  /// Where the truck currently is along the full route, as a fraction
  /// 0..1. Forward-only with backtrack tolerance, biased toward the
  /// EARLIEST polyline point within the absolute-min tolerance window
  /// so a self-intersecting route doesn't pin the truck to the wrong
  /// pass.
  double _currentDriverFraction() {
    if (_currentLatLng == null) return _maxDriverFractionReached;
    if (_fullRoutePolyline.isEmpty || _fullRouteCumulativeDistances.isEmpty) {
      return _maxDriverFractionReached;
    }
    final total = _fullRouteCumulativeDistances.last;
    if (total <= 0) return 0.0;

    // Forward search window: never go more than 500 m behind the
    // highest fraction the truck has ever been observed at.
    final minSearchDist =
        (_maxDriverFractionReached * total - 500).clamp(0.0, total);

    // Pass 1: absolute minimum haversine distance from any polyline
    // point at-or-after the search floor.
    double absMin = double.infinity;
    for (int i = 0; i < _fullRoutePolyline.length; i++) {
      if (_fullRouteCumulativeDistances[i] < minSearchDist) continue;
      final d = _haversineDistance(_currentLatLng!, _fullRoutePolyline[i]);
      if (d < absMin) absMin = d;
    }
    if (absMin == double.infinity) return _maxDriverFractionReached;

    // Pass 2: earliest polyline point within +200 m of the absolute
    // minimum. Disambiguates self-intersecting routes by preferring
    // the first-pass leg over the second-pass leg.
    int bestIdx = 0;
    for (int i = 0; i < _fullRoutePolyline.length; i++) {
      if (_fullRouteCumulativeDistances[i] < minSearchDist) continue;
      final d = _haversineDistance(_currentLatLng!, _fullRoutePolyline[i]);
      if (d <= absMin + 200) {
        bestIdx = i;
        break;
      }
    }

    final fraction =
        (_fullRouteCumulativeDistances[bestIdx] / total).clamp(0.0, 1.0);
    if (fraction > _maxDriverFractionReached) {
      _maxDriverFractionReached = fraction;
    }
    return fraction;
  }

  /// Returns the raw [DateTime] for a given route fraction.
  /// Identical logic to [_getTimeForFraction] but returns a [DateTime?]
  /// so callers can compare and clamp before formatting.
  DateTime? _computeDateTimeForFraction(double fraction) {
    final duration = _fullRouteDurationSeconds > 0
        ? _fullRouteDurationSeconds
        : _totalRouteDurationSeconds;
    if (duration == 0) return null;

    final currentFraction = _currentDriverFraction();
    if (fraction <= currentFraction || _remainingDurationSeconds <= 0) {
      DateTime? baseTime;
      if (_trackingData?.inProgressAt != null && _trackingData!.inProgressAt!.isNotEmpty) {
        try {
          baseTime = DateTime.parse(_trackingData!.inProgressAt!);
        } catch (_) {}
      }
      baseTime ??= _routeStartTime;
      if (baseTime == null) return null;
      // Interpolate using actual elapsed travel time so passed intermediate
      // stops show times consistent with the driver's real position rather
      // than times computed from the (often much larger) estimated total
      // route duration (e.g. a 19-hour route where the driver covered 30%
      // in 1.5 hours would otherwise show 6:30 PM for a stop at 27%).
      if (currentFraction > 0 && _trackingData?.driverLocation.updatedAt != null) {
        try {
          final driverTime = DateTime.parse(_trackingData!.driverLocation.updatedAt!);
          if (driverTime.isAfter(baseTime)) {
            final elapsed = driverTime.difference(baseTime);
            final t = (fraction / currentFraction).clamp(0.0, 1.0);
            return baseTime.add(Duration(seconds: (t * elapsed.inSeconds).round()));
          }
        } catch (_) {}
      }
      // Fallback to estimated duration when driver timestamp is unavailable.
      final seconds = (fraction * duration).round();
      return baseTime.add(Duration(seconds: seconds));
    }

    // Future branch: now() + speed-adaptive remaining, capped at Google Maps ETA.
    final adaptiveRemaining = _adaptiveRemainingSeconds();
    final effectiveRemaining = _remainingDurationSeconds > 0
        ? min(adaptiveRemaining, _remainingDurationSeconds)
        : adaptiveRemaining;
    final routeAhead = (1.0 - currentFraction).clamp(0.0001, 1.0);
    final stopAhead = (fraction - currentFraction).clamp(0.0, 1.0);
    final secondsFromNow =
        ((stopAhead / routeAhead) * effectiveRemaining).round();
    return DateTime.now().add(Duration(seconds: secondsFromNow));
  }

  String _getTimeForFraction(double fraction) {
    final dt = _computeDateTimeForFraction(fraction);
    return dt != null ? _formatDateTimeObj(dt) : '-';
  }

  /// Locally-computed remaining duration adjusted for actual driver
  /// speed. Uses `_estimatedSpeedKmh` (computed from successive GPS
  /// poll positions, not the backend's pre-baked field) so the ETA
  /// reflects the truck's REAL movement, not whatever the backend
  /// happened to think the speed was.
  ///
  /// Falls back to the static `_remainingDurationSeconds` when:
  ///   - actual speed is below 5 km/h (parked / crawling — division
  ///     by ~0 would balloon the ETA. In this case Google's static
  ///     duration which already accounts for traffic / road
  ///     conditions is the better number.),
  ///   - route distance/duration metadata isn't loaded yet,
  ///   - or the computed scale falls outside [0.5, 2.0] (clamped to
  ///     prevent a one-off GPS spike from sending the ETA wildly off).
  int _adaptiveRemainingSeconds() {
    if (_remainingDurationSeconds <= 0) return _remainingDurationSeconds;
    if (_estimatedSpeedKmh < 5) return _remainingDurationSeconds;
    if (_fullRouteCumulativeDistances.isEmpty) return _remainingDurationSeconds;

    final totalRouteMeters = _fullRouteCumulativeDistances.last;
    final totalDurationSec = _fullRouteDurationSeconds > 0
        ? _fullRouteDurationSeconds
        : _totalRouteDurationSeconds;
    if (totalRouteMeters <= 0 || totalDurationSec <= 0) {
      return _remainingDurationSeconds;
    }

    final expectedAvgKmh = (totalRouteMeters / totalDurationSec) * 3.6;
    if (expectedAvgKmh < 1) return _remainingDurationSeconds;

    // scale > 1 → driver slower than expected → ETA grows.
    // scale < 1 → driver faster than expected → ETA shrinks.
    final rawScale = expectedAvgKmh / _estimatedSpeedKmh;
    final scale = rawScale.clamp(0.5, 2.0);
    return (_remainingDurationSeconds * scale).round();
  }

  /// Update the smoothed speed estimate from the latest GPS position.
  /// Called once per accepted live poll. Exponential smoothing (α=0.3)
  /// stops a single GPS spike from briefly doubling/halving the ETA.
  void _updateSpeedEstimate(LatLng newPos) {
    final now = DateTime.now();
    if (_lastSpeedCalcPos != null && _lastSpeedCalcTime != null) {
      final elapsed = now.difference(_lastSpeedCalcTime!).inSeconds;
      if (elapsed > 0) {
        final dist = _haversineMeters(_lastSpeedCalcPos!, newPos);
        final instantSpeed = (dist / elapsed) * 3.6;
        _estimatedSpeedKmh = _estimatedSpeedKmh * 0.7 + instantSpeed * 0.3;
      }
    }
    _lastSpeedCalcPos = newPos;
    _lastSpeedCalcTime = now;

    // Stable mode switching
    final int targetMode = _estimatedSpeedKmh >= 60 ? 2 : (_estimatedSpeedKmh >= 25 ? 1 : 0);
    if (targetMode != _currentMode) {
      if (targetMode == _pendingMode) {
        _pendingModeCount++;
        if (_pendingModeCount >= _modeChangeThreshold) {
          _currentMode = targetMode;
          _pendingModeCount = 0;
        }
      } else {
        _pendingMode = targetMode;
        _pendingModeCount = 1;
      }
    } else {
      _pendingModeCount = 0;
    }
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
          // Prefer the server-computed ETA (includes halt-time adjustments).
          // Fall back to local fraction-based calculation if API didn't provide it.
          final apiTime = sub['estimated_arrival'] as String? ?? '';
          String subTime;
          if (apiTime.isNotEmpty) {
            subTime = apiTime;
          } else {
            final fraction = sub['distance_fraction'] as double? ?? 0.0;
            subTime = fraction > 0 ? _getTimeForFraction(fraction) : '-';
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
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      final hour = dateTime.hour > 12 ? dateTime.hour - 12 : dateTime.hour;
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
    // Connector below this item is green ONLY when both this item AND
    // the next item are passed. Without this, the connector below
    // "Pickup started from" (always passed) was always green —
    // visually reaching down into the next stop's icon and making
    // customers think the truck had progressed there.
    bool isNextPassed = false,
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
                  // Connector is green only when BOTH this item AND
                  // the next are passed — so the green trail visibly
                  // stops at the last passed stop and doesn't bleed
                  // into the next (unpassed) stop's icon.
                  final connectorPassed = isPassed && isNextPassed;
                  return Container(
                    width: connectorPassed ? 3 : 2,
                    height: lineHeight,
                    color: connectorPassed ? Colors.green : Colors.grey.shade300,
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
    debugPrint("checking for last update $lastUpdateDate");
    debugPrint("checking for last update $lastUpdateTime");
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
    _followResumeTimer?.cancel();
    _smallMapController?.dispose();
    _expandedMapController?.dispose();
    super.dispose();
  }
}
