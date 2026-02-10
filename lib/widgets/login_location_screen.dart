import 'package:bestseeds/widgets/location_selector_screen.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// Screen shown after login to select/confirm user location
/// Used by both Driver and Employee login flows
class LoginLocationScreen extends StatefulWidget {
  final Function(LocationData location) onLocationSelected;
  final String userType; // 'driver' or 'employee'

  const LoginLocationScreen({
    super.key,
    required this.onLocationSelected,
    this.userType = 'driver',
  });

  @override
  State<LoginLocationScreen> createState() => _LoginLocationScreenState();
}

class _LoginLocationScreenState extends State<LoginLocationScreen> {
  bool _isLoading = false;
  LocationData? _selectedLocation;

  @override
  void initState() {
    super.initState();
    // Auto-fetch current location on screen load
    _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _isLoading = false;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _isLoading = false;
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Get address from coordinates
      String address = await _getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );

      setState(() {
        _selectedLocation = LocationData(
          latitude: position.latitude,
          longitude: position.longitude,
          address: address,
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      debugPrint('Error getting location: $e');
    }
  }

  Future<String> _getAddressFromCoordinates(double lat, double lng) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        List<String> parts = [];
        if (place.subLocality?.isNotEmpty == true)
          parts.add(place.subLocality!);
        if (place.locality?.isNotEmpty == true) parts.add(place.locality!);
        if (place.administrativeArea?.isNotEmpty == true) {
          parts.add(place.administrativeArea!);
        }
        if (parts.isNotEmpty) return parts.join(', ');
      }
    } catch (e) {
      debugPrint('Geocoding error: $e');
    }
    return 'Lat: ${lat.toStringAsFixed(4)}, Lng: ${lng.toStringAsFixed(4)}';
  }

  void _selectFromMap() async {
    final result = await LocationSelector.show(
      context: context,
      initialLatitude: _selectedLocation?.latitude,
      initialLongitude: _selectedLocation?.longitude,
    );

    if (result != null) {
      setState(() {
        _selectedLocation = result;
      });
    }
  }

  void _confirmLocation() {
    if (_selectedLocation != null) {
      widget.onLocationSelected(_selectedLocation!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      body: SingleChildScrollView(
        child: Container(
          width: width,
          height: height,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0xFF0077C8),
                Color(0xFF3FA9F5),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                /// Header
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: width * 0.06,
                    vertical: height * 0.02,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Set Your Location',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: width * 0.055,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

                /// Content
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: width * 0.06),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.location_on,
                          size: width * 0.25,
                          color: Colors.white,
                        ),
                        SizedBox(height: height * 0.03),
                        Text(
                          'Where are you located?',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: width * 0.06,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: height * 0.015),
                        Text(
                          'We need your location to show you\nrelevant bookings and services',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: width * 0.04,
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),

                /// Bottom Card
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    horizontal: width * 0.06,
                    vertical: height * 0.035,
                  ),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      /// Current Location Display
                      if (_isLoading)
                        Padding(
                          padding:
                              EdgeInsets.symmetric(vertical: height * 0.02),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF0077C8),
                                ),
                              ),
                              SizedBox(width: width * 0.03),
                              Text(
                                'Getting your location...',
                                style: TextStyle(
                                  fontSize: width * 0.04,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (_selectedLocation != null)
                        Container(
                          padding: EdgeInsets.all(width * 0.04),
                          margin: EdgeInsets.only(bottom: height * 0.02),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0077C8)
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.location_on,
                                  color: Color(0xFF0077C8),
                                ),
                              ),
                              SizedBox(width: width * 0.03),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Your Location',
                                      style: TextStyle(
                                        fontSize: width * 0.035,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    SizedBox(height: height * 0.005),
                                    Text(
                                      _selectedLocation!.address,
                                      style: TextStyle(
                                        fontSize: width * 0.04,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                      /// Use Current Location Button
                      SizedBox(
                        width: double.infinity,
                        height: height * 0.06,
                        child: OutlinedButton.icon(
                          onPressed: _isLoading ? null : _getCurrentLocation,
                          icon: const Icon(Icons.my_location),
                          label: const Text('Use Current Location'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF0077C8),
                            side: const BorderSide(color: Color(0xFF0077C8)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: height * 0.015),

                      /// Select from Map Button
                      SizedBox(
                        width: double.infinity,
                        height: height * 0.06,
                        child: OutlinedButton.icon(
                          onPressed: _isLoading ? null : _selectFromMap,
                          icon: const Icon(Icons.map_outlined),
                          label: const Text('Select from Map'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF0077C8),
                            side: const BorderSide(color: Color(0xFF0077C8)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: height * 0.025),

                      /// Continue Button
                      SizedBox(
                        width: double.infinity,
                        height: height * 0.06,
                        child: ElevatedButton(
                          onPressed: _selectedLocation == null || _isLoading
                              ? null
                              : _confirmLocation,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _selectedLocation != null
                                ? const Color(0xFF0077C8)
                                : const Color(0xFF0077C8)
                                    .withValues(alpha: 0.4),
                            disabledBackgroundColor:
                                const Color(0xFF0077C8).withValues(alpha: 0.4),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            'Continue',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: _selectedLocation != null
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: height * 0.02),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
