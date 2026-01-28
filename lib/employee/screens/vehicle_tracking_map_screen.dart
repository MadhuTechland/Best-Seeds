import 'dart:math';

import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/utils/custom_marker_helper.dart';
import 'package:bestseeds/utils/google_maps_service.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

class VehicleTrackingMapScreen extends StatefulWidget {
  final Booking booking;

  const VehicleTrackingMapScreen({
    super.key,
    required this.booking,
  });

  @override
  State<VehicleTrackingMapScreen> createState() =>
      _VehicleTrackingMapScreenState();
}

class _VehicleTrackingMapScreenState extends State<VehicleTrackingMapScreen> {
  // Separate controllers for small and expanded maps
  GoogleMapController? _smallMapController;
  GoogleMapController? _expandedMapController;

  // Default location (Hyderabad, India)
  static const LatLng _defaultLocation = LatLng(17.3850, 78.4867);

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

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    final currentLoc = widget.booking.currentLocation;

    // Get current vehicle position from API
    if (currentLoc != null &&
        currentLoc.lat != null &&
        currentLoc.lng != null) {
      _currentVehiclePosition = LatLng(currentLoc.lat!, currentLoc.lng!);
    } else {
      _currentVehiclePosition = _defaultLocation;
    }

    // Set initial camera position - will be updated to fit all markers
    _initialPosition = CameraPosition(
      target: _currentVehiclePosition,
      zoom: 10.0, // Lower zoom to show more area initially
    );

    // Load custom markers first (both sizes)
    await _loadCustomMarkers();

    // Then setup markers and routes
    await _setupMarkersAndPolylines();
  }

  Future<void> _loadCustomMarkers() async {
    // Small map markers (smaller size for compact view)
    _smallTruckMarker =
        await CustomMarkerHelper.getTruckMarkerFromAsset(size: 30);
    _smallPickupMarker =
        await CustomMarkerHelper.getStartLocationMarkerFromAsset(size: 26);
    _smallDestinationMarker =
        await CustomMarkerHelper.getDropLocationMarkerFromAsset(size: 26);

    // Expanded map markers (bigger size for full screen view)
    _expandedTruckMarker =
        await CustomMarkerHelper.getTruckMarkerFromAsset(size: 60);
    _expandedPickupMarker =
        await CustomMarkerHelper.getStartLocationMarkerFromAsset(size: 30);
    _expandedDestinationMarker =
        await CustomMarkerHelper.getDropLocationMarkerFromAsset(size: 30);
  }

  Future<void> _setupMarkersAndPolylines() async {
    final pickup = widget.booking.pickup;
    final currentLoc = widget.booking.currentLocation;
    final destination = widget.booking.destination;

    Set<Polyline> polylines = {};

    /// -------- Get Pickup Coordinates --------
    if (pickup?.lat != null && pickup?.lng != null) {
      _pickupLatLng = LatLng(pickup!.lat!, pickup.lng!);
    } else if (pickup?.locationName != null) {
      _pickupLatLng =
          await GoogleMapsService.geocodeAddress(pickup!.locationName!);
    }

    /// -------- Get Current Location Coordinates --------
    if (currentLoc?.lat != null && currentLoc?.lng != null) {
      _currentLatLng = LatLng(currentLoc!.lat!, currentLoc.lng!);
    }

    /// -------- Get Destination Coordinates --------
    if (destination?.lat != null && destination?.lng != null) {
      _destinationLatLng = LatLng(destination!.lat!, destination.lng!);
    } else if (destination?.locationName != null) {
      _destinationLatLng =
          await GoogleMapsService.geocodeAddress(destination!.locationName!);
    }

    // Build markers for both small and expanded views
    _buildMarkers();

    /// -------- Routes using Directions API --------

    // Route from Pickup to Current Location (completed path - green)
    if (_pickupLatLng != null && _currentLatLng != null) {
      final routePoints = await GoogleMapsService.getDirections(
        origin: _pickupLatLng!,
        destination: _currentLatLng!,
      );

      if (routePoints.isNotEmpty) {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('pickup_to_current'),
            points: routePoints,
            color: Colors.green,
            width: 5,
            patterns: [], // Solid line for completed path
          ),
        );
      } else {
        // Fallback to straight line if directions API fails
        polylines.add(
          Polyline(
            polylineId: const PolylineId('pickup_to_current'),
            points: [_pickupLatLng!, _currentLatLng!],
            color: Colors.green,
            width: 4,
          ),
        );
      }
    }

    // Route from Current Location to Destination (remaining path - blue dashed)
    if (_currentLatLng != null && _destinationLatLng != null) {
      final routePoints = await GoogleMapsService.getDirections(
        origin: _currentLatLng!,
        destination: _destinationLatLng!,
      );

      if (routePoints.isNotEmpty) {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('current_to_destination'),
            points: routePoints,
            color: const Color(0xFF0077C8),
            width: 5,
            patterns: [
              PatternItem.dash(20),
              PatternItem.gap(10),
            ], // Dashed line for remaining path
          ),
        );
      } else {
        // Fallback to straight line if directions API fails
        polylines.add(
          Polyline(
            polylineId: const PolylineId('current_to_destination'),
            points: [_currentLatLng!, _destinationLatLng!],
            color: const Color(0xFF0077C8),
            width: 4,
            patterns: [
              PatternItem.dash(20),
              PatternItem.gap(10),
            ],
          ),
        );
      }
    }

    // If no current location, show full route from pickup to destination
    if (_currentLatLng == null &&
        _pickupLatLng != null &&
        _destinationLatLng != null) {
      final routePoints = await GoogleMapsService.getDirections(
        origin: _pickupLatLng!,
        destination: _destinationLatLng!,
      );

      if (routePoints.isNotEmpty) {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('full_route'),
            points: routePoints,
            color: const Color(0xFF0077C8),
            width: 5,
            patterns: [
              PatternItem.dash(20),
              PatternItem.gap(10),
            ],
          ),
        );
      } else {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('full_route'),
            points: [_pickupLatLng!, _destinationLatLng!],
            color: const Color(0xFF0077C8),
            width: 4,
          ),
        );
      }
    }

    // Calculate initial camera position to show full route
    _calculateInitialCameraPosition();

    setState(() {
      _polylines = polylines;
      _isLoadingRoute = false;
    });
  }

  /// Build markers for both small and expanded map views
  void _buildMarkers() {
    final pickup = widget.booking.pickup;
    final currentLoc = widget.booking.currentLocation;
    final destination = widget.booking.destination;

    Set<Marker> smallMarkers = {};
    Set<Marker> expandedMarkers = {};

    /// -------- Pickup Markers --------
    if (_pickupLatLng != null) {
      smallMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickupLatLng!,
          icon: _smallPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(
            title: 'Pickup',
            snippet: pickup?.locationName,
          ),
        ),
      );
      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickupLatLng!,
          icon: _expandedPickupMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(
            title: 'Pickup',
            snippet: pickup?.locationName,
          ),
        ),
      );
    }

    /// -------- Current/Truck Markers --------
    if (_currentLatLng != null) {
      smallMarkers.add(
        Marker(
          markerId: const MarkerId('vehicle'),
          position: _currentLatLng!,
          icon: _smallTruckMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(
            title: 'Vehicle Location',
            snippet: currentLoc?.locationName ?? 'Current Position',
          ),
          anchor: const Offset(0.5, 0.5),
        ),
      );
      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('vehicle'),
          position: _currentLatLng!,
          icon: _expandedTruckMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(
            title: 'Vehicle Location',
            snippet: currentLoc?.locationName ?? 'Current Position',
          ),
          anchor: const Offset(0.5, 0.5),
        ),
      );
    }

    /// -------- Destination Markers --------
    if (_destinationLatLng != null) {
      smallMarkers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: _destinationLatLng!,
          icon: _smallDestinationMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Destination',
            snippet: destination?.locationName,
          ),
        ),
      );
      expandedMarkers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: _destinationLatLng!,
          icon: _expandedDestinationMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Destination',
            snippet: destination?.locationName,
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
      _initialPosition = CameraPosition(
        target: points.first,
        zoom: 14.0,
      );
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
              child: _isMapExpanded
                  ? _buildExpandedMapView(width, height)
                  : _buildDefaultView(width, height),
            ),
          ],
        ),
      ),
    );
  }

  /// Default view with small map + details + timeline
  Widget _buildDefaultView(double width, double height) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// Map Section (clickable to expand)
          _buildSmallMapSection(width, height),

          /// Content Section
          Padding(
            padding: EdgeInsets.all(width * 0.05),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDriverDetails(width, height),
                SizedBox(height: height * 0.025),
                _buildVehicleStatus(width, height),
                SizedBox(height: height * 0.01),
                _buildDeliveryInfo(width, height),
                SizedBox(height: height * 0.025),
                _buildLocationTimeline(width, height),
              ],
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
          padding: EdgeInsets.only(
            bottom: height * 0.16, // space for Last Update card
            right: width * 0.02,
            top: height * 0.02,
          ),
          onMapCreated: (GoogleMapController controller) {
            _expandedMapController = controller;
            // Fit to show all markers after map is created
            Future.delayed(const Duration(milliseconds: 300), () {
              _fitExpandedMapToAllMarkers();
            });
          },
        ),

        // Loading indicator for route
        if (_isLoadingRoute)
          const Center(
            child: CircularProgressIndicator(
              color: Color(0xFF0077C8),
            ),
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
            southwest:
                LatLng(minLat - actualLatPadding, minLng - actualLngPadding),
            northeast:
                LatLng(maxLat + actualLatPadding, maxLng + actualLngPadding),
          ),
          60, // Padding in pixels
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
            southwest:
                LatLng(minLat - actualLatPadding, minLng - actualLngPadding),
            northeast:
                LatLng(maxLat + actualLatPadding, maxLng + actualLngPadding),
          ),
          40, // Less padding for small map
        ),
      );
    } catch (e) {
      debugPrint('Error fitting small map to markers: $e');
    }
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
              if (_isMapExpanded) {
                setState(() {
                  _isMapExpanded = false;
                });
              } else {
                Navigator.pop(context);
              }
            },
            child: Icon(
              Icons.arrow_back,
              size: width * 0.06,
              color: Colors.black,
            ),
          ),
          SizedBox(width: width * 0.04),
          Text(
            'Vehicle tracking',
            style: TextStyle(
              fontSize: width * 0.048,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallMapSection(double width, double height) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _isMapExpanded = true;
        });
      },
      child: Container(
        height: height * 0.22,
        margin: EdgeInsets.all(width * 0.04),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              GoogleMap(
                mapType: MapType.normal,
                initialCameraPosition: _initialPosition,
                markers: _smallMapMarkers,
                polylines: _polylines,
                myLocationEnabled: false,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: true,
                mapToolbarEnabled: true,
                scrollGesturesEnabled: true,
                zoomGesturesEnabled: true,
                rotateGesturesEnabled: true,
                tiltGesturesEnabled: true,
                onMapCreated: (GoogleMapController controller) {
                  _smallMapController = controller;
                  // Fit to show all markers after map is created
                  Future.delayed(const Duration(milliseconds: 300), () {
                    _fitSmallMapToAllMarkers();
                  });
                },
              ),
              // Loading overlay
              if (_isLoadingRoute)
                Container(
                  color: Colors.white.withValues(alpha: 0.7),
                  child: const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF0077C8),
                    ),
                  ),
                ),
              // Layers icon
              Positioned(
                top: width * 0.03,
                left: width * 0.03,
                child: Container(
                  padding: EdgeInsets.all(width * 0.02),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.layers,
                    size: width * 0.045,
                    color: Colors.black,
                  ),
                ),
              ),
              // Expand icon
              Positioned(
                top: width * 0.03,
                right: width * 0.03,
                child: Container(
                  padding: EdgeInsets.all(width * 0.02),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.fullscreen,
                    size: width * 0.045,
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDriverDetails(double width, double height) {
    final driver = widget.booking.driverDetails;
    final driverName = driver.name.isNotEmpty ? driver.name : 'Not assigned';
    final driverMobile =
        driver.mobile.isNotEmpty ? '+91${driver.mobile}' : 'N/A';
    final vehicleNumber =
        driver.vehicleNumber.isNotEmpty ? driver.vehicleNumber : 'N/A';

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
          spacing: width * 0.08, // horizontal spacing
          runSpacing: height * 0.016, // vertical spacing between rows
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
        Icon(
          icon,
          size: width * 0.05,
          color: Colors.grey.shade700,
        ),
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
    final status = widget.booking.status;
    String statusMessage;

    if (status.isCompleted) {
      statusMessage = 'Your delivery has been completed successfully.';
    } else if (status.isDelivered) {
      statusMessage = 'Your order is out for delivery.';
    } else if (status.isInProgress) {
      statusMessage = 'Vehicle is on the way to the destination.';
    } else if (status.isAccepted) {
      statusMessage =
          'Your booking has been confirmed. Vehicle will start soon.';
    } else {
      statusMessage =
          'We\'ve received your booking. Within a few days, we will assign your vehicle';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Vehicle Status',
          style: TextStyle(
            fontSize: width * 0.042,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: height * 0.01),
        Text(
          statusMessage,
          style: TextStyle(
            fontSize: width * 0.036,
            color: Colors.grey.shade700,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildDeliveryInfo(double width, double height) {
    String deliveryText = '';

    if (widget.booking.deliveryDatetime != null) {
      try {
        final deliveryDate = DateTime.parse(widget.booking.deliveryDatetime!);
        deliveryText =
            'Delivery Expected on ${DateFormat('dd/MM/yyyy').format(deliveryDate)}';
      } catch (e) {
        deliveryText =
            'Delivery Expected on ${widget.booking.deliveryDatetime}';
      }
    } else if (widget.booking.preferredDate != null) {
      try {
        final preferredDate = DateTime.parse(widget.booking.preferredDate!);
        deliveryText =
            'Delivery Expected on ${DateFormat('dd/MM/yyyy').format(preferredDate)}';
      } catch (e) {
        deliveryText = 'Delivery Expected on ${widget.booking.preferredDate}';
      }
    }

    if (deliveryText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Text(
      deliveryText,
      style: TextStyle(
        fontSize: width * 0.036,
        color: Colors.grey.shade700,
      ),
    );
  }

  Widget _buildLocationTimeline(double width, double height) {
    final pickup = widget.booking.pickup;
    final currentLoc = widget.booking.currentLocation;
    final destination = widget.booking.destination;

    // Determine if journey has started
    final hasStarted = pickup?.vehicleStartedDate != null;
    final hasCurrentLocation =
        currentLoc?.lat != null && currentLoc?.lng != null;

    // Build timeline items dynamically
    List<Widget> timelineItems = [];

    // Pickup location
    timelineItems.add(
      _buildTimelineItem(
        width,
        height,
        Icons.location_on,
        hasStarted ? Colors.green : Colors.grey,
        'Pickup started from',
        pickup?.locationName ?? widget.booking.hatcheryName,
        _formatDateTime(pickup?.vehicleStartedDate),
        isFirst: true,
        isLast: !hasCurrentLocation && destination == null,
      ),
    );

    // Current location (if vehicle is in transit)
    if (hasCurrentLocation) {
      timelineItems.add(
        _buildTimelineItem(
          width,
          height,
          Icons.local_shipping, // Truck icon for timeline too
          Colors.green,
          currentLoc?.locationName ?? 'Current Location',
          _formatDate(currentLoc?.updatedAt),
          _formatDateTime(currentLoc?.updatedAt),
          isLast: destination == null,
        ),
      );
    }

    // Destination
    timelineItems.add(
      _buildTimelineItem(
        width,
        height,
        Icons.flag,
        widget.booking.status.isCompleted ? Colors.green : Colors.grey,
        'Destination',
        destination?.locationName ?? widget.booking.droppingLocation,
        widget.booking.status.isCompleted ? 'Delivered' : '-',
        isLast: true,
      ),
    );

    return Column(children: timelineItems);
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
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: width * 0.08,
              height: width * 0.08,
              decoration: BoxDecoration(
                color: iconColor == Colors.green
                    ? Colors.green
                    : Colors.grey.shade400,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: width * 0.045,
                color: Colors.white,
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: height * 0.05,
                color: Colors.grey.shade300,
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
                          style: TextStyle(
                            fontSize: width * 0.038,
                            fontWeight: FontWeight.w600,
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
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: width * 0.036,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              if (!isLast) SizedBox(height: height * 0.01),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLastUpdateCard(double width, double height) {
    final currentLoc = widget.booking.currentLocation;
    final hasCurrentLocation =
        currentLoc != null && currentLoc.lat != null && currentLoc.lng != null;

    // Format the last update time
    String lastUpdateTime = '-';
    String lastUpdateDate = '';
    if (currentLoc?.updatedAt != null) {
      try {
        final dateTime = DateTime.parse(currentLoc!.updatedAt!);
        lastUpdateTime = DateFormat('hh:mm a').format(dateTime);
        lastUpdateDate = DateFormat('dd/MM/yyyy').format(dateTime);
      } catch (e) {
        lastUpdateTime = '-';
      }
    }

    // Get location name
    String locationName = currentLoc?.locationName ?? 'Location not available';

    return Container(
      padding: EdgeInsets.all(width * 0.04),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Last Update Title
          Text(
            'Last Update',
            style: TextStyle(
              fontSize: width * 0.04,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          SizedBox(height: height * 0.015),

          // Status indicator and time
          Row(
            children: [
              // Green dot indicator
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: hasCurrentLocation ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: width * 0.03),
              // Time and date
              Text(
                '$lastUpdateTime, $lastUpdateDate',
                style: TextStyle(
                  fontSize: width * 0.038,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: height * 0.01),

          // Location name
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: width * 0.055), // Align with text above
              Expanded(
                child: Text(
                  locationName,
                  style: TextStyle(
                    fontSize: width * 0.035,
                    color: Colors.grey.shade600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDateTime(String? dateTimeStr) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '-';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      return DateFormat('hh:mm a').format(dateTime);
    } catch (e) {
      return '-';
    }
  }

  String _formatDate(String? dateTimeStr) {
    if (dateTimeStr == null || dateTimeStr.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      return DateFormat('dd/MM/yyyy').format(dateTime);
    } catch (e) {
      return '';
    }
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
          CameraPosition(
            target: _currentLatLng!,
            zoom: 15.0,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error centering on vehicle: $e');
    }
  }

  @override
  void dispose() {
    _smallMapController?.dispose();
    _expandedMapController?.dispose();
    super.dispose();
  }
}
