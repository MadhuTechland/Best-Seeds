import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';

class VehicleTrackingMapScreen extends StatefulWidget {
  final String bookingId;
  final String title;
  final String driverName;
  final String vehicleNumber;

  const VehicleTrackingMapScreen({
    super.key,
    required this.bookingId,
    required this.title,
    required this.driverName,
    required this.vehicleNumber,
  });

  @override
  State<VehicleTrackingMapScreen> createState() => _VehicleTrackingMapScreenState();
}

class _VehicleTrackingMapScreenState extends State<VehicleTrackingMapScreen> {
  final Completer<GoogleMapController> _controller = Completer();

  // Default location (Hyderabad, India)
  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(17.3850, 78.4867),
    zoom: 13.0,
  );

  // Sample route coordinates (Hyderabad area)
  final List<LatLng> _routeCoordinates = [
    const LatLng(17.3850, 78.4867), // Start - Seven Star Hatchery
    const LatLng(17.3900, 78.4900),
    const LatLng(17.3950, 78.4950),
    const LatLng(17.4000, 78.5000), // End
  ];

  // Current vehicle position
  LatLng _currentPosition = const LatLng(17.3950, 78.4950);

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  void _initializeMap() {
    // Add markers
    _markers = {
      Marker(
        markerId: const MarkerId('start'),
        position: _routeCoordinates.first,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: const InfoWindow(title: 'Pickup Location'),
      ),
      Marker(
        markerId: const MarkerId('vehicle'),
        position: _currentPosition,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: InfoWindow(
          title: 'Vehicle: ${widget.vehicleNumber}',
          snippet: 'Driver: ${widget.driverName}',
        ),
      ),
      Marker(
        markerId: const MarkerId('destination'),
        position: _routeCoordinates.last,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: const InfoWindow(title: 'Destination'),
      ),
    };

    // Add polyline for route
    _polylines = {
      Polyline(
        polylineId: const PolylineId('route'),
        points: _routeCoordinates,
        color: const Color(0xFF0077C8),
        width: 5,
      ),
    };
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

            /// ================= Map Section =================
            _buildMapSection(width, height),

            /// ================= Content Section =================
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(width * 0.05),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDriverDetails(width, height),
                    SizedBox(height: height * 0.025),
                    _buildVehicleStatus(width, height),
                    SizedBox(height: height * 0.025),
                    _buildDeliveryInfo(width, height),
                    SizedBox(height: height * 0.025),
                    _buildLocationTimeline(width, height),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

  Widget _buildMapSection(double width, double height) {
    return Container(
      height: height * 0.25,
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
              markers: _markers,
              polylines: _polylines,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              onMapCreated: (GoogleMapController controller) {
                _controller.complete(controller);
              },
            ),
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
                  size: width * 0.05,
                  color: Colors.black,
                ),
              ),
            ),
            Positioned(
              bottom: width * 0.03,
              right: width * 0.03,
              child: GestureDetector(
                onTap: _centerOnVehicle,
                child: Container(
                  padding: EdgeInsets.all(width * 0.025),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0077C8),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.my_location,
                    size: width * 0.05,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverDetails(double width, double height) {
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
        Row(
          children: [
            Icon(
              Icons.person_outline,
              size: width * 0.05,
              color: Colors.grey.shade700,
            ),
            SizedBox(width: width * 0.03),
            Text(
              widget.driverName,
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey.shade800,
              ),
            ),
            SizedBox(width: width * 0.06),
            Icon(
              Icons.phone_outlined,
              size: width * 0.05,
              color: Colors.grey.shade700,
            ),
            SizedBox(width: width * 0.03),
            Text(
              '+91xxxxxxxxx',
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey.shade800,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.local_shipping_outlined,
              size: width * 0.05,
              color: Colors.grey.shade700,
            ),
            SizedBox(width: width * 0.02),
            Text(
              widget.vehicleNumber,
              style: TextStyle(
                fontSize: width * 0.04,
                color: Colors.grey.shade800,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVehicleStatus(double width, double height) {
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
        SizedBox(height: height * 0.015),
        Text(
          'We\'ve received your booking. Within a few days, we will assign your vehicle',
          style: TextStyle(
            fontSize: width * 0.038,
            color: Colors.grey.shade700,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildDeliveryInfo(double width, double height) {
    return Text(
      'Delivery Expected on 27/06/2025',
      style: TextStyle(
        fontSize: width * 0.038,
        color: Colors.grey.shade700,
      ),
    );
  }

  Widget _buildLocationTimeline(double width, double height) {
    return Column(
      children: [
        _buildTimelineItem(
          width,
          height,
          Icons.location_on,
          Colors.green,
          'Pickup started from',
          'Seven Star Hatchery',
          '2:30 PM',
          isFirst: true,
        ),
        _buildTimelineItem(
          width,
          height,
          Icons.circle,
          Colors.green,
          'Kakinada',
          '24/06/2025',
          '10:30 PM',
        ),
        _buildTimelineItem(
          width,
          height,
          Icons.location_on_outlined,
          Colors.grey,
          'Vizag',
          null,
          '-',
        ),
        _buildTimelineItem(
          width,
          height,
          Icons.location_on_outlined,
          Colors.grey,
          'Vijayawada',
          null,
          '-',
        ),
        _buildTimelineItem(
          width,
          height,
          Icons.location_on,
          Colors.grey,
          'Destination',
          'Amalapuram',
          '-',
          isLast: true,
        ),
      ],
    );
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
                color: iconColor == Colors.green ? Colors.green : Colors.grey.shade400,
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
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: width * 0.04,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: width * 0.035,
                            color: Colors.grey.shade600,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: width * 0.038,
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


  void _centerOnVehicle() async {
    final GoogleMapController controller = await _controller.future;
    controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _currentPosition,
          zoom: 16.0,
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
