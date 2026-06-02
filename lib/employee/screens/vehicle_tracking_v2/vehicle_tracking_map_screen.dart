// These points are added by adithya

// Reduced Google Maps API cost by avoiding frequent Directions API calls
// Reused initial route instead of redrawing polyline on every GPS update
// Switched to marker-only updates for live movement (no full map redraw)
// previously route is guessing not shown actual travelled path
// Implemented breadcrumb-based tracking for travelled path (green line)
// Added intelligent rerouting only on route deviation (not continuously)
// Built hybrid snapping system (on-road smooth + off-road accurate)
// Prevented polyline cutting through buildings using snap + fallback logic
// Implemented segment-based route snapping (no full polyline scan)
// Added forward-only segment progression (no backward jumps)
// Designed dynamic speed-based system (city / suburban / highway modes)
// Adaptive thresholds for snapping, rerouting, breadcrumbs, and camera
// Implemented deviation detection with consecutive polling (noise-safe)
// Added immediate reroute for large deviations (>150m)
// Optimized breadcrumb density for long-distance travel (downsampling)
// Implemented smooth marker animation with easing
// Synced camera movement with marker animation (Uber-like follow mode)
// Added bearing-based vehicle rotation (realistic movement direction)
// Fixed rotation via asset normalization (no runtime hacks)
// Implemented camera follow mode with user override + recenter
// Dynamic zoom based on speed (city vs highway view)
// Prevented GPS jitter using spike + direction filtering
// Improved backend data consistency (timestamp ordering + deduplication)
// Switched from timeline dependency to real-time breadcrumb system
// Separated green (actual path) and blue (predicted route) logic
// Built lightweight reroute system (updates only remaining route)
// Handled long-distance trips efficiently (1000km+ scalability)


import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get/get.dart'; // for Iterable.firstWhereOrNull
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:bestseeds/widgets/refresh_button.dart';
import 'package:bestseeds/utils/google_maps_service.dart';
import 'custom_marker_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bestseeds/driver/models/specific_vehicle_tracking_response.dart';
import 'package:bestseeds/driver/service/auth_service.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/employee/services/tracking_stops_service.dart';

/// Fresh 1:1 port of the user app's
/// `seedsuser/app/vehicle_tracking/view/vehicle_tracking_map_screen.dart`
/// into the vendor/employee module.
///
/// Only the data layer is adapted: tracking data is fetched from the vendor
/// endpoint (`vendor/bookings/{id}/tracking`) via [AuthService] +
/// [StorageService] instead of the farmer endpoint / GetX controller. Every
/// piece of UI, animation, snapping, rerouting and timeline logic is identical
/// to the user app.
class VehicleTrackingMapScreenV2 extends StatefulWidget {
  final String bookingId;

  const VehicleTrackingMapScreenV2({super.key, required this.bookingId});

  @override
  State<VehicleTrackingMapScreenV2> createState() =>
      _VehicleTrackingMapScreenV2State();
}

class _VehicleTrackingMapScreenV2State extends State<VehicleTrackingMapScreenV2>
    with TickerProviderStateMixin {
  final AuthService _authService = AuthService();
  final StorageService _storageService = StorageService();

  /// Vendor replacement for the user app's
  /// `controller.fetchSpecificVehicleTracking` + `controller.specificVehicle`.
  /// Fetches from the vendor tracking endpoint and returns the parsed
  /// [TrackingData] (or null on any failure).
  Future<TrackingData?> _fetchTrackingData() async {
    final token = _storageService.getToken();
    if (token == null || token.isEmpty) {
      debugPrint('🔄 [FETCH] No token — session expired');
      return null;
    }

    final bookingIdInt = int.tryParse(widget.bookingId);
    if (bookingIdInt == null) {
      debugPrint('🔄 [FETCH] Invalid bookingId "${widget.bookingId}"');
      return null;
    }

    // Vendor-specific endpoint. The farmer/vehicle_tracking endpoint checks
    // customer_mobile/farmer_id which doesn't match for vendor login (404).
    final response = await _authService.getBookingTracking(
      token: token,
      bookingId: bookingIdInt,
    );

    if (!mounted) return null;

    if (response['status'] != true) {
      debugPrint('🔄 [FETCH] status=false: ${response['message']}');
      return null;
    }

    final parsed = SpecificVehicleTrackingResponse.fromJson(response);
    final data = parsed.data;

    // Sanity guard: refuse a payload whose booking id doesn't match the one we
    // asked for (protects against the "tap booking A, see booking B" bug).
    if (data != null &&
        data.bookingId != 0 &&
        data.bookingId != bookingIdInt) {
      debugPrint(
          '🔄 [FETCH] Booking mismatch: requested $bookingIdInt got ${data.bookingId}');
      return null;
    }

    return data;
  }

  // Separate controllers for small and expanded maps
  GoogleMapController? _smallMapController;
  GoogleMapController? _expandedMapController;

  // Default location (Hyderabad, India)
  static const LatLng _defaultLocation = LatLng(17.3850, 78.4867);
  static const Duration _liveTrackingPollInterval = Duration(seconds: 7);
  static const Duration _routeRefreshInterval = Duration(minutes: 5);
  // Minimum gap between two reroute API calls. 15 seconds is the
  // responsive-but-safe lower bound: it prevents a flickering GPS from
  // firing back-to-back reroutes (which would burn API quota and make
  // the blue line flash), while still letting a real deviation produce
  // a fresh blue route within about 1 poll interval.
  static const Duration _rerouteCooldown = Duration(seconds: 15);
  static const Duration _markerAnimationStepDuration = Duration(
    milliseconds: 40,
  );
  static const int _markerAnimationSteps = 25; // 25 × 40ms = 1 second
  // Driver is considered "off route" the moment their perpendicular
  // distance to the blue polyline exceeds this. 100 m is below the width
  // of any parallel road, so legitimate lane drift / turn preparation
  // won't trigger it, but a genuine wrong-turn onto a different road
  // will. Mode-specific bumps happen in `_rerouteThreshold` below.
  static const double _polylineRerouteThresholdMeters = 100;
  // Two consecutive polls (≈14 s at 7 s interval) of sustained deviation
  // are enough to confirm it's a real wrong turn, not a GPS jitter.
  // Previously was 3 polls which added an extra 7 s of delay.
  static const int _deviationsBeforeReroute = 2;

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
  bool _isLoadingRoute = true;

  // Follow mode: camera tracks vehicle with bearing rotation
  bool _isFollowingVehicle = true;
  bool _isProgrammaticCameraMove = false; // distinguishes user drag vs our animateCamera
  static const double _followZoom = 16.5;
  static const double _followTilt = 45.0; // 3D perspective tilt

  // Auto-resume follow mode after the user has stopped touching the map
  // for this long. Without this, a single accidental pinch / pan during a
  // long trip permanently abandons the truck off-screen.
  static const Duration _followAutoResumeDelay = Duration(seconds: 8);
  Timer? _followResumeTimer;

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
  // Home/pickup MARKER position. Prefers admin_pickup if admin set one
  // (resolved by lat/lng or by geocoding the name). Falls back to
  // _pickupLatLng (driver's actual journey start) when admin didn't set
  // a separate pickup. Decoupled from _pickupLatLng so the route fetch
  // can still use driver-start as the origin while the marker shows
  // where admin intended.
  LatLng? _homeMarkerLatLng;
  LatLng? _currentLatLng;
  LatLng? _destinationLatLng;
  LatLng? _lastVehicleMarkerLatLng;
  double _lastVehicleBearing = 0;

  // Segment-based snapping: track which polyline segment the vehicle is on.
  // Only search nearby segments (forward) instead of entire route.
  int _currentSegmentIndex = 0;

  // ── SNAP STATE FOR THE PIPELINE ──
  // Set on every successful snap. Used by:
  //   - Bearing check  (_lastAcceptedSnap, raw vs snap direction agree?)
  //   - Parallel filter (raw barely moved but snap jumped far?)
  //   - Gap protection in render (_lastRenderedSnap)
  LatLng? _lastAcceptedSnap;
  LatLng? _lastAcceptedRaw;
  LatLng? _lastRenderedSnap;

  // ── SNAP IDEMPOTENCY CACHE ──
  // _snapToRoute is called multiple times per render frame (animation
  // steps × 25, plus marker build, plus polyline refresh). Without a
  // cache, the second call with the same input would observe the
  // side-effects of the first call — most importantly, Gate 5 buffers
  // on the first call and confirms on the second, causing the marker
  // and the polyline to render against different state. That's how
  // "green cuts through buildings" and "blue where green should be"
  // appear.
  //
  // Cache key is the raw input position. Cache miss → run the full
  // pipeline once. Cache hit → return the same output, no gate
  // re-evaluation, no state mutation.
  LatLng? _snapCacheInput;
  LatLng? _snapCacheOutput;

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

  // ── APPROACH POLYLINE (pickup → driver) ──
  // When the admin sets a pickup location but the driver actually starts
  // somewhere else (e.g. admin set Vikarabad as pickup but the driver
  // begins from Madhapur), we draw a separate green line connecting the
  // Actual GPS breadcrumbs — the real path the driver took.
  // Used for the green completed polyline instead of Directions API route.
  List<LatLng> _driverBreadcrumbs = [];
  DateTime? _lastBreadcrumbTime;
  int _consecutiveDeviations = 0;

  // Point buffer: hold 3+ points before committing to breadcrumbs.
  // Removes jitter patterns completely — only commit when direction is confirmed
  // across at least three consecutive consistent samples.
  List<LatLng> _pointBuffer = [];
  // Minimum buffered points required before we trust the direction and commit
  // them to the breadcrumb trail. Bumped from 2 → 3 because two points alone
  // weren't enough to filter the small "square loop" jitter patterns we saw
  // in cities (booking 547/548).
  static const int _minBufferCommitPoints = 3;
  // Track if driver is stationary (from backend is_moving flag + local speed check)
  bool _driverIsMoving = true;

  // ── ACTIVE-DROP GATING ──
  // For multi-drop trips, this customer's booking is "active" only when the
  // driver is actually serving it — meaning every earlier-priority drop has
  // been completed. While earlier drops are still pending, the truck is
  // serving someone else, so we hide the vehicle marker on this screen
  // (otherwise the customer sees the truck moving toward another customer's
  // drop and gets misled). True when no uncompleted earlier-priority drops
  // exist in routeWaypoints.
  bool _isActiveDrop = true;

  // Speed-based dynamic behavior: auto-adjusts for city vs highway.
  // Updated every GPS poll. All thresholds derive from _currentMode.
  double _estimatedSpeedKmh = 0;
  LatLng? _lastSpeedCalcPos;
  DateTime? _lastSpeedCalcTime;
  // Mode stability: prevent flickering between city/suburban/highway.
  // Mode only changes after 3 consecutive polls agree on a new mode.
  int _currentMode = 0; // 0=city, 1=suburban, 2=highway
  int _pendingMode = 0;
  int _pendingModeCount = 0;
  static const int _modeChangeThreshold = 3; // polls needed to switch

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
  // route fetch / reroute / refresh poll. Used by `_getTimeForFraction`
  // to anchor FUTURE stop ETAs on `now + remainingDuration` instead of
  // `journey_start + fraction × original`, so a halt at any stop pushes
  // every downstream stop forward by the halt duration automatically.
  int _remainingDurationSeconds = 0;
  DateTime _remainingDurationSetAt = DateTime.now();

  /// Returns the remaining seconds adjusted for wall-clock time elapsed
  /// since the value was last set by the Directions API.
  int get _liveRemainingSeconds {
    if (_remainingDurationSeconds <= 0) return 0;
    final elapsed = DateTime.now().difference(_remainingDurationSetAt).inSeconds;
    return (_remainingDurationSeconds - elapsed).clamp(0, _remainingDurationSeconds);
  }

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

    // Initialise FIRST, then start live polling. Without this, the live
    // timer fires concurrently with the (slow, async) Google Directions
    // call inside `_initializeMap` and both flows mutate `_currentLatLng`,
    // `_currentSegmentIndex`, and the snap pipeline state in interleaved
    // order. Result: on screen reopen the first frame shows the BLUE
    // line covering the travelled portion (because the slice index hasn't
    // been seeded yet) until the race resolves a few polls later. Deferring
    // the timer guarantees init runs to completion before the first poll.
    _initializeMap().whenComplete(() {
      if (!mounted) return;
      _liveTrackingTimer = Timer.periodic(_liveTrackingPollInterval, (_) {
        if (!mounted || _isRefreshing) return;
        // Stop polling if destination reached
        final isDelivered = _trackingData?.isDelivered ?? false;
        final atDest = _currentLatLng != null &&
            _destinationLatLng != null &&
            _haversineDistance(_currentLatLng!, _destinationLatLng!) < 50;
        if (isDelivered || atDest) {
          debugPrint('🔄 [REFRESH] Destination reached — stopping polling');
          _liveTrackingTimer?.cancel();
          return;
        }
        _refreshData().catchError((e) {
          debugPrint('🔄 [REFRESH] Timer error: $e');
        });
      });
    });
  }

  Future<void> _initializeMap() async {
    // Fetch tracking data (vendor endpoint)
    _trackingData = await _fetchTrackingData();
    if (_trackingData == null) {
      setState(() {
        _isLoadingRoute = false;
      });
      return;
    }

    final driverLoc = _trackingData!.driverLocation;

    // Get current vehicle position from API
    if (driverLoc.lat != 0 && driverLoc.lng != 0) {
      _currentVehiclePosition = LatLng(driverLoc.lat, driverLoc.lng);
    } else {
      _currentVehiclePosition = _defaultLocation;
    }

    // Set initial camera position - will be updated to fit all markers
    _initialPosition = CameraPosition(
      target: _currentVehiclePosition,
      zoom: 10.0,
    );

    // Load custom markers (non-blocking, fast — just image decoding)
    await _loadCustomMarkers();

    // Setup markers, route and polylines — show UI as soon as markers are ready
    try {
      await _setupMarkersAndPolylines();
    } catch (e) {
      debugPrint('🗺️ [INIT] Route setup error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingRoute = false;
          _lastRefreshedAt = DateTime.now();
        });
      }
    }
  }

  Future<void> _refreshData({bool forceRouteRefresh = false}) async {
    if (_isRefreshing && !forceRouteRefresh) return;
    debugPrint('🔄 [REFRESH] Started (force=$forceRouteRefresh)');
    setState(() => _isRefreshing = true);

    try {
      final newData = await _fetchTrackingData();

      if (newData != null) {
        debugPrint('🔄 [REFRESH] API data received: driver=(${newData.driverLocation.lat},${newData.driverLocation.lng}) status=${newData.driverLocation.driverStatus} speed=${newData.driverLocation.speedKmh}');
        debugPrint('🔄 [REFRESH] passed_stops from DB: ${newData.passedStops.length} items, breadcrumbs: ${newData.driverBreadcrumbs.length}');
        final oldPickup = _trackingData?.pickup;
        final oldDrop = _trackingData?.drop;
        final previousVehiclePosition = _currentLatLng;
        _trackingData = newData;

        final driverLoc = newData.driverLocation;
        if (driverLoc.lat != 0 && driverLoc.lng != 0) {
          final newPos = LatLng(driverLoc.lat, driverLoc.lng);

          // ── STALE-POLL GUARD ──
          // The backend rejects spike updates with HTTP 422, leaving
          // bookings.driver_lat unchanged. The next poll then returns the
          // same coordinates we already processed last time. If we let
          // those re-flow through the pipeline, the snap can drift, the
          // marker can flicker between two positions, and a long
          // rejection streak followed by an accepted point produces a
          // visible "snap back to pickup → straight line forward" jump.
          //
          // Check if driver actually moved — used to skip breadcrumb noise,
          // but always update position, stops, and ETA.
          final bool driverMoved = forceRouteRefresh ||
              previousVehiclePosition == null ||
              _haversineMeters(previousVehiclePosition, newPos) >= 2;

          if (!driverMoved) {
            debugPrint('🔄 [REFRESH] Driver stationary (<2m) — updating stops/ETA only');
          } else {
            debugPrint('🔄 [REFRESH] ✅ Processing new position');
          }

          // Always update position so marker and ETA reflect latest
          _currentVehiclePosition = newPos;
          _currentLatLng = newPos;

          // Update speed estimate for dynamic thresholds (city vs highway)
          _updateSpeedEstimate(newPos);

          // ── Use backend is_moving flag to stop drawing when stationary ──
          _driverIsMoving = newData.driverLocation.isMoving;

          // ── Collect GPS breadcrumb (actual path driven) — only when moved ──
          if (!driverMoved) {
            // Skip breadcrumb processing but continue to stops/ETA below
          } else {
          // ── Collect GPS breadcrumb (actual path driven) ──
          // Pipeline: filter → validate → buffer → snap → commit
          // CITY: strict snapping, never raw GPS, higher thresholds
          // HIGHWAY: relaxed snapping, allow raw GPS, lower thresholds
          final now = DateTime.now();
          final secSinceLast = _lastBreadcrumbTime != null
              ? now.difference(_lastBreadcrumbTime!).inSeconds
              : 999;
          if (_driverBreadcrumbs.isEmpty) {
            // Seed along planned route — see _seedBreadcrumbsAlongPlannedRoute
            // for why we slice _fullPolyline instead of just adding two
            // endpoints (which produced the diagonal-through-buildings line).
            _seedBreadcrumbsAlongPlannedRoute(newPos);
            _lastBreadcrumbTime = now;
            _pointBuffer.clear();
          } else if (!_driverIsMoving) {
            // ── STATIONARY: don't update polyline at all ──
            // Backend confirmed driver is not moving — skip breadcrumb entirely.
            // This prevents GPS drift from drawing noise while parked/stopped.
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
                final jitterThreshold = _currentMode == 0 ? 100.0 : (_currentMode == 1 ? 120.0 : 140.0);
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
              final largeJumpThreshold = _currentMode == 0 ? 120.0 : (_currentMode == 1 ? 200.0 : 350.0);
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
                      // else: snap failed — hold position, don't add raw
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
        } // end if (driverMoved) else breadcrumb block
        }

        // Update ETA on EVERY poll — even when driver lat/lng is null (use pickup)
        final etaOrigin = _currentLatLng ?? _pickupLatLng;
        if (_destinationLatLng != null && etaOrigin != null) {
          double etaDistKm = newData.remainingDistanceKm.toDouble();
          if (etaDistKm <= 0) {
            etaDistKm = _haversineDistance(etaOrigin, _destinationLatLng!) / 1000;
          }
          if (etaDistKm > 0.1) {
            final avgSpeedKmh = etaDistKm < 10 ? 30.0 : (etaDistKm > 50 ? 60.0 : 40.0);
            final etaSeconds = ((etaDistKm / avgSpeedKmh) * 3600).round();
            _remainingDurationSeconds = etaSeconds;
            _remainingDurationSetAt = DateTime.now();
            _estimatedDuration = _formatDuration(etaSeconds);
          }
        }

        // Check if route endpoints changed (rare — usually only driver moves)
        final pickupChanged = oldPickup?.name != newData.pickup.name;
        final dropChanged = oldDrop?.name != newData.drop.name;
        final routeChanged = pickupChanged || dropChanged;

        // Retry full setup if route never loaded (polyline empty)
        final routeNeverLoaded = _fullPolyline.isEmpty && _pickupLatLng != null && _destinationLatLng != null;

        if (routeChanged || routeNeverLoaded) {
          if (routeNeverLoaded && !routeChanged) {
            debugPrint('🔄 [REFRESH] Route never loaded — retrying full setup');
          }
          // Only reset state on actual route change, not on retry
          if (routeChanged) {
            _routeStops = [];
            _routeStartTime = null;
            _totalRouteDurationSeconds = 0;
            _estimatedDuration = '';
            _remainingDurationSeconds = 0;
            _remainingDurationSetAt = DateTime.now();
            _fullPolyline = [];
            _cumulativeDistances = [];
            _currentSegmentIndex = 0;
            _expandedSegmentIndex = null;
            _subStopsCache = {};
            _loadingSegment = null;
            _fixedStopsGenerated = false;
            _fixedStops = [];
            _currentStopIndex = -1;
            _fullRoutePolyline = [];
            _fullRouteCumulativeDistances = [];
            _fullRouteDurationSeconds = 0;
            _passedStopTimes = {};
          }

          // Only reset breadcrumbs if PICKUP changed (new journey origin).
          // If only destination changed, keep the driven path — it's still
          // valid history.
          if (pickupChanged) {
            _driverBreadcrumbs = [];
            _lastBreadcrumbTime = null;
            _pointBuffer.clear();
            // The fraction-watermark belongs to the PREVIOUS route.
            // Resetting allows the new route's fraction search to start
            // from 0 instead of being pinned to the old route's progress.
            _maxDriverFractionReached = 0.0;
            // Reset the snap pipeline state — a new journey origin means
            // previous bearing/parallel references are stale.
            _lastAcceptedSnap = null;
            _lastAcceptedRaw = null;
            _lastRenderedSnap = null;
            _snapCacheInput = null;
            _snapCacheOutput = null;
            // Wipe any leftover green-polyline cache from older app versions
            // (the timeline-from-API system that was removed) so nothing stale
            // resurfaces on the new journey.
            // No cache to clear — all data is fresh from API
          }

          await _setupMarkersAndPolylines();
        } else {
          // Ensure pickup/destination are set (might be null if initial setup failed)
          if (_pickupLatLng == null && newData.pickup.lat != 0 && newData.pickup.lng != 0) {
            _pickupLatLng = LatLng(newData.pickup.lat, newData.pickup.lng);
          }
          if (_destinationLatLng == null && newData.drop.lat != 0 && newData.drop.lng != 0) {
            _destinationLatLng = LatLng(newData.drop.lat, newData.drop.lng);
          }

          // Rebuild timeline whenever API passed stop count changes.
          // Always rebuild from scratch to ensure API names take priority
          // over client-generated stop names.
          final apiPassedCount = newData.passedStops.length;
          final currentApiStopCount = _fixedStops.where((s) =>
              s['api_time'] != null).length;
          debugPrint('🔄 [POLL] apiPassed=$apiPassedCount currentApi=$currentApiStopCount fixedStops=${_fixedStops.length} driver=(${_currentLatLng?.latitude},${_currentLatLng?.longitude})');
          if (apiPassedCount != currentApiStopCount || (_fixedStops.isEmpty && apiPassedCount > 0)) {
            debugPrint('🔄 [POLL] Rebuilding timeline (passed count changed)');
            _fixedStopsGenerated = false;
            await _buildFixedStopsFromPassedAndUpcoming();
            _fixedStopsGenerated = true;
            debugPrint('🔄 [POLL] Rebuild done. fixedStops=${_fixedStops.length}');
          } else {
            debugPrint('🔄 [POLL] No rebuild needed — stops unchanged');
          }

          // Always update progress so vehicle icon moves in timeline
          if (_currentLatLng != null) _updateProgress(_currentLatLng!);
          if (forceRouteRefresh) {
            _buildGreenFromPolyline();
            unawaited(_refreshHomeToVehicleRoute());
          }
          // Only call setState if no rebuild happened (rebuild does its own setState)
          if (apiPassedCount == currentApiStopCount && mounted) {
            setState(() {});
          }

          // Silent update — only move vehicle marker if REAL movement detected.
          // GPS noise (< threshold) is ignored to prevent:
          //   - truck flickering back and forth
          //   - wrong bearing/direction from noise
          //   - green line not growing (breadcrumbs skip noise)
          //
          // PHYSICAL movement wins over the backend's `is_moving` flag.
          // The backend computes `is_moving` as "net displacement >30 m from
          // a 60 s-old tracking row", which can report false negatives when:
          //   - Only 1-2 tracking rows exist (no 60 s-old anchor yet)
          //   - Backend is rejecting spike updates so the old anchor stays
          //   - Driver is crawling in traffic (<30 m/min)
          //
          // Previously `!is_moving` short-circuited the position update and
          // snapped the marker back to `animateFrom`, which froze the marker
          // at its last-rendered position even while new GPS was arriving.
          // Now we let `moveDist >= _breadcrumbMinDistance` be the primary
          // gate — if the GPS actually moved farther than the noise floor,
          // animate to the new position regardless of what the flag says.
          final animateFrom = _lastVehicleMarkerLatLng ?? previousVehiclePosition;
          if (animateFrom != null && _currentLatLng != null) {
            final moveDist = _haversineMeters(animateFrom, _currentLatLng!);
            // Marker has its own (much smaller) threshold than the breadcrumb-
            // commit gate. During a reroute / slow turn the driver may move
            // only ~10–25 m per poll — that's below `_breadcrumbMinDistance`
            // so we shouldn't ADD a breadcrumb point, but the truck is still
            // physically moving and the marker has to follow it. Anything
            // ≥5 m is well above GPS noise and worth animating.
            if (moveDist >= 5) {
              _animateVehicleMarker(animateFrom, _currentLatLng!);
            } else {
              // Sub-noise-floor move — likely a parked truck drifting.
              // Keep `_currentLatLng` at the new (reported) position so
              // any downstream consumer sees fresh data, but skip the
              // animation so the marker doesn't jitter in place.
              _refreshCompletedPolylineFromTimeline();
            }
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

          // ── REROUTE DETECTION (consecutive deviation) ──
          // Track deviation over multiple polls to avoid false triggers.
          // Only reroutes blue line — green breadcrumbs stay untouched.
          if (_currentLatLng != null) {
            final polylinePoints = _polylines
                .where((p) => p.polylineId.value != 'completed')
                .expand((p) => p.points)
                .toList();
            if (polylinePoints.isNotEmpty) {
              final deviation = _minDistanceToPolyline(
                _currentLatLng!,
                polylinePoints,
              );

              // ── REROUTE GUARD: never reroute when slow or stationary ──
              // A parked truck with drifting GPS will look "deviated" even
              // though the driver hasn't moved. Reroutes triggered in that
              // state burn API quota AND can snap blue to a wrong road if
              // GPS happens to drift onto a parallel street.
              //
              // Trust the app's own exponentially-smoothed speed estimate
              // (`_estimatedSpeedKmh`), NOT the backend's `is_moving` flag.
              // The flag is false-negative-prone (see `_refreshData` marker
              // logic) and can block legitimate reroutes when the truck is
              // actually doing 40 km/h on a different road.
              final bool tooSlowToReroute = _estimatedSpeedKmh < 5;

              // Structural deviation: a >120 m offset from the planned
              // polyline cannot be GPS jitter — the driver is on a
              // different road. Force-reroute now, bypassing BOTH the
              // speed guard AND the 15s cooldown. Without this bypass
              // the truck marker freezes (snap pipeline holds because the
              // GPS is far from _fullPolyline) and the green line keeps
              // growing alone until the cooldown expires or the user
              // back-navigates and re-enters the screen.
              final bool structuralDeviation = deviation > 120;

              if ((deviation > _rerouteThreshold && !tooSlowToReroute) || structuralDeviation) {
                _consecutiveDeviations++;
                debugPrint(
                  '📡 Deviation: ${deviation.toStringAsFixed(0)}m '
                  '(threshold=${_rerouteThreshold.toStringAsFixed(0)}m, '
                  '${_consecutiveDeviations}/$_deviationsBeforeReroute, '
                  'speed=${_estimatedSpeedKmh.toStringAsFixed(0)}km/h'
                  '${structuralDeviation ? ', STRUCTURAL' : ''})',
                );

                // Reroute now if:
                //   • structural (>200m) → bypass cooldown AND speed
                //   • >1.5× threshold → bypass consecutive-count gate
                //   • otherwise wait for 2 consecutive polls
                final shouldReroute = structuralDeviation
                    || ((deviation > _rerouteThreshold * 1.5 || _consecutiveDeviations >= _deviationsBeforeReroute)
                        && _shouldRefreshRoute(forceRefresh: forceRouteRefresh));

                if (shouldReroute) {
                  _consecutiveDeviations = 0;
                  await _rerouteFromDriverPosition();
                }
              } else {
                if (tooSlowToReroute && deviation > _rerouteThreshold) {
                  debugPrint('⏸️ Deviation ignored: stationary/slow '
                      '(speed=${_estimatedSpeedKmh.toStringAsFixed(0)}km/h)');
                }
                // Driver back on route — cancel reroute trigger
                if (_consecutiveDeviations > 0) {
                  debugPrint('✅ Driver back on route — deviation reset');
                }
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
      debugPrint('🔄 [REFRESH] Done');
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _loadCustomMarkers() async {
    // Small map markers (smaller size for compact view)
    _smallTruckMarker =
        await CustomMarkerHelperV2.getTruckMarker(size: 40);
    _smallPickupMarker =
        await CustomMarkerHelperV2.getStartLocationMarkerFromAsset(size: 26);
    _smallDestinationMarker =
        await CustomMarkerHelperV2.getDropLocationMarkerFromAsset(size: 26);

    // Expanded map markers (bigger size for full screen view)
    _expandedTruckMarker =
        await CustomMarkerHelperV2.getTruckMarker(size: 64);
    _expandedPickupMarker =
        await CustomMarkerHelperV2.getStartLocationMarkerFromAsset(size: 30);
    _expandedDestinationMarker =
        await CustomMarkerHelperV2.getDropLocationMarkerFromAsset(size: 30);
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

    /// -------- Get Current Location Coordinates --------
    if (driverLoc.lat != 0 && driverLoc.lng != 0) {
      _currentLatLng = LatLng(driverLoc.lat, driverLoc.lng);
    }

    /// -------- Resolve HOME MARKER (admin pickup if set, else driver pickup) --------
    /// Marker position is split from the route origin. Route fetch keeps
    /// using _pickupLatLng (driver's actual journey start) so geometry is
    /// unaffected. Marker shows where admin intended to start.
    final adminPickup = _trackingData?.adminPickup;
    if (adminPickup != null &&
        adminPickup.lat != 0 &&
        adminPickup.lng != 0) {
      _homeMarkerLatLng = LatLng(adminPickup.lat, adminPickup.lng);
    } else {
      _homeMarkerLatLng = _pickupLatLng;
    }

    /// -------- Get Destination Coordinates --------
    if (destination.lat != 0 && destination.lng != 0) {
      _destinationLatLng = LatLng(destination.lat, destination.lng);
    } else if (destination.name.isNotEmpty) {
      _destinationLatLng = await GoogleMapsService.geocodeAddress(
        destination.name,
      );
    }

    // ── Determine whether this customer's booking is the ACTIVE drop ──
    // Previously this was gated on uncompleted earlier-priority waypoints,
    // which hid the truck for priority 2/3/+ bookings while priority 1 was
    // still in progress (e.g. Hyd→Gnt via BZA). Customers want to see the
    // truck for ALL their bookings regardless of priority, so the gate is
    // always open. Field kept so the existing _buildMarkers check works.
    _isActiveDrop = true;

    // Build markers for both small and expanded views
    _buildMarkers();

    /// -------- Route + Intermediate Stops using single Directions API call --------
    if (_pickupLatLng != null && _destinationLatLng != null) {
      // Separate waypoints into delivered (completed) and remaining (pending/in-progress)
      // Sorted by priority so polyline follows the intended delivery order
      // Use ALL waypoints (including completed ones) so the route polyline
      // always goes through Vijayawada etc. — the green covered path needs
      // the full road geometry, not just the remaining portion.
      final allWaypoints = _trackingData!.routeWaypoints
          .where((wp) => wp.lat != 0 && wp.lng != 0)
          .toList()
        ..sort((a, b) => a.priority.compareTo(b.priority));
      final remainingWaypoints = allWaypoints
          .map((wp) => LatLng(wp.lat, wp.lng))
          .toList();

      // ALWAYS route from PICKUP → DESTINATION so _fullPolyline contains the
      // complete road path. driverPosition is passed separately for progress/ETA.
      // Green line = breadcrumbs (actual GPS trail), NOT route split.
      // Blue line = remaining route from API (driver → destination on-road).
      final routeOrigin = _pickupLatLng!;

      // Detect if driver has essentially arrived at destination
      final bool driverAtDestination = _currentLatLng != null &&
          _destinationLatLng != null &&
          _haversineMeters(_currentLatLng!, _destinationLatLng!) < 30;

      debugPrint(
        '🗺️ Route params: origin=$routeOrigin (always pickup), '
        'driverPos=$_currentLatLng, atDest=$driverAtDestination, '
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
        final remainingPointsRoute =
            routeData['remaining_points'] as List<LatLng>? ?? [];
        _routeStops = routeData['stops'] as List<Map<String, dynamic>>? ?? [];
        _totalRouteDurationSeconds =
            routeData['total_duration_seconds'] as int? ?? 0;
        _fullPolyline = routeData['polyline_points'] as List<LatLng>? ?? [];
        _cumulativeDistances =
            (routeData['cumulative_distances'] as List?)?.cast<double>() ?? [];

        final remainingSeconds =
            routeData['remaining_duration_seconds'] as int? ?? 0;
        _remainingDurationSeconds = remainingSeconds;
        _remainingDurationSetAt = DateTime.now();

        // Route start time from driver's last update
        final driverLocData = _trackingData!.driverLocation;
        if (driverLocData.updatedAt != null && driverLocData.updatedAt!.isNotEmpty) {
          try {
            _routeStartTime = DateTime.parse(driverLocData.updatedAt!);
          } catch (_) {}
        }

        // ── WARM UP PIPELINE STATE FROM TIMELINE HISTORY ──
        // After a fresh load (screen reopen, app restart) all 7-gate
        // pipeline state is null/zero. The slice renderer would draw
        // from segment 0 even if the truck has been driving for an hour,
        // and the first few live snaps would be unstable because the
        // bearing/parallel/2-point gates have no history to compare
        // against — that's the "back and come zigzag" symptom.
        //
        // Fix: replay the backend's filtered timeline through the SAME
        // snap pipeline used by live updates. The backend already sorts
        // (oldest → newest) and already cleans (cluster collapse,
        // Douglas-Peucker), so it's a clean driving history feed.
        // After replay, _currentSegmentIndex / _lastAcceptedSnap /
        // _lastAcceptedRaw are correctly populated as if we'd been
        // running live the whole time.
        if (_fullPolyline.length >= 2) {
          if ((_trackingData?.timeline.isNotEmpty ?? false)) {
            _replayTimelineThroughPipeline();
          } else if (_currentLatLng != null) {
            _initializeSegmentIndex(_currentLatLng!);
          }
        }

        if (driverAtDestination) {
          // ── ARRIVED: driver is within 30m of destination ──
          // Show the ACTUAL DRIVEN path (server-snapped timeline) as the
          // completed line, NOT the planned _fullPolyline. The planned
          // polyline is what Google originally suggested at start-of-trip;
          // the timeline reflects every reroute / detour / U-turn the
          // driver actually drove. Falls back to _fullPolyline only when
          // the timeline isn't ready yet (very rare at arrival).
          // GREEN 'completed' breadcrumb line intentionally omitted —
          // replaced by the green dotted road-aligned home→vehicle polyline.
          _estimatedDuration = '';
        } else if (_currentLatLng != null) {
          // ── IN TRANSIT: green = breadcrumbs, blue = remaining route ──

          // Seed breadcrumbs along the planned road polyline so the
          // historical green line follows real roads, not a diagonal from
          // pickup straight to the truck through buildings.
          if (_driverBreadcrumbs.isEmpty) {
            _seedBreadcrumbsAlongPlannedRoute(_currentLatLng!);
            _lastBreadcrumbTime = DateTime.now();
          }

          // GREEN + BLUE: slice the master road polyline at the driver's
          // CURRENT SEGMENT and join with the exact snapped driver point.
          //
          // Why segment index instead of "closest vertex":
          //   `_getClosestPolylineIndex` returns the nearest VERTEX, which
          //   can land one vertex ahead of where the driver actually is on
          //   the segment. When that happens:
          //     green = [v0..vi+1] then snappedDriver (which sits between
          //     vi and vi+1) → last segment of green goes BACKWARD →
        //     visible kink/loop near the truck.
          //     blue likewise starts one vertex ahead of the driver →
          //     looks like a parallel duplicate line.
          //
          //   `_currentSegmentIndex` is maintained by `_snapToRoute` as the
          //   *segment start* index (the i in segment [vi, vi+1] that the
          //   driver is currently inside). It is forward-only, with a jump
          //   cap to reject single-point teleports. Using it directly as
          //   the split point guarantees:
          //     green = [v0..vi] + snappedDriver  (snappedDriver lies
          //             between vi and vi+1 → continuous, no backward kink)
          //     blue  = snappedDriver + [vi+1..vN]  (continuous, no gap)
          if (_fullPolyline.length >= 2) {
            // Ensure _currentSegmentIndex is fresh for the current driver
            // position before we read it. _snapToRoute applies the full
            // 7-gate pipeline; we still apply a render-side gap check
            // here as a final safety net.
            final snappedDriver = _snapToRoute(_currentLatLng!);

            // ── GAP PROTECTION (mode-aware) ──
            // If the new snap is far from the previously rendered snap,
            // hold the previous frame instead of drawing a long straight
            // shortcut. Thresholds match realistic per-poll movement at
            // the 200 km/h backend speed cap:
            //   city     130 m  (≈ 47 km/h × 10 s)
            //   suburban 350 m  (≈ 126 km/h × 10 s)
            //   highway  700 m  (≈ 252 km/h × 10 s — covers a 14 s drop
            //             at sustained 180 km/h, plus headroom)
            final double gapMax = _currentMode == 0
                ? 130
                : (_currentMode == 1 ? 350 : 700);
            final bool gapViolation = _lastRenderedSnap != null &&
                _haversineMeters(_lastRenderedSnap!, snappedDriver) > gapMax;
            if (gapViolation) {
              debugPrint('🚫 Gap protection: snap jumped >${gapMax.toStringAsFixed(0)}m, holding frame');
              polylines = Set<Polyline>.from(_polylines);
            } else {
              _lastRenderedSnap = snappedDriver;

              // GREEN 'completed' breadcrumb line intentionally omitted —
              // replaced by the green dotted road-aligned home→vehicle
              // polyline (no straight chords between sparse timeline points).

              final splitAt = _currentSegmentIndex
                  .clamp(0, _fullPolyline.length - 1);

              // Blue = driver position → end-of-current-segment → destination.
              final bluePoints = <LatLng>[
                snappedDriver,
                if (splitAt + 1 < _fullPolyline.length)
                  ..._fullPolyline.sublist(splitAt + 1),
              ];
              if (bluePoints.length >= 2) {
                polylines.add(
                  Polyline(
                    polylineId: const PolylineId('remaining'),
                    points: bluePoints,
                    color: const Color(0xFF1A73E8),
                    width: 5,
                    patterns: [PatternItem.dot, PatternItem.gap(10)],
                  ),
                );
              }
            }
          } else if (remainingPointsRoute.length >= 2) {
            // No full polyline yet — show whatever the API returned as blue.
            polylines.add(
              Polyline(
                polylineId: const PolylineId('remaining'),
                points: remainingPointsRoute,
                color: const Color(0xFF1A73E8),
                width: 5,
                patterns: [PatternItem.dot, PatternItem.gap(10)],
              ),
            );
          }

          _estimatedDuration = _formatDuration(remainingSeconds);
        } else if (_fullPolyline.length >= 2) {
          // No driver position — full route as solid blue
          _estimatedDuration = _formatDuration(remainingSeconds);
          polylines.add(
            Polyline(
              polylineId: const PolylineId('full_route'),
              points: _fullPolyline,
              color: const Color(0xFF1A73E8),
              width: 5,
              patterns: [PatternItem.dot, PatternItem.gap(10)],
            ),
          );
        }
      } else {
        // Directions API failed — never draw a straight chord between driver
        // and destination as a fallback. At long ranges that chord crosses
        // oceans/forests and misleads the customer; at short ranges it cuts
        // through buildings. Better to show nothing until the next successful
        // Directions call replaces the line.
        debugPrint('❌ Directions API failed — keeping previous polylines');
        if (_polylines.isNotEmpty) {
          polylines = Set<Polyline>.from(_polylines);
        }
      }
    }
    // ── ADDITIVE BRANCH: NO PICKUP PROVIDED ──
    // Admin never set a pickup location for this booking. Skip the
    // pickup→destination route entirely and just draw a blue line from
    // the driver's current position to the destination. No green line.
    // Existing functionality (above) is untouched — this branch only runs
    // when the existing condition fails.
    else if (_destinationLatLng != null && _currentLatLng != null) {
      debugPrint('🟦 No pickup provided — routing driver → destination only');
      final routeData = await GoogleMapsService.getRouteWithStops(
        origin: _currentLatLng!,
        destination: _destinationLatLng!,
      );
      if (routeData.isNotEmpty) {
        final pts = routeData['polyline_points'] as List<LatLng>? ?? [];
        final remainingSeconds =
            routeData['total_duration_seconds'] as int? ?? 0;
        if (pts.length >= 2) {
          polylines.add(
            Polyline(
              polylineId: const PolylineId('remaining'),
              points: pts,
              color: const Color(0xFF1A73E8),
              width: 5,
              patterns: [PatternItem.dot, PatternItem.gap(10)],
            ),
          );
        }
        _estimatedDuration = _formatDuration(remainingSeconds);
      }
    }

    // NOTE: a previous "additive post-step" used to overwrite the green
    // polyline here with a fresh Directions(pickup→driver) call. That was
    // wrong — Directions returns the road Google would *suggest*, not the
    // road the driver actually drove. After a reroute / U-turn / detour
    // the override snapped the green line back to the originally-planned
    // road, which is the bug customers reported as "green shows planned
    // path after I close and reopen tracking". The green polyline is now
    // built earlier in this method from `_trackingData.timeline`, which
    // is the server's road-snapped actual GPS history (see snap-on-read
    // in VehicleController) and correctly reflects every real reroute.

    // Calculate initial camera position to show full route
    _calculateInitialCameraPosition();

    // Green completed line: try Directions API first, fallback to polyline slice
    _buildGreenFromPolyline();
    unawaited(_refreshHomeToVehicleRoute());

    // Merge green line into polylines set (don't overwrite it)
    final h2v = _buildHomeToVehiclePolyline();
    if (h2v != null) polylines.add(h2v);

    setState(() {
      _polylines = polylines;
      // NOTE: do NOT seed `_lastRouteRefreshAt` here. If we do, the
      // cooldown gate blocks the first reroute for `_rerouteCooldown`
      // seconds after setup — and if the customer opens the screen
      // mid-trip when the driver is already off-route, the first
      // deviation detected would be silently dropped. Let the first
      // actual reroute set the timestamp.
    });

    // ── FIXED TIMELINE: passed stops from DB (API) + upcoming generated client-side ──
    // Force rebuild if: no stops yet, or at destination with stale upcoming stops.
    final apiHasStops = (_trackingData?.passedStops ?? []).isNotEmpty;
    if (_fixedStopsGenerated && _fixedStops.isEmpty && apiHasStops) {
      _fixedStopsGenerated = false; // rebuild — API has stops but we don't
    }
    final bool atDest = _currentLatLng != null &&
        _destinationLatLng != null &&
        _haversineDistance(_currentLatLng!, _destinationLatLng!) < 500;
    if (atDest && _fixedStopsGenerated) {
      final hasUpcoming = _fixedStops.any((s) => s['api_time'] == null && s['passed_at'] == null);
      if (hasUpcoming) _fixedStopsGenerated = false;
    }
    if (!_fixedStopsGenerated && _pickupLatLng != null && _destinationLatLng != null) {
      await _buildFixedStopsFromPassedAndUpcoming();
      _fixedStopsGenerated = true;
    }
    if (_currentLatLng != null) _updateProgress(_currentLatLng!);
  }

  // ── Build _fixedStops from API passed_stops + client-generated upcoming ──
  // Phase 1: Show passed stops instantly (no async, no Google API)
  // Phase 2: Generate upcoming stops in background, merge silently
  Future<void> _buildFixedStopsFromPassedAndUpcoming() async {
    if (_pickupLatLng == null || _destinationLatLng == null) return;

    // 1. Passed stops from DB (permanent, actual times)
    // Filter out stops whose name is just a city/state from pickup or destination
    // address (e.g. "Hyderabad", "Telangana", "Andhra Pradesh").
    final pickupAddr = _trackingData?.pickup.name ?? '';
    final dropAddr = _trackingData?.drop.name ?? '';
    final Set<String> cityNames = {};
    for (final addr in [pickupAddr, dropAddr]) {
      for (final part in addr.split(',')) {
        final p = part.trim().toLowerCase();
        if (p.isNotEmpty) cityNames.add(p);
      }
    }
    // Also exclude common broad names
    cityNames.addAll(['india', 'in']);

    final passedFromApi = (_trackingData?.passedStops ?? [])
        .where((pt) {
          final name = (pt['name']?.toString() ?? '').toLowerCase().trim();
          if (name.isEmpty) return false;
          // Always filter destination name from passed stops
          final destFirst = dropAddr.split(',').first.trim().toLowerCase();
          if (name == destFirst) return false;
          // Filter city names for long routes only
          final totalKm = (_pickupLatLng != null && _destinationLatLng != null)
              ? _haversineDistance(_pickupLatLng!, _destinationLatLng!) / 1000 : 999.0;
          if (totalKm >= 10 && cityNames.contains(name)) return false;
          return true;
        })
        .map((pt) {
      return <String, dynamic>{
        'name': pt['name']?.toString() ?? 'Stop',
        'lat': (pt['lat'] as num?)?.toDouble() ?? 0.0,
        'lng': (pt['lng'] as num?)?.toDouble() ?? 0.0,
        'dist_fraction': 0.0,
        'api_order': (pt['order'] as num?)?.toInt() ?? 0,
        'passed_at': pt['passed_at']?.toString(),
        // Store raw API time/date for direct display (avoids re-parsing)
        'api_time': pt['time']?.toString(),
        'api_date': pt['date']?.toString(),
        'is_key_stop': false,
      };
    }).toList();

    // 1b. Route waypoints (key delivery stops — e.g. Secunderabad via booking 829)
    // Skip if: same as destination, or already in passed stops (by name or proximity).
    final passedNames = passedFromApi.map((s) => (s['name'] as String).toLowerCase()).toSet();
    final waypointStops = (_trackingData?.routeWaypoints ?? [])
        .where((wp) {
          if (wp.lat == 0 || wp.lng == 0) return false;
          // Skip if same location as destination (within 500m)
          if (_destinationLatLng != null &&
              _haversineDistance(LatLng(wp.lat, wp.lng), _destinationLatLng!) < 500) return false;
          // Skip only if exact name match with a passed stop
          final wpName = wp.name.split(',').first.trim().toLowerCase();
          if (passedNames.contains(wpName)) return false;
          return true;
        })
        .map((wp) {
      // If driver already crossed this waypoint, mark as passed
      bool crossed = false;
      if (_currentLatLng != null && _pickupLatLng != null) {
        final driverDist = _haversineDistance(_pickupLatLng!, _currentLatLng!);
        final wpDist = _haversineDistance(_pickupLatLng!, LatLng(wp.lat, wp.lng));
        crossed = driverDist > wpDist + 500;
      }
      return <String, dynamic>{
        'name': wp.name.isNotEmpty ? wp.name.split(',').first.trim() : 'Stop',
        'lat': wp.lat,
        'lng': wp.lng,
        'dist_fraction': 0.0,
        'is_key_stop': true,
        if (crossed) 'api_time': _formatDateTimeObj(DateTime.now()),
        if (crossed) 'passed_at': DateTime.now().toIso8601String(),
      };
    }).toList();

    // ── PHASE 1: Show passed stops + waypoints IMMEDIATELY ──
    // Use haversine fraction (instant, no API needed) so user sees data right away
    if (passedFromApi.isNotEmpty || waypointStops.isNotEmpty) {
      final straightDist = _haversineDistance(_pickupLatLng!, _destinationLatLng!);
      if (straightDist > 0) {
        for (final stop in [...passedFromApi, ...waypointStops]) {
          final sLat = stop['lat'] as double;
          final sLng = stop['lng'] as double;
          stop['dist_fraction'] = (_haversineDistance(_pickupLatLng!, LatLng(sLat, sLng)) / straightDist).clamp(0.0, 1.0);
        }
      }
      // Passed in API order, waypoints after
      passedFromApi.sort((a, b) => ((a['api_order'] as int?) ?? 0).compareTo((b['api_order'] as int?) ?? 0));
      final phase1Stops = [...passedFromApi, ...waypointStops];
      if (mounted) {
        setState(() {
          _fixedStops = phase1Stops;
          _isLoadingFixedStops = false;
        });
      }
    }

    // ── PHASE 2: Fetch polyline + generate upcoming (async, silent) ──
    await _fetchFullRoutePolyline();

    // Rebuild green line now that _fullRoutePolyline has all waypoints
    _buildGreenFromPolyline();

    // Assign dist_fraction to passed stops + waypoint stops
    final allStopsToFraction = [...passedFromApi, ...waypointStops];
    if (_fullRoutePolyline.isNotEmpty && _fullRouteCumulativeDistances.isNotEmpty) {
      // Polyline available — use projection for accurate fraction
      final totalDist = _fullRouteCumulativeDistances.last;
      for (final stop in allStopsToFraction) {
        final sLat = stop['lat'] as double;
        final sLng = stop['lng'] as double;
        double minD = double.infinity;
        int bestIdx = 0;
        for (int i = 0; i < _fullRoutePolyline.length; i++) {
          final d = _haversineDistance(LatLng(sLat, sLng), _fullRoutePolyline[i]);
          if (d < minD) { minD = d; bestIdx = i; }
        }
        stop['dist_fraction'] = totalDist > 0
            ? _fullRouteCumulativeDistances[bestIdx] / totalDist
            : 0.0;
      }
    } else if (_pickupLatLng != null && _destinationLatLng != null) {
      // Fallback: use haversine distance ratio (pickup → stop / pickup → dest)
      final totalDist = _haversineDistance(_pickupLatLng!, _destinationLatLng!);
      if (totalDist > 0) {
        for (final stop in allStopsToFraction) {
          final sLat = stop['lat'] as double;
          final sLng = stop['lng'] as double;
          final stopDist = _haversineDistance(_pickupLatLng!, LatLng(sLat, sLng));
          stop['dist_fraction'] = (stopDist / totalDist).clamp(0.0, 1.0);
        }
      }
    }

    // 3. Generate upcoming stops client-side for the route portion NOT covered
    //    by API passed stops. Uses last passed stop (or pickup) as origin so
    //    that stops always fill the gap to destination — even if driver has arrived.
    final driverPos = _currentLatLng ?? _pickupLatLng!;

    // Use last API passed stop as origin for upcoming stops generation.
    // This fills the gap between the last confirmed stop and destination,
    // even if the driver has already arrived at destination.
    LatLng upcomingOrigin = driverPos;
    if (passedFromApi.isNotEmpty) {
      final lastPassed = passedFromApi.last;
      final lpLat = lastPassed['lat'] as double;
      final lpLng = lastPassed['lng'] as double;
      upcomingOrigin = LatLng(lpLat, lpLng);
    }

    List<Map<String, dynamic>> upcomingStops = [];
    {
      final remainingKm = _haversineDistance(upcomingOrigin, _destinationLatLng!) / 1000;
      final polyTotalDistKm = _fullRouteCumulativeDistances.isNotEmpty
          ? _fullRouteCumulativeDistances.last / 1000
          : 0.0;
      final effectiveRemainingKm = remainingKm > 1
          ? remainingKm
          : (polyTotalDistKm > 0 ? polyTotalDistKm : 1.0);

      // Generate if there's meaningful distance left (>1km from origin to dest)
      if (remainingKm > 1) {
        // Build ordered mandatory waypoints still ahead of the origin
        final List<LatLng> mandatoryWaypoints = [];
        final unvisitedWaypoints = (_trackingData?.routeWaypoints ?? [])
            .where((wp) => wp.lat != 0 && wp.lng != 0 && !wp.isCompleted)
            .toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));
        for (final wp in unvisitedWaypoints) {
          // Only include waypoints that are ahead of the origin
          final wpDistFromPickup = _haversineDistance(_pickupLatLng!, LatLng(wp.lat, wp.lng));
          final originDistFromPickup = _haversineDistance(_pickupLatLng!, upcomingOrigin);
          if (wpDistFromPickup > originDistFromPickup) {
            mandatoryWaypoints.add(LatLng(wp.lat, wp.lng));
          }
        }
        debugPrint('🛣️ [STOPS] Route: origin(${upcomingOrigin.latitude.toStringAsFixed(2)},${upcomingOrigin.longitude.toStringAsFixed(2)}) → ${mandatoryWaypoints.length} waypoints → destination');

        upcomingStops = await TrackingStopsService.generateUpcomingStops(
          driverPosition: upcomingOrigin,
          destination: _destinationLatLng!,
          remainingDistanceKm: effectiveRemainingKm,
          waypoints: mandatoryWaypoints,
        );
      }
    }

    // Fallback 1: if no stops, generate from straight-line midpoints + geocode
    if (upcomingStops.isEmpty && _pickupLatLng != null && _destinationLatLng != null) {
      final distKm = _haversineDistance(upcomingOrigin, _destinationLatLng!) / 1000;
      final stopCount = TrackingStopsService.recommendedStopCount(distKm);
      // For short routes (<10km), skip city name filter because the whole
      // route is within the same city — filtering removes all results.
      final bool skipCityFilter = distKm < 10;
      if (stopCount > 0 && distKm > 0.5) {
        final oLat = upcomingOrigin.latitude;
        final oLng = upcomingOrigin.longitude;
        final dLat = _destinationLatLng!.latitude;
        final dLng = _destinationLatLng!.longitude;
        for (int s = 1; s <= stopCount; s++) {
          final frac = s / (stopCount + 1);
          final lat = oLat + (dLat - oLat) * frac;
          final lng = oLng + (dLng - oLng) * frac;
          final name = await GoogleMapsService.reverseGeocode(
            LatLng(lat, lng), routeDistanceKm: distKm);
          // Always filter pickup address parts even on short routes
          final pickupParts = pickupAddr.split(',').map((p) => p.trim().toLowerCase()).where((p) => p.isNotEmpty).toSet();
          final nameLower = (name ?? '').toLowerCase().trim();
          if (name != null && name.isNotEmpty &&
              !pickupParts.contains(nameLower) &&
              (skipCityFilter || !cityNames.contains(nameLower))) {
            upcomingStops.add({
              'name': name,
              'lat': lat,
              'lng': lng,
              'status': 'upcoming',
            });
          }
        }
        debugPrint('🛣️ [STOPS] Midpoint fallback: ${upcomingStops.length} stops (skipCityFilter=$skipCityFilter)');
      }
    }

    // Fallback 2: if Google API failed, sample stops from cached polyline.
    if (upcomingStops.isEmpty && _fullRoutePolyline.length >= 2) {
      final fallbackRemainingKm = _haversineDistance(upcomingOrigin, _destinationLatLng!) / 1000;
      if (fallbackRemainingKm > 1) {
        final polyTotalDist = _fullRouteCumulativeDistances.isNotEmpty
            ? _fullRouteCumulativeDistances.last
            : 0.0;
        final stopCount = TrackingStopsService.recommendedStopCount(fallbackRemainingKm);
        if (stopCount > 0 && polyTotalDist > 0) {
          final interval = polyTotalDist / (stopCount + 1);
          final List<LatLng> candidatePts = [];
          for (int s = 1; s <= stopCount; s++) {
            final targetDist = interval * s;
            int idx = 0;
            for (int j = 1; j < _fullRouteCumulativeDistances.length; j++) {
              if (_fullRouteCumulativeDistances[j] >= targetDist) { idx = j; break; }
            }
            candidatePts.add(_fullRoutePolyline[idx]);
          }
          // Reverse-geocode in parallel using distance-aware strategy
          final names = await Future.wait(
            candidatePts.map((pt) => GoogleMapsService.reverseGeocode(
                pt, routeDistanceKm: fallbackRemainingKm)),
          );
          for (int s = 0; s < candidatePts.length; s++) {
            final name = names[s] ?? 'Stop ${s + 1}';
            upcomingStops.add({
              'name': name,
              'lat': candidatePts[s].latitude,
              'lng': candidatePts[s].longitude,
              'status': 'upcoming',
            });
          }
          debugPrint('🛣️ [STOPS] Fallback: ${upcomingStops.length} stops from polyline with geocoding');
        }
      }
    }

    // Convert upcoming stops to _fixedStops format with dist_fraction
    final totalDist = _fullRouteCumulativeDistances.isNotEmpty
        ? _fullRouteCumulativeDistances.last
        : 0.0;
    final upcomingMapped = upcomingStops.map((s) {
      final sLat = (s['lat'] as num?)?.toDouble() ?? 0.0;
      final sLng = (s['lng'] as num?)?.toDouble() ?? 0.0;
      double fraction = 0.0;
      if (_fullRoutePolyline.isNotEmpty && totalDist > 0) {
        double minD = double.infinity;
        int bestIdx = 0;
        for (int i = 0; i < _fullRoutePolyline.length; i++) {
          final d = _haversineDistance(LatLng(sLat, sLng), _fullRoutePolyline[i]);
          if (d < minD) { minD = d; bestIdx = i; }
        }
        fraction = _fullRouteCumulativeDistances[bestIdx] / totalDist;
      }
      return <String, dynamic>{
        'name': s['name']?.toString() ?? 'Stop',
        'lat': sLat,
        'lng': sLng,
        'dist_fraction': fraction,
        'is_key_stop': false,
        // No passed_at — this is upcoming
      };
    }).toList();

    // 4. Merge: passed (from DB) + waypoints (key stops) + upcoming (client-generated)
    // For short routes (<10km), skip city name filter — entire route is in same area
    final totalRouteKm = (_pickupLatLng != null && _destinationLatLng != null)
        ? _haversineDistance(_pickupLatLng!, _destinationLatLng!) / 1000
        : 999.0;
    final bool shortRoute = totalRouteKm < 10;
    final fixedStopList = [...passedFromApi, ...waypointStops];
    final fixedNames = fixedStopList.map((s) => (s['name'] as String).toLowerCase()).toSet();
    final filtered = upcomingMapped.where((s) {
      final name = (s['name'] as String).toLowerCase();
      if (fixedNames.contains(name)) return false;
      // Always filter pickup address parts (even on short routes)
      // Only skip drop address filter for short routes
      final pickupParts = <String>{};
      for (final part in (pickupAddr).split(',')) {
        final p = part.trim().toLowerCase();
        if (p.isNotEmpty) pickupParts.add(p);
      }
      if (pickupParts.contains(name)) return false;
      if (!shortRoute && cityNames.contains(name)) return false;
      // Filter by proximity — drop if within 500m of any fixed stop
      final sLat = s['lat'] as double;
      final sLng = s['lng'] as double;
      for (final p in fixedStopList) {
        final d = _haversineDistance(LatLng(sLat, sLng), LatLng(p['lat'] as double, p['lng'] as double));
        if (d < 500) return false;
      }
      // Filter client-generated stops too close to destination (within 2km)
      // Waypoints (admin-set) are never filtered — they represent priority bookings
      if (_destinationLatLng != null && _haversineDistance(LatLng(sLat, sLng), _destinationLatLng!) < 2000) return false;
      return true;
    }).toList();

    // Also filter duplicate waypoints against each other (by proximity)
    final deduplicatedWaypoints = <Map<String, dynamic>>[];
    for (final wp in waypointStops) {
      final wpLat = wp['lat'] as double;
      final wpLng = wp['lng'] as double;
      bool dupOfPassed = false;
      for (final p in passedFromApi) {
        final d = _haversineDistance(LatLng(wpLat, wpLng), LatLng(p['lat'] as double, p['lng'] as double));
        if (d < 500) { dupOfPassed = true; break; }
      }
      if (!dupOfPassed) deduplicatedWaypoints.add(wp);
    }

    // Deduplicate upcoming stops against each other (geocoding spelling variants)
    final deduplicatedUpcoming = <Map<String, dynamic>>[];
    for (final s in filtered) {
      final sLat = s['lat'] as double;
      final sLng = s['lng'] as double;
      bool tooClose = false;
      for (final existing in deduplicatedUpcoming) {
        final d = _haversineDistance(LatLng(sLat, sLng), LatLng(existing['lat'] as double, existing['lng'] as double));
        if (d < 500) { tooClose = true; break; }
      }
      if (!tooClose) deduplicatedUpcoming.add(s);
    }

    // Sort passed stops by API order (fixed), upcoming by dist_fraction
    passedFromApi.sort((a, b) => ((a['api_order'] as int?) ?? 0).compareTo((b['api_order'] as int?) ?? 0));
    deduplicatedUpcoming.sort((a, b) => (a['dist_fraction'] as double).compareTo(b['dist_fraction'] as double));
    // Passed first (in API order), then waypoints, then upcoming (by fraction)
    final allStops = [...passedFromApi, ...deduplicatedWaypoints, ...deduplicatedUpcoming];

    _enforceMonotonicPassedAt(allStops);

    if (mounted) {
      setState(() {
        _fixedStops = allStops;
        _isLoadingFixedStops = false;
      });
    }
    debugPrint('🗺️ [FIXED-STOPS] ${passedFromApi.length} passed (DB) + ${deduplicatedWaypoints.length} waypoints + ${deduplicatedUpcoming.length} upcoming (client) = ${allStops.length} total');
    if (_currentLatLng != null) _updateProgress(_currentLatLng!);
  }

  // ── Sync passed stops from API into _fixedStops on each poll ──


  bool _shouldRefreshRoute({bool forceRefresh = false}) {
    if (forceRefresh) return true;
    if (_lastRouteRefreshAt == null) return true;
    return DateTime.now().difference(_lastRouteRefreshAt!) >= _rerouteCooldown;
  }

  /// Lightweight reroute: fetch new route from DRIVER → DESTINATION,
  /// update ONLY the blue polyline. NEVER touches green breadcrumbs.
  /// Called when driver deviates from the suggested route.
  Future<void> _rerouteFromDriverPosition() async {
    if (_currentLatLng == null || _destinationLatLng == null) return;

    debugPrint('🔄 Rerouting from driver position...');

    final remainingWaypoints = (_trackingData?.routeWaypoints ?? [])
        .where((wp) => wp.lat != 0 && wp.lng != 0 && !wp.isCompleted)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final wpLatLngs = remainingWaypoints
        .map((wp) => LatLng(wp.lat, wp.lng))
        .toList();

    final routeData = await GoogleMapsService.getRouteWithStops(
      origin: _currentLatLng!,
      destination: _destinationLatLng!,
      routeWaypoints: wpLatLngs,
    );

    if (routeData.isEmpty) {
      debugPrint('❌ Reroute API failed — keeping current blue');
      return;
    }

    // Update route data for new path
    _fullPolyline = routeData['polyline_points'] as List<LatLng>? ?? [];
    _cumulativeDistances =
        (routeData['cumulative_distances'] as List?)?.cast<double>() ?? [];
    _totalRouteDurationSeconds =
        routeData['total_duration_seconds'] as int? ?? 0;
    // Reroute origin = current driver position, so the entire new
    // duration IS the remaining duration.
    _remainingDurationSeconds = _totalRouteDurationSeconds;
    _remainingDurationSetAt = DateTime.now();

    // Reset segment index AND snap pipeline state for the new route
    // geometry — bearing/parallel references no longer apply.
    _currentSegmentIndex = 0;
    _lastAcceptedSnap = null;
    _lastAcceptedRaw = null;
    _lastRenderedSnap = null;
    _snapCacheInput = null;
    _snapCacheOutput = null;
    if (_currentLatLng != null && _fullPolyline.length >= 2) {
      _initializeSegmentIndex(_currentLatLng!);
    }

    // Update ETA (entire new route = remaining time)
    _estimatedDuration = _formatDuration(_totalRouteDurationSeconds);

    // Replace ONLY blue polyline — keep green (home_to_vehicle) visible
    final updatedPolylines = _polylines
        .where((p) => p.polylineId.value != 'remaining')
        .toSet();

    if (_fullPolyline.length >= 2) {
      updatedPolylines.add(
        Polyline(
          polylineId: const PolylineId('remaining'),
          points: List<LatLng>.from(_fullPolyline),
          color: const Color(0xFF1A73E8),
          width: 5,
          patterns: [PatternItem.dot, PatternItem.gap(10)],
        ),
      );
    }

    // Refresh green line in background — existing one stays visible
    unawaited(_refreshHomeToVehicleRoute());

    if (mounted) {
      setState(() {
        _polylines = updatedPolylines;
        _lastRouteRefreshAt = DateTime.now();
      });
    }

    // Regenerate timeline stops from the new rerouted polyline so the
    // location list reflects the actual path the driver is now taking.
    await _regenerateFixedStopsFromPolyline(_fullPolyline, _totalRouteDurationSeconds);

    debugPrint('✅ Rerouted: ${_fullPolyline.length} points, ETA=$_estimatedDuration');
  }

  /// Updates polylines on each live position update:
  ///   - Green solid: actual GPS breadcrumbs (real path the driver drove)
  ///   - Blue dashed: remaining route from driver → destination (split from _fullPolyline)
  void _refreshCompletedPolylineFromTimeline() {
    if (_currentLatLng == null) return;

    // Check if driver arrived at destination — lock completed state
    if (_destinationLatLng != null &&
        _haversineMeters(_currentLatLng!, _destinationLatLng!) < 30) {
      // ARRIVED: lock the green line to the ACTUAL driven path (server-
      // snapped timeline) rather than the planned _fullPolyline so the
      // final view reflects every reroute / U-turn the driver actually
      // took, not the original Google suggestion.
      // Arrived: drop the in-flight 'completed' / 'remaining' / dotted
      // green lines. The 'completed' breadcrumb polyline is intentionally
      // not redrawn — replaced by the green dotted home→vehicle polyline.
      // Arrived: keep green line (home_to_vehicle), remove blue route lines
      final arrivedPolylines = _polylines
          .where((p) =>
              p.polylineId.value != 'completed' &&
              p.polylineId.value != 'remaining')
          .toSet();
      if (mounted) setState(() => _polylines = arrivedPolylines);
      return;
    }

    // Keep home_to_vehicle (green line) — only remove completed/remaining for rebuild
    final updatedPolylines = _polylines
        .where((p) =>
            p.polylineId.value != 'completed' &&
            p.polylineId.value != 'remaining')
        .toSet();

    // Refresh green line in background — existing one stays visible until replaced
    unawaited(_refreshHomeToVehicleRoute());

    // GREEN + BLUE: slice the master polyline at _currentSegmentIndex
    // (segment START, not nearest vertex). _snapToRoute applies the full
    // 7-gate pipeline; we still apply a render-side gap check here as a
    // final safety net (mode-aware).
    if (_fullPolyline.length >= 2) {
      final snappedPos = _snapToRoute(_currentLatLng!);

      // ── GAP PROTECTION (mode-aware) ──
      // Hold the segment-slice frame when the snap jumps further than the
      // per-mode threshold (avoids drawing a long shortcut chord). BUT
      // always advance `_lastRenderedSnap` to the new snap before bailing,
      // otherwise the comparison anchor stays frozen at the OLD position
      // and every subsequent poll re-fires the same gap check, leaving
      // the green line stuck behind the truck until the user hot-reloads.
      final double gapMax = _currentMode == 0
          ? 130
          : (_currentMode == 1 ? 350 : 700);
      final bool gapHold = _lastRenderedSnap != null &&
          _haversineMeters(_lastRenderedSnap!, snappedPos) > gapMax;
      _lastRenderedSnap = snappedPos;
      if (gapHold) {
        debugPrint('🚫 Gap protection (live): snap jumped >${gapMax.toStringAsFixed(0)}m, '
            'holding frame — segment slice will resume next poll');
        return;
      }

      // GREEN 'completed' breadcrumb line intentionally omitted —
      // replaced by the green dotted road-aligned home→vehicle polyline.

      final splitAt = _currentSegmentIndex
          .clamp(0, _fullPolyline.length - 1);

      final bluePoints = <LatLng>[
        snappedPos,
        if (splitAt + 1 < _fullPolyline.length)
          ..._fullPolyline.sublist(splitAt + 1),
      ];
      if (bluePoints.length >= 2) {
        updatedPolylines.add(
          Polyline(
            polylineId: const PolylineId('remaining'),
            points: bluePoints,
            color: const Color(0xFF1A73E8),
            width: 5,
            patterns: [PatternItem.dot, PatternItem.gap(10)],
          ),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _polylines = updatedPolylines;
    });

    // NOTE: The live `_maybeRefreshLiveGreenFromDirections` override used
    // to fire here. It was added back when `_currentSegmentIndex` would
    // get stuck and stop advancing — the override re-fetched a fresh
    // pickup→driver Directions polyline so the green line could keep
    // growing. After the gap-protection latching fix, the segment-slice
    // path advances reliably on every poll, so the override is no longer
    // needed AND it was causing the green line to visibly flicker
    // because the segment-slice (built from `_fullPolyline`) and the
    // override (built from a fresh API call) produced slightly different
    // geometries that swapped on each poll. Removed.
  }

  // Cubic ease-in-out for smooth acceleration/deceleration
  double _easeInOutCubic(double t) {
    return t < 0.5 ? 4 * t * t * t : 1 - ((-2 * t + 2) * (-2 * t + 2) * (-2 * t + 2)) / 2;
  }

  void _animateVehicleMarker(LatLng from, LatLng to) {
    _markerAnimationTimer?.cancel();
    _lastVehicleMarkerLatLng = from;

    if (_haversineMeters(from, to) < 2) {
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

      // Smooth position interpolation with easing, snapped to route
      final interpolated = LatLng(
        from.latitude + (to.latitude - from.latitude) * easedT,
        from.longitude + (to.longitude - from.longitude) * easedT,
      );
      _currentLatLng = _snapToRoute(interpolated);

      // Smooth bearing interpolation (shortest rotation path)
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
        // NOT on every step — that overwhelms tile loader and causes blank map.
        if (_isFollowingVehicle) {
          _animateCameraToVehicle();
        } else {
          // Edge-detection safety net: if the user disabled follow mode but
          // the truck is about to leave the viewport, nudge the camera once
          // so the marker can never silently drift off-screen.
          _ensureVehicleVisible();
        }
      }
    });
  }

  /// Re-arm the auto-resume timer every time the user touches the map.
  /// After `_followAutoResumeDelay` of no further interaction, follow mode
  /// turns back on and the camera snaps to the truck on the next poll.
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
  /// flipped on — we only nudge the camera once. Called from the live-poll
  /// path after every accepted position update.
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

      // Truck just crossed out of the viewport. Pan once (no zoom / tilt
      // change) so the user's manual zoom level is preserved.
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

  /// Animate camera to follow vehicle with bearing rotation and tilt.
  /// Adjusts zoom based on stable mode: tighter in city, wider on highway.
  /// Only called when _isFollowingVehicle is true (user hasn't dragged map).
  void _animateCameraToVehicle() {
    if (_currentLatLng == null) return;

    final controller = _isMapExpanded ? _expandedMapController : _smallMapController;
    if (controller == null) return;

    // Dynamic zoom based on stable mode (not raw speed — avoids flickering)
    final double zoom;
    switch (_currentMode) {
      case 2: zoom = 14.5; break;  // highway — wide view
      case 1: zoom = 15.5; break;  // suburban
      default: zoom = _followZoom;  // city — close
    }

    try {
      _isProgrammaticCameraMove = true;
      controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _currentLatLng!,
            zoom: zoom,
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

  /// Update speed estimate from GPS positions. Called every poll.
  /// Uses exponential smoothing + stable mode switching (no flickering).
  void _updateSpeedEstimate(LatLng newPos) {
    final now = DateTime.now();
    if (_lastSpeedCalcPos != null && _lastSpeedCalcTime != null) {
      final elapsed = now.difference(_lastSpeedCalcTime!).inSeconds;
      if (elapsed > 0) {
        final dist = _haversineMeters(_lastSpeedCalcPos!, newPos);
        final instantSpeed = (dist / elapsed) * 3.6; // km/h
        // Exponential smoothing (α=0.3): prevents single GPS spike from flipping mode
        _estimatedSpeedKmh = _estimatedSpeedKmh * 0.7 + instantSpeed * 0.3;
      }
    }
    _lastSpeedCalcPos = newPos;
    _lastSpeedCalcTime = now;

    // Stable mode switching: only change after 3 consecutive polls agree.
    // Prevents flickering (e.g., traffic jam on highway → don't switch to city).
    final int targetMode;
    if (_estimatedSpeedKmh >= 60) {
      targetMode = 2; // highway
    } else if (_estimatedSpeedKmh >= 25) {
      targetMode = 1; // suburban
    } else {
      targetMode = 0; // city
    }

    if (targetMode != _currentMode) {
      if (targetMode == _pendingMode) {
        _pendingModeCount++;
        if (_pendingModeCount >= _modeChangeThreshold) {
          _currentMode = targetMode;
          _pendingModeCount = 0;
          debugPrint('🚦 Mode switched to ${['city', 'suburban', 'highway'][_currentMode]} '
              '(speed=${_estimatedSpeedKmh.toStringAsFixed(0)}km/h)');
        }
      } else {
        _pendingMode = targetMode;
        _pendingModeCount = 1;
      }
    } else {
      // Already in correct mode — reset pending
      _pendingModeCount = 0;
    }
  }

  /// Dynamic snap threshold based on stable mode (not raw speed).
  /// Tightened per the 7-gate pipeline tuning:
  ///   city     25 m  (urban GPS noise floor + small margin)
  ///   suburban 40 m
  ///   highway  60 m  (sparse polyline + faster movement)
  double get _snapThreshold {
    switch (_currentMode) {
      case 2: return 60;  // highway
      case 1: return 40;  // suburban
      default: return 25; // city
    }
  }

  /// Dynamic reroute threshold based on stable mode. Aggressive across
  /// every mode — the user wants new blue polylines to appear as soon
  /// as the driver physically leaves the planned road, regardless of
  /// whether it's a narrow city lane or a highway exit.
  double get _rerouteThreshold {
    switch (_currentMode) {
      case 2: return 150;  // highway (was 250)
      case 1: return 120;  // suburban (was 150)
      default: return _polylineRerouteThresholdMeters; // 100 m city (was the same)
    }
  }

  /// Dynamic breadcrumb min distance based on stable mode.
  /// City = 20m (GPS noise in Indian cities is 10-30m, must be above noise floor).
  /// Suburban = 30m, Highway = 50m.
  double get _breadcrumbMinDistance {
    switch (_currentMode) {
      case 2: return 50;  // highway
      case 1: return 30;  // suburban
      default: return 20; // city (GPS noise range = 10-30m)
    }
  }

  /// Dynamic segment search window based on stable mode.
  int get _segmentSearchWindow {
    switch (_currentMode) {
      case 2: return 50;  // highway
      case 1: return 20;  // suburban
      default: return 10; // city
    }
  }

  /// Haversine distance in meters between two LatLng points.
  double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * R * asin(sqrt(h));
  }

  /// Returns the minimum distance (meters) from [point] to the current
  /// polyline, measured against each SEGMENT (not just each vertex).
  ///
  /// The vertex-only version was producing false positives on long, sparse
  /// curves: a driver perfectly on the road but between two distant
  /// vertices could measure ~100 m to the nearest vertex even though they
  /// were ~5 m from the actual road. That triggered unnecessary reroutes
  /// in curves. Projecting onto each segment (`_projectOntoSegment`)
  /// returns the true perpendicular distance to the line, which is what
  /// the deviation check actually wants.
  double _minDistanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return double.infinity;
    if (polyline.length == 1) return _haversineMeters(point, polyline.first);

    double minDist = double.infinity;
    for (int i = 0; i < polyline.length - 1; i++) {
      final projected = _projectOntoSegment(point, polyline[i], polyline[i + 1]);
      final d = _haversineMeters(point, projected);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  /// Seed breadcrumbs when the screen opens mid-trip and the buffer is
  /// still empty. We can't recover the *actual* path the driver drove
  /// before the screen was open (the only record is the API timeline,
  /// which is raw GPS — drawing it produces building-cuts), so we instead
  /// seed with the road-snapped slice of [_fullPolyline] from start to
  /// the driver's current segment. The line follows real roads even if
  /// it doesn't reflect a pre-screen detour. Live updates after this
  /// point come from real breadcrumbs and DO show actual detours/U-turns.
  void _seedBreadcrumbsAlongPlannedRoute(LatLng currentPos) {
    _driverBreadcrumbs.clear();
    if (_pickupLatLng != null) {
      _driverBreadcrumbs.add(_pickupLatLng!);
    }
    // _snapToRoute updates _currentSegmentIndex as a side effect, so the
    // slice below is anchored to where the driver actually is on the route.
    final snapped = _snapToRoute(currentPos);
    if (_fullPolyline.length >= 2) {
      final splitAt = _currentSegmentIndex.clamp(0, _fullPolyline.length - 1);
      if (splitAt >= 1) {
        _driverBreadcrumbs.addAll(_fullPolyline.sublist(0, splitAt + 1));
      }
    }
    _driverBreadcrumbs.add(snapped);
  }

  /// Downsample breadcrumbs to prevent memory/render issues on long trips.
  /// Keeps the oldest half at 1/3 density, preserves the recent half in full detail.
  void _downsampleBreadcrumbs() {
    final total = _driverBreadcrumbs.length;
    final halfIdx = total ~/ 2;

    // Keep every 3rd point in the older half, but ALWAYS keep turning points
    final older = <LatLng>[];
    for (int i = 0; i < halfIdx; i++) {
      if (i % 3 == 0) {
        older.add(_driverBreadcrumbs[i]);
      } else if (i >= 1 && i < halfIdx - 1) {
        // Check if this is a turning point — preserve curve shape
        final prev = _driverBreadcrumbs[i - 1];
        final curr = _driverBreadcrumbs[i];
        final next = _driverBreadcrumbs[i + 1];
        final b1 = _getBearing(prev, curr);
        final b2 = _getBearing(curr, next);
        var diff = (b2 - b1).abs();
        if (diff > 180) diff = 360 - diff;
        if (diff > 25) older.add(curr); // turning point — keep it
      }
    }

    // Keep all points in the recent half
    final recent = _driverBreadcrumbs.sublist(halfIdx);

    _driverBreadcrumbs = [...older, ...recent];
  }

  /// Project point P onto line segment A→B, returning the closest point on AB.
  LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.latitude - a.latitude;
    final dy = b.longitude - a.longitude;
    if (dx == 0 && dy == 0) return a;
    var t = ((p.latitude - a.latitude) * dx + (p.longitude - a.longitude) * dy) /
        (dx * dx + dy * dy);
    t = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + t * dx, a.longitude + t * dy);
  }

  /// Segment-based route snapping.
  /// Only searches nearby segments (forward from current position) instead of
  /// the entire polyline. This prevents jumping backward or cutting across turns.
  /// Updates [_currentSegmentIndex] as the vehicle progresses.
  LatLng _snapToRoute(LatLng raw) {
    if (_fullPolyline.length < 2) return raw;

    // ── IDEMPOTENCY CACHE ──
    // Same raw input within a single render frame → return the cached
    // output without re-running the pipeline. Prevents marker/polyline
    // desync caused by Gate 5 (2-point stability) confirming on the
    // second call within the same frame.
    if (_snapCacheInput != null && _snapCacheOutput != null) {
      if ((_snapCacheInput!.latitude - raw.latitude).abs() < 1e-7 &&
          (_snapCacheInput!.longitude - raw.longitude).abs() < 1e-7) {
        return _snapCacheOutput!;
      }
    }

    // Use centralized speed-based threshold (city: 30m, suburban: 50m, highway: 80m)
    final threshold = _snapThreshold;

    // Dynamic search window based on speed (city: +10, highway: +50)
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

    // If no good match, widen forward window (but NEVER search entire route
    // — that causes random jumps to future segments or wrong roads)
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

    // ─────────────────────────────────────────────────────────────────
    //                      7-GATE SNAP PIPELINE
    //
    //   0. Stop filter
    //   1. Snap-quality (hard threshold, no fallback)
    //   2. Bearing/direction agreement
    //   3. Parallel-road sideways filter
    //   4. Segment continuity (forward-only with U-turn allowance)
    //   5. 2-point stability confirmation for big jumps
    //   ↓ accept → commit segment + snap state
    //
    // Mode-aware thresholds (city / suburban / highway):
    //   snap            25 / 40 / 60  m   (in _snapThreshold)
    //   max forward seg  3 /  8 / 12
    //   max backward seg                3 (U-turn allowance, all modes)
    //   bearing reject  75 / 90 / 110 °
    //   parallel raw   <30 m and snap >80 m → reject
    // ─────────────────────────────────────────────────────────────────

    // ── GATE 0: Stop filter ──
    // If the truck is confirmed stationary, hold the previous position.
    // Prevents drift-while-parked from advancing the segment index or
    // committing breadcrumb noise.
    if (!_driverIsMoving) {
      final hold = _lastAcceptedSnap
          ?? (_driverBreadcrumbs.isNotEmpty ? _driverBreadcrumbs.last : raw);
      _snapCacheInput = raw;
      _snapCacheOutput = hold;
      return hold;
    }

    // ── GATE 1: Snap quality (hard threshold, no raw fallback) ──
    if (minDist > threshold) {
      debugPrint('🚫 Snap quality fail: ${minDist.toStringAsFixed(0)}m > ${threshold.toStringAsFixed(0)}m (mode=$_currentMode)');
      final hold = _lastAcceptedSnap
          ?? (_driverBreadcrumbs.isNotEmpty ? _driverBreadcrumbs.last : raw);
      _snapCacheInput = raw;
      _snapCacheOutput = hold;
      return hold;
    }

    // ── GATE 2: Bearing/direction agreement ──
    // The vector from lastAccepted → raw should point the same direction
    // as lastAccepted → snapped. If they disagree by a wide angle, the
    // snap pulled the truck onto a perpendicular cross-street.
    if (_lastAcceptedSnap != null) {
      final rawHop = _haversineMeters(_lastAcceptedSnap!, raw);
      if (rawHop > 15) {  // only check when there's meaningful movement
        final rawBearing = _getBearing(_lastAcceptedSnap!, raw);
        final snapBearing = _getBearing(_lastAcceptedSnap!, snapped);
        var diff = (rawBearing - snapBearing).abs();
        if (diff > 180) diff = 360 - diff;
        final double maxBearingDiff = _currentMode == 0
            ? 75
            : (_currentMode == 1 ? 90 : 110);
        if (diff > maxBearingDiff) {
          debugPrint('🚫 Bearing mismatch: ${diff.toStringAsFixed(0)}° > ${maxBearingDiff.toStringAsFixed(0)}° (mode=$_currentMode)');
          _snapCacheInput = raw;
          _snapCacheOutput = _lastAcceptedSnap!;
          return _lastAcceptedSnap!;
        }
      }
    }

    // ── GATE 3: Parallel-road filter ──
    // Raw GPS barely moved (<30 m) but the snap jumped far (>80 m).
    // That means the snap latched onto a parallel road or service lane.
    if (_lastAcceptedSnap != null && _lastAcceptedRaw != null) {
      final rawHop = _haversineMeters(_lastAcceptedRaw!, raw);
      final snapHop = _haversineMeters(_lastAcceptedSnap!, snapped);
      if (rawHop < 30 && snapHop > 80) {
        debugPrint('🚫 Parallel road: raw=${rawHop.toStringAsFixed(0)}m snap=${snapHop.toStringAsFixed(0)}m');
        _snapCacheInput = raw;
        _snapCacheOutput = _lastAcceptedSnap!;
        return _lastAcceptedSnap!;
      }
    }

    // ── (Gate 4 / Gate 5 removed) ──
    // Earlier versions had a "forward segment cap + 2-point stability
    // confirmation" pair that buffered large forward jumps and waited
    // for a second consistent poll before committing. In practice this:
    //
    //   - Froze the marker for 20+ seconds during U-turns and fast
    //     movement, then produced a visible "teleport" when finally
    //     confirmed.
    //   - Got into deadlocks when consecutive snaps landed at slightly
    //     different segments (each one overwrote the pending without
    //     ever confirming).
    //   - Couldn't tell legitimate fast movement apart from snap errors
    //     because the only check was segment count.
    //
    // The remaining gates (snap quality, bearing agreement, parallel-
    // road filter) are individually strong enough to reject the bad-
    // single-point case Gate 5 was meant to catch:
    //
    //   - Bad point on a parallel road → bearing disagrees → Gate 2
    //   - Bad point with raw barely moved → parallel filter → Gate 3
    //   - Bad point off the road entirely → snap quality > threshold
    //     → Gate 1
    //
    // So we commit unconditionally once Gates 0-3 pass.

    // ── ALL GATES PASSED — commit ──
    _currentSegmentIndex = bestIndex;
    _lastAcceptedSnap = snapped;
    _lastAcceptedRaw = raw;
    _snapCacheInput = raw;
    _snapCacheOutput = snapped;
    return snapped;
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
    if (_fullPolyline.isEmpty) return 0;

    // Search forward from current segment (+30) instead of entire polyline.
    // Falls back to broader search only if needed.
    final searchEnd = (_currentSegmentIndex + 30).clamp(0, _fullPolyline.length);
    double minDist = double.infinity;
    int index = _currentSegmentIndex;

    for (int i = _currentSegmentIndex; i < searchEnd; i++) {
      final d = _haversineMeters(_fullPolyline[i], current);
      if (d < minDist) {
        minDist = d;
        index = i;
      }
    }

    return index;
  }

  /// Warm up the snap pipeline state after a fresh load (screen reopen,
  /// app restart, hot reload) so that the first live poll has a correct
  /// `_currentSegmentIndex` and a populated `_lastAcceptedSnap` /
  /// `_lastAcceptedRaw` baseline.
  ///
  /// CRITICAL: seed the segment index from `_currentLatLng` (the live
  /// driver position), NOT from the last timeline point. `bookings.driver_lat`
  /// updates on every accepted GPS poll, but `vehicle_trackings` rows are
  /// only inserted on movement ≥25 m, so the last timeline point can be
  /// several polls behind the actual current position. Seeding from the
  /// stale timeline position puts `_currentSegmentIndex` BEHIND the truck,
  /// which makes the first live poll look like a "large forward jump" to
  /// Gate 5 → buffer → marker frozen at the wrong position. The user sees:
  ///   - First reload: marker shows wrong (frozen behind actual position)
  ///   - Wait + reload again: timeline has caught up to driver_lat → marker
  ///     correct
  ///
  /// Fix: always seed from `_currentLatLng`. Use timeline only for
  /// previous-point bearing/parallel context.
  void _replayTimelineThroughPipeline() {
    if (_trackingData == null) return;
    if (_fullPolyline.length < 2) return;
    if (_currentLatLng == null) return;

    // 1. Seed segment index from the CURRENT driver position. This is the
    //    most up-to-date position the backend has.
    _initializeSegmentIndex(_currentLatLng!);

    // 2. Snap the current position to its segment to get the canonical
    //    on-route coordinate. Manual projection (we can't call
    //    `_snapToRoute` here because the gates need state we're about to
    //    set ourselves).
    LatLng snappedCurrent = _currentLatLng!;
    if (_currentSegmentIndex < _fullPolyline.length - 1) {
      snappedCurrent = _projectOntoSegment(
        _currentLatLng!,
        _fullPolyline[_currentSegmentIndex],
        _fullPolyline[_currentSegmentIndex + 1],
      );
    }

    // 3. Extract timeline points to provide bearing/parallel context for
    //    the very next live poll. Without this, Gate 2 (bearing) and
    //    Gate 3 (parallel) skip on the first poll because they have no
    //    `_lastAcceptedRaw` to compare against.
    final timelinePoints = <LatLng>[];
    for (final t in _trackingData!.timeline) {
      final lat = t.lat;
      final lng = t.lng;
      if (lat != null && lng != null && lat != 0 && lng != 0) {
        timelinePoints.add(LatLng(lat, lng));
      }
    }

    // 4. Seed snap state. `_lastAcceptedSnap` is the snapped current
    //    position (where the truck is on the route, right now).
    //    `_lastAcceptedRaw` is the previous timeline point if available
    //    so the bearing check has a "previous position" to compare
    //    against. Falls back to current if there's no history.
    _lastAcceptedSnap = snappedCurrent;
    _lastAcceptedRaw = timelinePoints.isNotEmpty
        ? timelinePoints.last
        : _currentLatLng;

    // 5. Clear the snap idempotency cache so the next call evaluates
    //    fresh (we just changed the underlying state out from under it).
    _snapCacheInput = null;
    _snapCacheOutput = null;

    debugPrint('✅ Pipeline warmed from current position: '
        'segment $_currentSegmentIndex / ${_fullPolyline.length - 1} '
        '(timeline had ${timelinePoints.length} points)');
  }

  /// Global search of entire polyline to find the correct starting segment.
  /// Called ONCE on route load so that _snapToRoute and _getClosestPolylineIndex
  /// start searching from the right position instead of always from 0.
  void _initializeSegmentIndex(LatLng driverPos) {
    if (_fullPolyline.length < 2) return;
    double minDist = double.infinity;
    int bestIdx = 0;
    for (int i = 0; i < _fullPolyline.length - 1; i++) {
      final projected = _projectOntoSegment(driverPos, _fullPolyline[i], _fullPolyline[i + 1]);
      final d = _haversineMeters(driverPos, projected);
      if (d < minDist) {
        minDist = d;
        bestIdx = i;
      }
    }
    _currentSegmentIndex = bestIdx;
    debugPrint('📍 Segment index initialized to $bestIdx (dist=${minDist.toStringAsFixed(0)}m)');
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
    if (_haversineMeters(previous, current) < 2) return;
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

  // Road-aligned points for the green dotted home→vehicle polyline. Filled
  // asynchronously by `_refreshHomeToVehicleRoute` via Directions API. While
  // empty, the polyline falls back to a straight chord between the two
  // markers (rendered immediately on first paint).
  List<LatLng> _homeToVehiclePoints = [];
  LatLng? _h2vFetchedHome;
  LatLng? _h2vFetchedVehicle;
  bool _h2vFetching = false;

  /// Green dotted line from the home (pickup) marker to the vehicle (truck)
  /// marker, following the actual road geometry. Returns null until the
  /// `_refreshHomeToVehicleRoute` Directions fetch has populated
  /// `_homeToVehiclePoints` — no straight-line fallback, as a chord on a
  /// road map reads as a wrong route, not a loading state.
  Polyline? _buildHomeToVehiclePolyline() {
    if (_homeToVehiclePoints.length < 2) return null;
    return Polyline(
      polylineId: const PolylineId('home_to_vehicle'),
      points: _homeToVehiclePoints,
      color: const Color(0xFF34A853),
      width: 5,
    );
  }

  /// Refresh the road-aligned green dotted home→vehicle polyline via a
  /// fresh Directions API call. Self-throttles: skips when neither endpoint
  /// moved meaningfully since the last fetch (30 m for home, 50 m for the
  /// truck). Fire-and-forget — schedules a setState on completion.
  List<LatLng>? _homeToFirstBreadcrumbRoute; // cached road path from home to first breadcrumb

  Future<void> _refreshHomeToVehicleRoute() async {
    final homePoint = _homeMarkerLatLng ?? _pickupLatLng;
    final breadcrumbs = _trackingData?.driverBreadcrumbs ?? [];

    // Fetch road-aligned path from home to first breadcrumb (once)
    if (_homeToFirstBreadcrumbRoute == null && homePoint != null && breadcrumbs.isNotEmpty) {
      LatLng? firstBc;
      for (final bc in breadcrumbs) {
        if (bc is List && bc.length >= 2) {
          final lat = (bc[0] as num?)?.toDouble();
          final lng = (bc[1] as num?)?.toDouble();
          if (lat != null && lng != null && lat != 0 && lng != 0) {
            firstBc = LatLng(lat, lng);
            break;
          }
        } else if (bc is Map) {
          final lat = (bc['lat'] as num?)?.toDouble();
          final lng = (bc['lng'] as num?)?.toDouble();
          if (lat != null && lng != null && lat != 0 && lng != 0) {
            firstBc = LatLng(lat, lng);
            break;
          }
        }
      }

      if (firstBc != null && _haversineDistance(homePoint, firstBc) > 100) {
        try {
          final pts = await GoogleMapsService.getDirectionsHighRes(
            origin: homePoint,
            destination: firstBc,
          );
          if (pts.length >= 2) {
            _homeToFirstBreadcrumbRoute = pts;
          }
        } catch (e) {
          debugPrint('🟢 [H2V] Home→firstBC route error: $e');
        }
      } else {
        _homeToFirstBreadcrumbRoute = []; // no road path needed (close enough)
      }
    }

    _buildGreenFromPolyline();
  }

  /// Build green line from driver_breadcrumbs (actual driven path).
  /// Filters out GPS spikes (>10km jumps) and null/empty values.
  /// Always covers passed stops — if breadcrumbs don't reach a passed stop,
  /// that stop's lat/lng is inserted to keep the path continuous.
  void _buildGreenFromPolyline() {
    final breadcrumbs = _trackingData?.driverBreadcrumbs ?? [];
    final passedStops = _trackingData?.passedStops ?? [];
    final driverPos = _currentLatLng;

    final List<LatLng> greenPoints = [];

    // 1. Add road-aligned path from home to first breadcrumb (if available)
    //    Otherwise just add home point
    final homePoint = _homeMarkerLatLng ?? _pickupLatLng;
    if (_homeToFirstBreadcrumbRoute != null && _homeToFirstBreadcrumbRoute!.isNotEmpty) {
      greenPoints.addAll(_homeToFirstBreadcrumbRoute!);
    } else if (homePoint != null) {
      greenPoints.add(homePoint);
    }

    // 2. Add breadcrumb points (filter spikes)
    LatLng? lastPoint = homePoint;
    for (final bc in breadcrumbs) {
      double? lat, lng;
      // Handle both formats: [lat,lng] array or {lat,lng} map
      if (bc is List && bc.length >= 2) {
        lat = (bc[0] as num?)?.toDouble();
        lng = (bc[1] as num?)?.toDouble();
      } else if (bc is Map) {
        lat = (bc['lat'] as num?)?.toDouble();
        lng = (bc['lng'] as num?)?.toDouble();
      }
      if (lat == null || lng == null || lat == 0 || lng == 0) continue;

      final point = LatLng(lat, lng);

      // Spike filter: skip if >10km jump from last point
      if (lastPoint != null) {
        final dist = _haversineDistance(lastPoint, point);
        if (dist > 10000) continue; // >10km = GPS spike, skip
      }

      greenPoints.add(point);
      lastPoint = point;
    }

    // 3. Ensure all passed stops are covered (insert if missing from breadcrumbs)
    for (final ps in passedStops) {
      final lat = (ps['lat'] as num?)?.toDouble();
      final lng = (ps['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || lat == 0 || lng == 0) continue;

      final stopPoint = LatLng(lat, lng);
      // Check if any breadcrumb is within 500m of this stop
      bool covered = greenPoints.any((gp) => _haversineDistance(gp, stopPoint) < 500);
      if (!covered) {
        // Insert stop at correct position (after nearest existing point)
        int insertIdx = greenPoints.length;
        double minDist = double.infinity;
        for (int i = 0; i < greenPoints.length; i++) {
          final d = _haversineDistance(greenPoints[i], stopPoint);
          if (d < minDist) { minDist = d; insertIdx = i + 1; }
        }
        greenPoints.insert(insertIdx.clamp(0, greenPoints.length), stopPoint);
      }
    }

    // 4. Add driver current position as last point
    if (driverPos != null && greenPoints.isNotEmpty) {
      final lastGreen = greenPoints.last;
      if (_haversineDistance(lastGreen, driverPos) > 5) { // >5m away
        greenPoints.add(driverPos);
      }
    }

    // 5. Draw green line
    if (greenPoints.length >= 2) {
      _homeToVehiclePoints = greenPoints;

      if (!mounted) return;
      final refreshed = _polylines
          .where((p) => p.polylineId.value != 'home_to_vehicle')
          .toSet();
      final h2v = _buildHomeToVehiclePolyline();
      if (h2v != null) refreshed.add(h2v);
      setState(() => _polylines = refreshed);
    }
  }

  int _findNearestPolylineIndex(LatLng point, List<LatLng> polyline) {
    double minDist = double.infinity;
    int bestIdx = 0;
    for (int i = 0; i < polyline.length; i++) {
      final d = _haversineDistance(point, polyline[i]);
      if (d < minDist) {
        minDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// Build markers for both small and expanded map views
  void _buildMarkers() {
    if (_trackingData == null) return;

    final pickup = _trackingData!.pickup;
    final driverLoc = _trackingData!.driverLocation;
    final destination = _trackingData!.drop;

    Set<Marker> smallMarkers = {};
    Set<Marker> expandedMarkers = {};

    /// -------- Pickup (home marker) --------
    /// Uses _homeMarkerLatLng (admin pickup if set, else driver pickup)
    /// instead of _pickupLatLng so the marker reflects admin's intended
    /// start location while the route fetch keeps using the driver's
    /// actual journey start as origin.
    final homeMarker = _homeMarkerLatLng ?? _pickupLatLng;
    final adminPickupName = _trackingData?.adminPickup?.name ?? '';
    final homeMarkerName =
        adminPickupName.isNotEmpty ? adminPickupName : pickup.name;
    if (homeMarker != null) {
      smallMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: homeMarker,
          icon:
              _smallPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Pickup', snippet: homeMarkerName),
        ),
      );

      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: homeMarker,
          icon:
              _expandedPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Pickup', snippet: homeMarkerName),
        ),
      );
    }

    /// -------- Vehicle (ONLY ONCE) --------
    // Skip the vehicle marker entirely when this booking is not yet the
    // active drop. The truck is currently serving an earlier-priority drop
    // for a different customer; showing it here would mislead this customer
    // into thinking the driver is on the way to them.
    if (_currentLatLng != null && _isActiveDrop) {
      final snappedPos = _snapToRoute(_currentLatLng!);
      final rotationAngle = _getVehicleBearing();
      final smallIcon = _smallTruckMarker ??
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
      final expandedIcon = _expandedTruckMarker ??
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

      smallMarkers.add(
        Marker(
          markerId: const MarkerId('vehicle'),
          position: snappedPos,
          icon: smallIcon,
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
          icon: expandedIcon,
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
              child: Builder(builder: (context) {
                if (_isLoadingRoute) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (_trackingData == null) {
                  return const Center(child: Text("No tracking data found"));
                }

                return _isMapExpanded
                    ? _buildExpandedMapView(width, height)
                    : _buildDefaultView(width, height);
              }),
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

        /// ── Floating ETA / Reached pill on map ──
        if (_estimatedDuration.isNotEmpty ||
            (_trackingData?.isDelivered ?? false) ||
            (_currentLatLng != null &&
                _destinationLatLng != null &&
                _haversineDistance(_currentLatLng!, _destinationLatLng!) < 50))
          Positioned(
            top: height * 0.015,
            left: 0,
            right: 0,
            child: Center(
              child: Builder(builder: (context) {
                // Check if destination reached (same logic as isReached in timeline)
                final destFirst = _trackingData?.drop.name.split(',').first.trim().toLowerCase() ?? '';
                bool passedAtDest = false;
                for (final ps in _trackingData?.passedStops ?? []) {
                  final psName = (ps['name'] as String? ?? '').toLowerCase().trim();
                  if (psName == destFirst) { passedAtDest = true; break; }
                  final psLat = (ps['lat'] as num?)?.toDouble() ?? 0;
                  final psLng = (ps['lng'] as num?)?.toDouble() ?? 0;
                  if (_destinationLatLng != null && psLat != 0 && psLng != 0 &&
                      _haversineDistance(LatLng(psLat, psLng), _destinationLatLng!) < 500) {
                    passedAtDest = true; break;
                  }
                }
                final bool arrivedAtDrop = (_trackingData?.isDelivered ?? false) ||
                    passedAtDest ||
                    (_currentLatLng != null &&
                        _destinationLatLng != null &&
                        _haversineDistance(_currentLatLng!, _destinationLatLng!) <
                            50);
                return Container(
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
                      Icon(
                        arrivedAtDrop ? Icons.check_circle : Icons.circle,
                        size: width * 0.03,
                        color: Colors.green,
                      ),
                      SizedBox(width: width * 0.02),
                      Text(
                        arrivedAtDrop
                            ? ((_trackingData?.isDelivered ?? false)
                                ? 'Delivered'
                                : 'Reached')
                            : 'Arriving in ',
                        style: TextStyle(
                          fontSize: width * 0.033,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      if (!arrivedAtDrop)
                        Text(
                          // Live ETA — decreases with wall-clock time
                          _liveRemainingSeconds > 0
                              ? _formatDuration(_liveRemainingSeconds)
                              : _estimatedDuration,
                          style: TextStyle(
                            fontSize: width * 0.038,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                    ],
                  ),
                );
              }),
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

        /// ── Recenter button (visible when follow mode is off) ──
        if (!_isFollowingVehicle)
          Positioned(
            top: height * 0.015,
            left: width * 0.04,
            child: GestureDetector(
              onTap: _centerOnVehicle,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.035,
                  vertical: width * 0.02,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0077C8),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.my_location,
                      size: width * 0.04,
                      color: Colors.white,
                    ),
                    SizedBox(width: width * 0.015),
                    Text(
                      'Recenter',
                      style: TextStyle(
                        fontSize: width * 0.032,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
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
    final locationName = _resolveDriverLocationName();

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
            onTap: _isRefreshing ? null : () => _refreshData(forceRouteRefresh: true),
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
          myLocationEnabled: false,
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
          RefreshButton(onTap: () async {
            debugPrint('🔄 [REFRESH-BTN] Tapped!');
            await _refreshData(forceRouteRefresh: true);
            debugPrint('🔄 [REFRESH-BTN] Complete!');
          }),
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

    final locationName = _resolveDriverLocationName();

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

    // Status copy is keyed off the actual trip state so the customer never
    // sees the stale "we'll assign your vehicle" message after a driver
    // has already been assigned and is mid-trip.
    final bool reached = _trackingData!.isDelivered ||
        (_currentLatLng != null &&
            _destinationLatLng != null &&
            _haversineDistance(_currentLatLng!, _destinationLatLng!) < 30);
    final bool inJourney = _currentLatLng != null;

    String statusMessage;
    if (reached) {
      statusMessage = _trackingData!.isDelivered
          ? 'Order delivered. Thank you!'
          : 'Driver has reached your location.';
    } else if (inJourney) {
      statusMessage = _trackingData!.vehicleDescription?.isNotEmpty == true
          ? _trackingData!.vehicleDescription!
          : (_trackingData!.deliveryUpdates.note.isNotEmpty
              ? _trackingData!.deliveryUpdates.note
              : 'Vehicle is on the way to your location.');
    } else {
      statusMessage = _trackingData!.vehicleDescription?.isNotEmpty == true
          ? _trackingData!.vehicleDescription!
          : (_trackingData!.deliveryUpdates.note.isNotEmpty
              ? _trackingData!.deliveryUpdates.note
              : 'We\'ve received your booking. Within a few days, we will assign your vehicle');
    }

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
        color: const Color(0xFF1A73E8), // blue
        width: 5,
        patterns: [PatternItem.dot, PatternItem.gap(10)],
      ),
    );
  }

  /// Handle timeline item tap — expand/collapse sub-stops.
  /// For passed stops (from API), only show substops from the API's sub_stops[].
  /// For upcoming stops (client-generated), generate substops from polyline.
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

    // segmentIndex = fixedStopIndex + 1, so the stop is at index segmentIndex - 1
    final stopIndex = segmentIndex - 1;
    if (stopIndex >= 0 && stopIndex < _fixedStops.length) {
      final stop = _fixedStops[stopIndex];
      final isPassedStop = stop['api_time'] != null || stop['passed_at'] != null;

      if (isPassedStop) {
        // Passed stop — only use API's sub_stops, never generate client-side
        final apiSubStops = (_trackingData?.passedStops ?? [])
            .firstWhereOrNull((ps) =>
                (ps['name'] as String?)?.toLowerCase() ==
                (stop['name'] as String?)?.toLowerCase())
            ?['sub_stops'] as List?;

        final subStops = (apiSubStops ?? [])
            .map((s) => <String, dynamic>{
                  'name': s['name']?.toString() ?? '',
                  'lat': (s['lat'] as num?)?.toDouble() ?? 0.0,
                  'lng': (s['lng'] as num?)?.toDouble() ?? 0.0,
                  'api_time': s['time']?.toString(),
                })
            .where((s) => (s['name'] as String).isNotEmpty)
            .toList();

        setState(() {
          _subStopsCache[segmentIndex] = subStops;
          _expandedSegmentIndex = subStops.isNotEmpty ? segmentIndex : null;
        });
        return;
      }
    }

    // Upcoming stop — generate sub-stops from polyline
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

    // Is destination reached? Check:
    // 1. Booking formally delivered
    // 2. Driver within 200m of drop
    // 3. A passed stop matches destination name or is near destination
    final destName = destination.name.split(',').first.trim().toLowerCase();
    bool passedStopAtDest = false;
    for (final ps in _trackingData!.passedStops) {
      final psName = (ps['name'] as String? ?? '').toLowerCase().trim();
      if (psName == destName) { passedStopAtDest = true; break; }
      final psLat = (ps['lat'] as num?)?.toDouble() ?? 0;
      final psLng = (ps['lng'] as num?)?.toDouble() ?? 0;
      if (_destinationLatLng != null && psLat != 0 && psLng != 0 &&
          _haversineDistance(LatLng(psLat, psLng), _destinationLatLng!) < 500) {
        passedStopAtDest = true; break;
      }
    }
    final bool isReached = _trackingData!.isDelivered ||
        passedStopAtDest ||
        (hasCurrentLocation &&
            _destinationLatLng != null &&
            _haversineDistance(LatLng(driverLoc.lat, driverLoc.lng), _destinationLatLng!) < 50);

    List<Widget> timelineItems = [];

    // Compute destination-arrival up-front: once the booking is formally
    // delivered (status=5) OR the driver is within 30 m of the drop, every
    // fixed stop should render as "Passed" with no active vehicle icon —
    // the truck is at (or has been to) the destination. Without the
    // is_delivered check, a driver who moves back to pickup after
    // delivering would re-light the truck icon on the nearest fixed stop.
    final bool driverAtDest = (_trackingData?.isDelivered ?? false) ||
        (hasCurrentLocation &&
            _destinationLatLng != null &&
            _haversineDistance(_currentLatLng!, _destinationLatLng!) < 30);

    // Check if driver is AT a fixed stop (within threshold) — if so, merge into that stop.
    // Disabled once the driver reaches the destination, otherwise the last
    // fixed stop keeps the live truck icon even though the driver has moved on.
    // Is the driver still near the pickup? (within 500m)
    final bool driverNearPickup = hasCurrentLocation &&
        _pickupLatLng != null &&
        _haversineDistance(_currentLatLng!, _pickupLatLng!) < 500;

    // Vehicle widget — always show as separate row after all passed stops.
    // Never merge into a fixed stop — driver's actual location should always
    // be visible between passed and upcoming stops.
    final bool willInsertVehicleWidget = hasCurrentLocation &&
        !driverNearPickup;

    /// -------- Pickup (always green, always first) --------
    final pickupTime = (_trackingData!.inProgressAt != null && _trackingData!.inProgressAt!.isNotEmpty)
        ? _formatDateTime(_trackingData!.inProgressAt)
        : _formatDateTime(driverLoc.updatedAt);
    final bool pickupNextIsPassed = willInsertVehicleWidget
        ? true
        : (_fixedStops.isNotEmpty && _currentStopIndex >= 0);

    // First stop fraction for substop generation on pickup tap
    final double firstStopFraction = _fixedStops.isNotEmpty ? _getStopFraction(0) : 1.0;

    timelineItems.add(
      GestureDetector(
        onTap: () {
          _onTimelineTap(0, 0.0, firstStopFraction);
        },
        child: _buildTimelineItem(
          width,
          height,
          driverNearPickup ? Icons.local_shipping : Icons.location_on,
          Colors.green,
          'Pickup started from',
          pickup.name.isNotEmpty ? pickup.name : 'N/A',
          pickupTime,
          isFirst: true,
          isPassed: true,
          isNextPassed: pickupNextIsPassed,
          isPulsing: driverNearPickup && !driverAtDest,
        ),
      ),
    );

    // Active vehicle ("driver is here") row — built BEFORE the first segment's
    // sub-stops. When the driver hasn't passed any fixed stop yet, the active
    // row must appear before the upcoming stop and its sub-stops (e.g.
    // "Jubilee Hills"), matching the user app. (The user app reaches the same
    // result by drawing the truck on the pickup row when it's near pickup.)
    Widget? vehicleWidget;
    if (willInsertVehicleWidget && !isReached) {
      // Vehicle widget's connector goes down to the next unpassed
      // fixed stop, so its connector is grey (next item is NOT passed).
      vehicleWidget = _buildTimelineItem(
        width,
        height,
        Icons.local_shipping,
        Colors.green,
        _resolveDriverLocationName(),
        _formatDate(driverLoc.updatedAt),
        _formatDateTime(driverLoc.updatedAt),
        isPulsing: true,
        isPassed: true,
        isNextPassed: false,
      );
    }

    bool vehicleInserted = false;

    // Has the driver passed any backend-confirmed fixed stop? If not, it's
    // still in the first segment, so insert the active row now — before this
    // segment's upcoming sub-stops — instead of after them.
    bool anyFixedStopPassed = false;
    for (final s in _fixedStops) {
      final hasApi = ((s['api_time'] as String?)?.isNotEmpty ?? false) ||
          ((s['passed_at'] as String?)?.isNotEmpty ?? false);
      if (hasApi) {
        anyFixedStopPassed = true;
        break;
      }
    }
    if (vehicleWidget != null && !anyFixedStopPassed) {
      timelineItems.add(vehicleWidget);
      vehicleInserted = true;
    }

    // Show substops for pickup → first stop segment
    if (_expandedSegmentIndex == 0) {
      String nextStopTime = '-';
      String nextStopName = '';
      if (_fixedStops.isNotEmpty) {
        nextStopName = (_fixedStops[0]['name'] as String?) ?? '';
        final nextApiTime = _fixedStops[0]['api_time'] as String?;
        final nextPassedAt = _fixedStops[0]['passed_at'] as String?;
        if (nextApiTime != null && nextApiTime.isNotEmpty) {
          nextStopTime = nextApiTime;
        } else if (nextPassedAt != null && nextPassedAt.isNotEmpty) {
          nextStopTime = _formatDateTime(nextPassedAt);
        }
      }
      timelineItems.add(
        _buildSubTimeline(
          width,
          height,
          0,
          _loadingSegment == 0,
          Colors.green,
          parentTime: pickupTime,
          nextStopTime: nextStopTime,
          parentStopName: pickup.name,
          nextStopName: nextStopName,
        ),
      );
    }

    /// -------- Fixed Stops (NEVER changes, only color updates) --------
    if (_isLoadingFixedStops && _fixedStops.isEmpty) {
      if (!vehicleInserted && vehicleWidget != null) {
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
      // Find the index of the last API-confirmed passed stop
      int lastPassedIdx = -1;
      for (int i = 0; i < _fixedStops.length; i++) {
        final hasApi = (_fixedStops[i]['api_time'] != null &&
                (_fixedStops[i]['api_time'] as String).isNotEmpty) ||
            (_fixedStops[i]['passed_at'] != null &&
                (_fixedStops[i]['passed_at'] as String).isNotEmpty);
        if (hasApi) lastPassedIdx = i;
      }

      // Pre-compute upcoming stop times to ensure they are monotonically increasing
      final Map<int, String> _upcomingTimes = {};
      final driverOrPickup = _currentLatLng ?? _pickupLatLng;
      if (driverOrPickup != null) {
        DateTime lastTime = DateTime.now();
        for (int i = 0; i < _fixedStops.length; i++) {
          final hasApi = (_fixedStops[i]['api_time'] != null &&
                  (_fixedStops[i]['api_time'] as String).isNotEmpty) ||
              (_fixedStops[i]['passed_at'] != null &&
                  (_fixedStops[i]['passed_at'] as String).isNotEmpty);
          if (hasApi) continue; // passed stops use API time
          if (i <= lastPassedIdx) continue; // skipped stops

          final sLat = (_fixedStops[i]['lat'] as num).toDouble();
          final sLng = (_fixedStops[i]['lng'] as num).toDouble();
          final distFromDriver = _haversineDistance(driverOrPickup!, LatLng(sLat, sLng));
          final speedKmh = _trackingData?.driverLocation.speedKmh?.toDouble() ?? 0;
          final avgSpeed = speedKmh > 5 ? speedKmh : 40;
          final etaMinutes = ((distFromDriver / 1000) / avgSpeed * 60).round().clamp(1, 99999);
          final stopTime = DateTime.now().add(Duration(minutes: etaMinutes));

          // Ensure monotonic: each stop time must be >= previous
          final effectiveTime = stopTime.isAfter(lastTime) ? stopTime : lastTime.add(const Duration(minutes: 3));
          _upcomingTimes[i] = _formatDateTimeObj(effectiveTime);
          lastTime = effectiveTime;
        }
      }

      for (int i = 0; i < _fixedStops.length; i++) {
        final hasBackendPassedAt =
            (_fixedStops[i]['passed_at'] != null &&
                (_fixedStops[i]['passed_at'] as String).isNotEmpty) ||
            (_fixedStops[i]['api_time'] != null &&
                (_fixedStops[i]['api_time'] as String).isNotEmpty);
        final isPassed = hasBackendPassedAt;

        // Skip unpassed stops that are before or at the last passed stop
        if (!isPassed && i <= lastPassedIdx) continue;

        // If destination reached → skip all upcoming (unpassed) stops
        if (!isPassed && isReached) continue;

        // Insert vehicle AFTER the last passed stop (i == lastPassedIdx + 1 area)
        if (!vehicleInserted && vehicleWidget != null && !isReached && i > lastPassedIdx) {
          timelineItems.add(vehicleWidget);
          vehicleInserted = true;
        }

        final stop = _fixedStops[i];
        final name = stop['name'] as String? ?? 'Stop ${i + 1}';
        final isKeyStop = stop['is_key_stop'] == true;
        final isDriverHere = false; // Driver always shows as separate vehicle widget

        if (i == 0) debugPrint('🗺️ [RENDER] Rendering ${_fixedStops.length} fixed stops, lastPassedIdx=$lastPassedIdx isReached=$isReached');
        final stopColor = isPassed ? Colors.green : Colors.black;
        String? subtitle;
        if (isDriverHere) {
          subtitle = _formatDate(driverLoc.updatedAt);
        } else if (isPassed) {
          subtitle = 'Passed';
        }

        // Time: from API data only
        final stopFraction = _getStopFraction(i);
        String? time;
        final passedAt = stop['passed_at'] as String?;
        final apiTime = stop['api_time'] as String?;
        final apiEta = stop['estimated_arrival'] as String?;

        if (apiTime != null && apiTime.isNotEmpty) {
          time = apiTime;
        } else if (passedAt != null && passedAt.isNotEmpty) {
          time = _formatDateTime(passedAt);
        } else if (_upcomingTimes.containsKey(i)) {
          time = _upcomingTimes[i]!;
        } else if (apiEta != null && apiEta.isNotEmpty) {
          time = apiEta;
        } else {
          // Compute ETA inline from distance to stop
          final sLat = (stop['lat'] as num).toDouble();
          final sLng = (stop['lng'] as num).toDouble();
          final driverPos = _currentLatLng ?? _pickupLatLng;
          if (driverPos != null) {
            final distKm = _haversineDistance(driverPos, LatLng(sLat, sLng)) / 1000;
            final etaMins = (distKm / 40 * 60).round().clamp(1, 99999);
            time = _formatDateTimeObj(DateTime.now().add(Duration(minutes: etaMins)));
          } else {
            time = '-';
          }
        }

        final nextFraction = i < _fixedStops.length - 1
            ? _getStopFraction(i + 1)
            : 1.0;
        final segmentIndex = i + 1;

        // Connector: green if next visible item is also passed or reached
        final bool nextIsPassed = isReached || (i < lastPassedIdx);

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
          String nextStopTime = '-';
          String nextStopName = '';

          // If this is the last passed stop, substops should end at current
          // time (driver is between here and next upcoming stop)
          if (i == lastPassedIdx && !isReached) {
            nextStopTime = _formatDateTimeObj(DateTime.now());
            nextStopName = _resolveDriverLocationName();
          } else {
            // Find the NEXT VISIBLE stop
            for (int j = i + 1; j < _fixedStops.length; j++) {
              final jHasApi = (_fixedStops[j]['api_time'] != null &&
                      (_fixedStops[j]['api_time'] as String).isNotEmpty) ||
                  (_fixedStops[j]['passed_at'] != null &&
                      (_fixedStops[j]['passed_at'] as String).isNotEmpty);
              if (!jHasApi && j <= lastPassedIdx) continue;
              if (!jHasApi && isReached) continue;

              nextStopName = (_fixedStops[j]['name'] as String?) ?? '';
              final nextApiTime = _fixedStops[j]['api_time'] as String?;
              final nextPassedAt = _fixedStops[j]['passed_at'] as String?;
              if (nextApiTime != null && nextApiTime.isNotEmpty) {
                nextStopTime = nextApiTime;
              } else if (nextPassedAt != null && nextPassedAt.isNotEmpty) {
                nextStopTime = _formatDateTime(nextPassedAt);
              } else if (_upcomingTimes.containsKey(j)) {
                nextStopTime = _upcomingTimes[j]!;
              } else {
                final nf = _getStopFraction(j);
                final eta = _getTimeForFraction(nf);
                nextStopTime = (eta.isNotEmpty && eta != '-') ? eta : '-';
              }
              break;
            }
            // If no next stop found, use destination time
            if (nextStopTime == '-') {
              nextStopName = destination.name;
              final destTime = isReached
                  ? _formatDateTime(driverLoc.updatedAt)
                  : _getTimeForFraction(1.0);
              if (destTime.isNotEmpty && destTime != '-') {
                nextStopTime = destTime;
              }
            }
          }
          timelineItems.add(
            _buildSubTimeline(
              width,
              height,
              segmentIndex,
              isLoading,
              isPassed ? Colors.green : Colors.grey,
              parentTime: time ?? '-',
              nextStopTime: nextStopTime,
              parentStopName: name,
              nextStopName: nextStopName,
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
      // Times are kept in memory only — no SharedPreferences persistence
    }

    /// -------- Destination --------
    // isReached already computed at the top of this method.

    final String destinationTime = isReached
        ? (_trackingData!.deliveredAt != null &&
                _trackingData!.deliveredAt!.isNotEmpty
            ? _trackingData!.deliveredAt!
            : _formatDateTime(driverLoc.updatedAt))
        : _getTimeForFraction(1.0);

    final destAddress = destination.name.isNotEmpty ? destination.name : null;
    timelineItems.add(
      _buildTimelineItem(
        width,
        height,
        isReached ? Icons.check_circle : Icons.flag,
        isReached ? Colors.green : Colors.black,
        isReached
            ? (_trackingData!.isDelivered ? 'Destination Delivered' : 'Destination Reached')
            : 'Destination',
        isReached
            ? destAddress
            : (destAddress ?? 'N/A'),
        destinationTime,
        isLast: true,
        isPassed: isReached,
      ),
    );

    return Column(children: timelineItems);
  }

  // ══════════════════════════════════════════════════════════════════════
  // FIXED TIMELINE — Layer 1: Business milestones (NEVER changes)
  // ══════════════════════════════════════════════════════════════════════

  /// Defensive client-side clamp: walk the stops in route order and bump any
  /// out-of-order `passed_at` up to the previous stop's `passed_at` + 1 s.
  /// The backend already enforces this same rule, but a stale cache or a
  /// race could in principle return data where stop N+1's pass time is
  /// earlier than stop N's — at which point the customer would see a later
  /// stop with an earlier time and assume the app is broken. Doing the
  /// clamp again on the client is cheap and keeps the UI honest.
  void _enforceMonotonicPassedAt(List<Map<String, dynamic>> stops) {
    DateTime? prev;
    for (final s in stops) {
      final raw = s['passed_at'] as String?;
      if (raw == null || raw.isEmpty) {
        continue;
      }
      DateTime t;
      try {
        t = DateTime.parse(raw);
      } catch (_) {
        continue;
      }
      // Use isBefore OR equal — two stops sharing the exact same
      // closest breadcrumb (common on short routes) would otherwise show
      // identical times and look like the data is broken. +1 s gives them
      // distinct timestamps without inventing a long fake pause.
      if (prev != null && !t.isAfter(prev)) {
        t = prev.add(const Duration(seconds: 1));
        s['passed_at'] = t.toIso8601String();
      }
      prev = t;
    }
  }

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
    // Always refetch — route must include all waypoints for accurate green line

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

    if (_fixedStops.isEmpty) setState(() => _isLoadingFixedStops = true);

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

    // Build waypoint entries (key stops), sorted by priority.
    final waypoints = (_trackingData?.routeWaypoints ?? [])
        ..sort((a, b) => a.priority.compareTo(b.priority));
    final List<Map<String, dynamic>> waypointStops = [];

    for (final wp in waypoints) {
      if (wp.lat == 0 && wp.lng == 0) continue;
      waypointStops.add({
        'name': wp.name.isNotEmpty ? wp.name : 'Waypoint',
        'lat': wp.lat,
        'lng': wp.lng,
        'is_key_stop': true,
      });
    }

    // Passed stops from DB (no auto_timeline_points — client generates upcoming)
    final List<Map<String, dynamic>> autoStops = (_trackingData?.passedStops ?? []).map((pt) {
      return {
        'name': pt['name']?.toString() ?? 'Stop',
        'lat': (pt['lat'] as num?)?.toDouble() ?? 0.0,
        'lng': (pt['lng'] as num?)?.toDouble() ?? 0.0,
        'is_key_stop': false,
        if (pt['passed_at'] != null) 'passed_at': pt['passed_at'],
      };
    }).where((s) => (s['lat'] as double) != 0 || (s['lng'] as double) != 0).toList();

    final allStops = [...waypointStops, ...autoStops];

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

    if (mounted && _fixedStops.isEmpty) setState(() => _isLoadingFixedStops = true);

    // Include only remaining (uncompleted) route_waypoints
    final remainingWps = (_trackingData?.routeWaypoints ?? [])
        .where((wp) => wp.lat != 0 && wp.lng != 0 && !wp.isCompleted)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));

    final List<Map<String, dynamic>> waypointStops = [];
    for (final wp in remainingWps) {
      waypointStops.add({
        'name': wp.name.isNotEmpty ? wp.name : 'Waypoint',
        'lat': wp.lat,
        'lng': wp.lng,
        'is_key_stop': true,
      });
    }

    // Passed stops from DB — permanent, never change
    final List<Map<String, dynamic>> passedStops = (_trackingData?.passedStops ?? []).map((pt) {
      return <String, dynamic>{
        'name': pt['name']?.toString() ?? 'Stop',
        'lat': (pt['lat'] as num?)?.toDouble() ?? 0.0,
        'lng': (pt['lng'] as num?)?.toDouble() ?? 0.0,
        'dist_fraction': 0.0,
        'is_key_stop': false,
        if (pt['passed_at'] != null) 'passed_at': pt['passed_at'],
      };
    }).where((s) => (s['lat'] as double) != 0 || (s['lng'] as double) != 0).toList();

    // Generate upcoming stops along new rerouted path:
    // driver → [pickup if not yet reached] → [uncompleted waypoints] → destination
    final driverPos = _currentLatLng ?? _pickupLatLng;
    List<Map<String, dynamic>> upcomingFromReroute = [];
    if (driverPos != null && _destinationLatLng != null) {
      final List<LatLng> mandatoryWps = [];
      if (_pickupLatLng != null && _haversineDistance(driverPos, _pickupLatLng!) > 500) {
        mandatoryWps.add(_pickupLatLng!);
      }
      for (final wp in remainingWps) {
        mandatoryWps.add(LatLng(wp.lat, wp.lng));
      }
      final totalDistKm = cumDist.last / 1000;
      final upcomingRaw = await TrackingStopsService.generateUpcomingStops(
        driverPosition: driverPos,
        destination: _destinationLatLng!,
        remainingDistanceKm: totalDistKm > 0 ? totalDistKm : 1.0,
        waypoints: mandatoryWps,
      );
      // Map to _fixedStops format
      for (final s in upcomingRaw) {
        final sLat = (s['lat'] as num?)?.toDouble() ?? 0.0;
        final sLng = (s['lng'] as num?)?.toDouble() ?? 0.0;
        upcomingFromReroute.add({
          'name': s['name']?.toString() ?? 'Stop',
          'lat': sLat,
          'lng': sLng,
          'dist_fraction': 0.0,
          'is_key_stop': false,
        });
      }
    }

    // Merge: passed (API) + waypoints + upcoming (rerouted), deduplicate
    final fixedNames = {
      ...passedStops.map((s) => (s['name'] as String).toLowerCase()),
      ...waypointStops.map((s) => (s['name'] as String).toLowerCase()),
    };
    final filteredUpcoming = upcomingFromReroute.where((s) {
      final name = (s['name'] as String).toLowerCase();
      if (fixedNames.contains(name)) return false;
      final sLat = s['lat'] as double;
      final sLng = s['lng'] as double;
      for (final p in [...passedStops, ...waypointStops]) {
        if (_haversineDistance(LatLng(sLat, sLng), LatLng(p['lat'] as double, p['lng'] as double)) < 500) return false;
      }
      return true;
    }).toList();

    final allStops = [...passedStops, ...waypointStops, ...filteredUpcoming];
    for (final stop in allStops) {
      final sLat = stop['lat'] as double;
      final sLng = stop['lng'] as double;
      double minD = double.infinity;
      int bestIdx = 0;
      for (int i = 0; i < polyline.length; i++) {
        final d = _haversineDistance(LatLng(sLat, sLng), polyline[i]);
        if (d < minD) { minD = d; bestIdx = i; }
      }
      stop['dist_fraction'] = cumDist.last > 0 ? cumDist[bestIdx] / cumDist.last : 0.0;
      stop['_sortDist'] = cumDist[bestIdx];
    }
    allStops.sort((a, b) => (a['_sortDist'] as double).compareTo(b['_sortDist'] as double));
    for (final stop in allStops) { stop.remove('_sortDist'); }
    debugPrint('🗺️ [REROUTE-STOPS] ${passedStops.length} passed + ${waypointStops.length} waypoints + ${filteredUpcoming.length} upcoming = ${allStops.length} total');

    if (mounted) {
      setState(() {
        _fixedStops = allStops;
        _isLoadingFixedStops = false;
      });
    }

    _fixedStopsGenerated = true;

    debugPrint('✅ Timeline regenerated after reroute: ${allStops.length} stops');
  }

  /// Uber-style progress: scan all FORWARD stops, find nearest within radius.
  /// Allows skipping stops (e.g., driver bypasses a city).
  /// Never moves backward. Cooldown prevents GPS jitter false triggers.
  void _updateProgress(LatLng currentLocation) {
    if (_fixedStops.isEmpty) return;

    // ── FRACTION-BASED PASSED CHECK (authoritative recompute) ──
    // Old logic was a one-way ratchet: it only INCREMENTED
    // `_currentStopIndex` from the persisted value, never recomputed.
    // That meant any wrong-high value (saved while the older 4-8 km
    // radius bug was active) became permanent — Mummidivaram stayed
    // "Passed" forever even after the truck drifted back south.
    //
    // New logic: recompute the index FROM SCRATCH every call as the
    // highest stop whose route fraction has been reached. The index can
    // both grow (normal forward travel) AND shrink (when stale persisted
    // state is corrected, or when the driver manually U-turns). When it
    // shrinks, we purge the stale `_passedStopTimes` entries so the next
    // legitimate pass-through will lock the correct arrival time, not
    // resurface the wrong one from cache.
    final currentFraction = _currentDriverFraction();
    debugPrint('📊 [PROGRESS] currentFraction=$currentFraction, polyline=${_fullRoutePolyline.length} pts, driverLat=${currentLocation.latitude}, driverLng=${currentLocation.longitude}');
    if (currentFraction <= 0 || _fullRoutePolyline.isEmpty) {
      // Fallback: use straight-line distance from pickup to determine
      // which stops the driver has already passed.
      if (_pickupLatLng != null && _fixedStops.isNotEmpty) {
        final driverDistFromPickup =
            _haversineDistance(currentLocation, _pickupLatLng!);
        int fallbackIndex = -1;
        for (int i = 0; i < _fixedStops.length; i++) {
          final sLat = (_fixedStops[i]['lat'] as num?)?.toDouble();
          final sLng = (_fixedStops[i]['lng'] as num?)?.toDouble();
          if (sLat == null || sLng == null) continue;
          final stopDist =
              _haversineDistance(_pickupLatLng!, LatLng(sLat, sLng));
          if (driverDistFromPickup >= stopDist) fallbackIndex = i;
        }
        if (fallbackIndex != _currentStopIndex) {
          debugPrint('📊 [PROGRESS] distance fallback: $_currentStopIndex → $fallbackIndex');
          setState(() => _currentStopIndex = fallbackIndex);
        }
      }
      return;
    }

    int recomputedIndex = -1;
    for (int i = 0; i < _fixedStops.length; i++) {
      final stopFraction = _getStopFraction(i);
      if (stopFraction > 0 && currentFraction >= stopFraction) {
        recomputedIndex = i;
      }
      if (i < 5) debugPrint('📊 [PROGRESS] stop[$i]="${_fixedStops[i]['name']}" fraction=$stopFraction passed=${currentFraction >= stopFraction}');
    }

    debugPrint("📡 DRIVER LOCATION: ${currentLocation.latitude}, ${currentLocation.longitude} "
        "(fraction=${currentFraction.toStringAsFixed(3)})");
    debugPrint("🎯 STOP INDEX recomputed=$recomputedIndex (was=$_currentStopIndex)");

    if (recomputedIndex == _currentStopIndex) return;

    final now = DateTime.now();
    if (recomputedIndex > _currentStopIndex) {
      // Forward progress — lock arrival times for the newly passed stops.
      for (int j = _currentStopIndex + 1; j <= recomputedIndex; j++) {
        final stopData = _fixedStops[j];
        final passedAt = stopData['passed_at'] as String?;
        if (passedAt != null && passedAt.isNotEmpty) {
          final formatted = _formatDateTime(passedAt);
          if (formatted != '-') {
            _passedStopTimes[j] = formatted;
            continue;
          }
        }

        if (!_passedStopTimes.containsKey(j)) {
          _passedStopTimes[j] = _formatDateTimeObj(now);
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
          if (stop['passed_at'] != null) 'passed_at': stop['passed_at'],
          if (stop['estimated_arrival'] != null)
            'estimated_arrival': stop['estimated_arrival'],
          if (stop['estimated_date'] != null) 'estimated_date': stop['estimated_date'],
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
      final apiPassedSignature = (_trackingData?.passedStops ?? [])
          .map((pt) => pt['passed_at']?.toString() ?? '')
          .join('|');
      final cachePassedSignature =
          stops.map((pt) => pt['passed_at']?.toString() ?? '').join('|');
      if (apiPassedSignature.replaceAll('|', '').isNotEmpty &&
          apiPassedSignature != cachePassedSignature) {
        await prefs.remove('fixed_stops_${widget.bookingId}');
        return false;
      }
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

  /// Highest fraction the driver has ever reached on `_fullRoutePolyline`.
  /// Used to bias future fraction calculations forward — the polyline
  /// can self-intersect (out-and-back via a waypoint, e.g.
  /// pickup → Mummidivaram → Amalapuram passing through the same area
  /// twice), and a naive closest-point search can return a point on
  /// the second pass even when the truck is on the first pass. We
  /// remember the highest fraction reached and never search backward
  /// past that minus a small slack tolerance.
  double _maxDriverFractionReached = 0.0;

  /// Where the truck currently is along the full route, as a fraction
  /// 0..1. Computed from `_currentLatLng` projected onto the cached
  /// `_fullRoutePolyline` (the same data that drives stop fractions, so
  /// the units stay consistent).
  ///
  /// SELF-INTERSECTING ROUTE HANDLING:
  /// Some routes loop back through their own area (e.g. an out-and-back
  /// via a priority waypoint). For those, multiple polyline points can
  /// be geometrically near the truck, but only one is the "correct" one
  /// for the truck's current pass. The naive `min haversine distance`
  /// search picks the absolute closest, which on the second pass of an
  /// out-and-back is often the post-waypoint leg — making the truck
  /// look like it's already past the waypoint when it isn't.
  ///
  /// Fix: bias the search toward the EARLIEST polyline point that is
  /// within a small tolerance of the absolute minimum. Once a fraction
  /// has been observed (`_maxDriverFractionReached`), restrict the
  /// search to points on or after that fraction minus a 500 m slack
  /// window — so legitimate forward progress isn't accidentally
  /// rewound by GPS jitter, but a stale "post-waypoint" guess from a
  /// previous bug doesn't pin the truck to the wrong leg.
  double _currentDriverFraction() {
    if (_currentLatLng == null) return _maxDriverFractionReached;
    if (_fullRoutePolyline.isEmpty || _fullRouteCumulativeDistances.isEmpty) {
      return _maxDriverFractionReached;
    }
    final total = _fullRouteCumulativeDistances.last;
    if (total <= 0) return 0.0;

    // Forward search window: never go more than 500 m behind the
    // highest fraction the truck has been observed at.
    final minSearchDist =
        (_maxDriverFractionReached * total - 500).clamp(0.0, total);

    // Pass 1: find the absolute minimum haversine distance from the
    // truck to any polyline point at-or-after the search floor.
    double absMin = double.infinity;
    for (int i = 0; i < _fullRoutePolyline.length; i++) {
      if (_fullRouteCumulativeDistances[i] < minSearchDist) continue;
      final d = _haversineDistance(_currentLatLng!, _fullRoutePolyline[i]);
      if (d < absMin) absMin = d;
    }
    if (absMin == double.infinity) return _maxDriverFractionReached;

    // Pass 2: find the EARLIEST polyline point within +200 m of the
    // absolute minimum. On a self-intersecting route this prefers the
    // first-pass leg over the second-pass leg whenever both are within
    // ~200 m of the truck — exactly the disambiguation we need.
    int bestIdx = 0;
    for (int i = 0; i < _fullRoutePolyline.length; i++) {
      if (_fullRouteCumulativeDistances[i] < minSearchDist) continue;
      final d = _haversineDistance(_currentLatLng!, _fullRoutePolyline[i]);
      if (d <= absMin + 200) {
        bestIdx = i;
        break; // earliest match wins
      }
    }

    final fraction =
        (_fullRouteCumulativeDistances[bestIdx] / total).clamp(0.0, 1.0);
    if (fraction > _maxDriverFractionReached) {
      _maxDriverFractionReached = fraction;
    }
    return fraction;
  }

  String _getTimeForFraction(double fraction) {
    // Use full route duration for fraction-based time calculation
    // so each stop gets a distinct time proportional to its distance along the route
    final duration = _fullRouteDurationSeconds > 0
        ? _fullRouteDurationSeconds
        : _totalRouteDurationSeconds;
    if (duration == 0) return '-';

    // ── PASSED stops: keep the original journey-start formula ──
    // Their actual arrival times are also captured separately into
    // `_passedStopTimes` and that locked value is preferred upstream;
    // this branch is just the fallback for the edge case where the
    // lock hasn't been written yet.
    final currentFraction = _currentDriverFraction();
    if (fraction <= currentFraction || _liveRemainingSeconds <= 0) {
      DateTime? baseTime;
      if (_trackingData?.inProgressAt != null && _trackingData!.inProgressAt!.isNotEmpty) {
        try {
          baseTime = DateTime.parse(_trackingData!.inProgressAt!).toLocal();
        } catch (_) {}
      }
      baseTime ??= _routeStartTime;
      if (baseTime == null) return '-';

      final seconds = (fraction * duration).round();
      return _formatDateTimeObj(baseTime.add(Duration(seconds: seconds)));
    }

    // ── FUTURE stops: anchor on now() + ADAPTIVE remaining duration ──
    //
    // Two effects stack on top of Google's `remaining_duration_seconds`:
    //
    //  1. HALT TRACKING — while the truck is parked, `now()` advances
    //     but `remaining` stays constant, so all downstream stops
    //     visibly shift forward by the halt duration.
    //
    //  2. SPEED-ADAPTIVE SCALING — while the truck is moving, the
    //     remaining duration is locally re-derived from the route's
    //     expected average speed and the driver's actual smoothed
    //     speed. Going faster than expected → ETA shrinks faster.
    //     Going slower → ETA grows. Same effect as Google Maps
    //     Navigation between traffic refreshes, but ZERO API cost
    //     because the math runs purely on locally-cached data
    //     (`_fullRouteDurationSeconds`, `_fullRouteCumulativeDistances`,
    //     `_estimatedSpeedKmh`).
    //
    // Falls back to the static `_remainingDurationSeconds` when:
    //   - actual speed is below 5 km/h (parked / crawling — division
    //     by ~0 would balloon the ETA),
    //   - route distance/duration metadata isn't loaded yet,
    //   - or the computed scale falls outside [0.5, 2.0] (we clamp it
    //     so a one-off GPS spike doesn't send the ETA wildly off).
    final adaptiveRemaining = _adaptiveRemainingSeconds();

    final routeAhead = (1.0 - currentFraction).clamp(0.0001, 1.0);
    final stopAhead = (fraction - currentFraction).clamp(0.0, 1.0);
    final secondsFromNow =
        ((stopAhead / routeAhead) * adaptiveRemaining).round();
    final dt = DateTime.now().add(Duration(seconds: secondsFromNow));
    return _formatDateTimeObj(dt);
  }

  /// Interpolate a realistic "passed at" time for a stop the driver has
  /// already passed but the backend didn't provide a `passed_at` for.
  /// Uses linear interpolation between journey start and driver's last
  /// known update time, based on the stop's fraction vs driver's fraction.
  String _interpolatePassedTime(double stopFraction) {
    DateTime? startTime;
    if (_trackingData?.inProgressAt != null && _trackingData!.inProgressAt!.isNotEmpty) {
      try { startTime = DateTime.parse(_trackingData!.inProgressAt!).toLocal(); } catch (_) {}
    }
    startTime ??= _routeStartTime;
    if (startTime == null) return '-';

    DateTime? driverTime;
    final updatedAt = _trackingData?.driverLocation.updatedAt;
    if (updatedAt != null && updatedAt.isNotEmpty) {
      try { driverTime = DateTime.parse(updatedAt).toLocal(); } catch (_) {}
    }
    driverTime ??= DateTime.now();

    final driverFraction = _currentDriverFraction();
    if (driverFraction <= 0) return _formatDateTimeObj(startTime);

    // Linear interpolation: stopTime = startTime + (stopFraction / driverFraction) * (driverTime - startTime)
    final totalElapsed = driverTime.difference(startTime).inSeconds;
    final ratio = (stopFraction / driverFraction).clamp(0.0, 1.0);
    final stopSeconds = (ratio * totalElapsed).round();
    return _formatDateTimeObj(startTime.add(Duration(seconds: stopSeconds)));
  }

  /// Locally-computed remaining duration adjusted for actual driver
  /// speed. Returns the static `_remainingDurationSeconds` when there
  /// isn't enough data or the truck is too slow to compute a meaningful
  /// scale factor. See `_getTimeForFraction` for full rationale.
  int _adaptiveRemainingSeconds() {
    final live = _liveRemainingSeconds;
    if (live <= 0) return live;
    if (_estimatedSpeedKmh < 5) return live;
    if (_fullRouteCumulativeDistances.isEmpty) return live;

    final totalRouteMeters = _fullRouteCumulativeDistances.last;
    final totalDurationSec = _fullRouteDurationSeconds > 0
        ? _fullRouteDurationSeconds
        : _totalRouteDurationSeconds;
    if (totalRouteMeters <= 0 || totalDurationSec <= 0) {
      return live;
    }

    final expectedAvgKmh = (totalRouteMeters / totalDurationSec) * 3.6;
    if (expectedAvgKmh < 1) return live;

    // scale > 1 → driver is slower than expected → ETA grows.
    // scale < 1 → driver is faster than expected → ETA shrinks.
    final rawScale = expectedAvgKmh / _estimatedSpeedKmh;
    final scale = rawScale.clamp(0.5, 2.0);
    return (live * scale).round();
  }

  /// Build the sub-timeline items between two main stops
  Widget _buildSubTimeline(
    double width,
    double height,
    int segmentIndex,
    bool isLoading,
    Color lineColor, {
    String parentTime = '-',
    String nextStopTime = '-',
    String parentStopName = '',
    String nextStopName = '',
  }) {
    if (isLoading && !_subStopsCache.containsKey(segmentIndex)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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

    final rawSubStops = _subStopsCache[segmentIndex];
    if (rawSubStops == null || rawSubStops.isEmpty) return const SizedBox.shrink();

    // Filter out substops that duplicate the parent, next stop, or any
    // city/state from the pickup/destination address (e.g. "Hyderabad").
    final parentLower = parentStopName.toLowerCase().trim();
    final nextLower = nextStopName.toLowerCase().trim();
    final Set<String> excludeNames = {parentLower, nextLower};
    // Add pickup and destination address components (split by comma)
    final pickupName = _trackingData?.pickup.name ?? '';
    final dropName = _trackingData?.drop.name ?? '';
    for (final addr in [pickupName, dropName]) {
      for (final part in addr.split(',')) {
        final p = part.trim().toLowerCase();
        if (p.isNotEmpty) excludeNames.add(p);
      }
    }
    final subStops = rawSubStops.where((s) {
      final n = (s['name'] as String? ?? '').toLowerCase().trim();
      if (n.isEmpty) return false;
      return !excludeNames.contains(n);
    }).toList();
    if (subStops.isEmpty) return const SizedBox.shrink();

    // Parse parent and next stop times for interpolation
    DateTime? parentDt = _tryParseDisplayTime(parentTime);
    DateTime? nextDt = _tryParseDisplayTime(nextStopTime);

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Column(
        children: List.generate(subStops.length, (idx) {
          final sub = subStops[idx];
          String subTime = '-';

          // Use API time if available (passed substops from backend)
          final apiSubTime = sub['api_time'] as String?;

          // Resolve this substop's coordinates. Generated (upcoming) substops
          // carry a 'location' LatLng; API substops carry lat/lng.
          LatLng? subLatLng;
          final loc = sub['location'];
          if (loc is LatLng) {
            subLatLng = loc;
          } else if (sub['lat'] != null && sub['lng'] != null) {
            subLatLng = LatLng(
              (sub['lat'] as num).toDouble(),
              (sub['lng'] as num).toDouble(),
            );
          }
          final driverPos = _currentLatLng ?? _pickupLatLng;

          if (apiSubTime != null && apiSubTime.isNotEmpty) {
            subTime = apiSubTime;
          }
          // Upcoming substop: compute ETA from the CURRENT driver position and
          // live speed (now + straight-line distance / speed) so the time
          // reflects where the driver is right now — not the journey start.
          else if (subLatLng != null && driverPos != null) {
            final distKm = _haversineDistance(driverPos, subLatLng) / 1000;
            final spd = _trackingData?.driverLocation.speedKmh ?? 0;
            final avgSpeed = spd > 5 ? spd : 40.0;
            final etaMin = (distKm / avgSpeed * 60).round().clamp(1, 99999);
            var subDt = DateTime.now().add(Duration(minutes: etaMin));
            // Keep ordering sane: never later than the next stop's time.
            if (nextDt != null && subDt.isAfter(nextDt)) {
              subDt = nextDt.subtract(const Duration(minutes: 1));
            }
            subTime = _formatDateTimeObj(subDt);
          }
          // Fallback: interpolate between parentTime and nextStopTime
          else if (parentDt != null && nextDt != null && nextDt.isAfter(parentDt)) {
            final totalMs = nextDt.difference(parentDt).inMilliseconds;
            final fraction = (idx + 1) / (subStops.length + 1);
            final subDt = parentDt.add(Duration(milliseconds: (totalMs * fraction).round()));
            subTime = _formatDateTimeObj(subDt);
          } else if (parentDt != null && nextDt != null && parentDt == nextDt) {
            subTime = parentTime;
          } else if (parentDt != null) {
            final subDt = parentDt.add(Duration(minutes: 15 * (idx + 1)));
            subTime = _formatDateTimeObj(subDt);
          }

          return _buildSubTimelineItem(
            width,
            height,
            sub['name'],
            subTime,
            lineColor,
          );
        }),
      ),
    );
  }

  /// Try to parse a display time like "12:29 PM" or "3:41 PM, 21/05/2026" into DateTime.
  DateTime? _tryParseDisplayTime(String timeStr) {
    if (timeStr == '-' || timeStr.isEmpty) return null;
    try {
      // Format: "HH:MM AM/PM" or "H:MM AM/PM"
      final clean = timeStr.split(',').first.trim();
      final parts = clean.split(' ');
      if (parts.length < 2) return null;
      final timeParts = parts[0].split(':');
      if (timeParts.length < 2) return null;
      int hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);
      final ampm = parts[1].toUpperCase();
      if (ampm == 'PM' && hour != 12) hour += 12;
      if (ampm == 'AM' && hour == 12) hour = 0;
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day, hour, minute);
    } catch (_) {
      return null;
    }
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
      // `.toLocal()` converts the parsed UTC/offset timestamp into the
      // device's local timezone. Without it, an ISO string like
      // "2026-05-19T11:31:00+00:00" would render as 11:31 AM regardless of
      // where the customer is — which is why passed stops were showing
      // 11:31 AM (UTC) instead of 5:01 PM IST today.
      final dateTime = DateTime.parse(dateTimeStr).toLocal();
      final hour = dateTime.hour > 12 ? dateTime.hour - 12 : (dateTime.hour == 0 ? 12 : dateTime.hour);
      final amPm = dateTime.hour >= 12 ? 'PM' : 'AM';
      return '${hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} $amPm';
    } catch (e) {
      // Handle short time format like "13:41" from in_progress_at
      if (dateTimeStr.contains(':') && !dateTimeStr.contains('-')) {
        return _format24to12(dateTimeStr);
      }
      return '-';
    }
  }

  String _formatDate(String? dateTimeStr) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(dateTimeStr).toLocal();
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
    final local = dateTime.isUtc ? dateTime.toLocal() : dateTime;
    final hour = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    final amPm = local.hour >= 12 ? 'PM' : 'AM';
    return '${hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')} $amPm';
  }

  /// Returns a meaningful location name for the driver.
  /// Falls back to the nearest stop name when the API returns empty/generic text.
  String _resolveDriverLocationName() {
    final driverLoc = _trackingData?.driverLocation;
    if (driverLoc == null) return 'Current Location';

    // If backend returned a real address, use it
    final name = driverLoc.name;
    if (name.isNotEmpty &&
        name != 'Location not available' &&
        name != 'N/A') {
      return name;
    }

    // Fallback: find nearest from stops, pickup, and destination
    final driverPos = _currentLatLng ?? _pickupLatLng;
    if (driverPos != null) {
      String? nearestName;
      double minDist = double.infinity;

      // Check all fixed stops
      for (final stop in _fixedStops) {
        final sLat = (stop['lat'] as num?)?.toDouble();
        final sLng = (stop['lng'] as num?)?.toDouble();
        if (sLat == null || sLng == null) continue;
        final d = _haversineDistance(driverPos, LatLng(sLat, sLng));
        if (d < minDist) {
          minDist = d;
          nearestName = stop['name'] as String?;
        }
      }

      // Check destination
      if (_destinationLatLng != null) {
        final destDist = _haversineDistance(driverPos, _destinationLatLng!);
        if (destDist < minDist) {
          minDist = destDist;
          nearestName = _trackingData?.drop.name.split(',').first.trim();
        }
      }

      // Check pickup
      if (_pickupLatLng != null) {
        final pickupDist = _haversineDistance(driverPos, _pickupLatLng!);
        if (pickupDist < minDist) {
          minDist = pickupDist;
          nearestName = _trackingData?.pickup.name.split(',').first.trim();
        }
      }

      if (nearestName != null && nearestName.isNotEmpty) {
        return 'Near $nearestName';
      }
    }

    // Last fallback: use pickup area name
    final pickupFirst = _trackingData?.pickup.name.split(',').first.trim() ?? '';
    if (pickupFirst.isNotEmpty) return 'Near $pickupFirst';

    return 'Current Location';
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
    // The connector line below this item is green only when BOTH this
    // item AND the next item are passed. Without this parameter, the
    // connector below "Pickup started from" (always passed) was always
    // green — visually reaching down into the next stop and making
    // customers think the truck had progressed there. Default false so
    // legacy callers stay safe (line will be grey unless they opt in).
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
                  // Connector line is green only when BOTH the item
                  // above AND the item below are passed. If only the
                  // top item is passed, the line shows grey — so the
                  // green trail visually stops at the last passed
                  // stop and doesn't bleed into the next (unpassed)
                  // stop's icon.
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
    print("checking for last update $lastUpdateDate");
    print("checking for last update $lastUpdateTime");
    // Get location name — resolve from nearest stop if API didn't geocode
    String locationName = _resolveDriverLocationName();

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
    final controller = _isMapExpanded ? _expandedMapController : _smallMapController;
    if (controller == null) return;

    // Re-enable follow mode
    setState(() => _isFollowingVehicle = true);

    // If no current location, fit to all markers instead
    if (_currentLatLng == null) {
      if (_isMapExpanded) {
        _fitExpandedMapToAllMarkers();
      } else {
        _fitSmallMapToAllMarkers();
      }
      return;
    }

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
      ).then((_) => _isProgrammaticCameraMove = false);
    } catch (e) {
      _isProgrammaticCameraMove = false;
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
