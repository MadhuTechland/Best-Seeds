import 'dart:async';
import 'dart:convert';

import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// Model class to hold location data
class LocationData {
  final double latitude;
  final double longitude;
  final String address;

  LocationData({
    required this.latitude,
    required this.longitude,
    required this.address,
  });

  @override
  String toString() =>
      'Lat: ${latitude.toStringAsFixed(6)}, Lng: ${longitude.toStringAsFixed(6)}';
}

/// Model for place predictions from Google Places API
class PlacePrediction {
  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;

  PlacePrediction({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
  });

  factory PlacePrediction.fromJson(Map<String, dynamic> json) {
    final structuredFormatting = json['structured_formatting'] ?? {};
    return PlacePrediction(
      placeId: json['place_id'] ?? '',
      description: json['description'] ?? '',
      mainText: structuredFormatting['main_text'] ?? '',
      secondaryText: structuredFormatting['secondary_text'] ?? '',
    );
  }
}

/// Reusable Location Selector
///
/// Usage:
/// ```dart
/// final result = await LocationSelector.show(
///   context: context,
///   initialLatitude: 20.5937,
///   initialLongitude: 78.9629,
/// );
///
/// if (result != null) {
///   print('Selected: ${result.latitude}, ${result.longitude}');
/// }
/// ```
class LocationSelector {
  /// Shows the location selection bottom sheet
  /// Returns [LocationData] if a location is selected, null if cancelled
  static Future<LocationData?> show({
    required BuildContext context,
    double? initialLatitude,
    double? initialLongitude,
    Color primaryColor = const Color(0xFF0077C8),
  }) async {
    final result = await showModalBottomSheet<_LocationOption>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return _LocationOptionsSheet(primaryColor: primaryColor);
      },
    );

    if (result == null || !context.mounted) return null;

    if (result == _LocationOption.currentLocation) {
      return _getCurrentLocation(context, primaryColor);
    } else if (result == _LocationOption.selectFromMap) {
      return _selectLocationFromMap(
        context,
        initialLatitude,
        initialLongitude,
        primaryColor,
      );
    }

    return null;
  }

  static Future<LocationData?> _getCurrentLocation(
    BuildContext context,
    Color primaryColor,
  ) async {
    try {
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          AppSnackbar.error('Location permission denied');
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        AppSnackbar.error(
            'Location permissions are permanently denied. Please enable from settings.');
        return null;
      }

      // Show loading
      if (!context.mounted) return null;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Center(
          child: CircularProgressIndicator(color: primaryColor),
        ),
      );

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Get address from coordinates
      String address = await _getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (!context.mounted) return null;
      Navigator.pop(context); // Close loading dialog

      AppSnackbar.success('Current location selected');

      return LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        address: address,
      );
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog
      }
      AppSnackbar.error('Failed to get location. Please check your GPS and internet connection.');
      return null;
    }
  }

  static Future<String> _getAddressFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        latitude,
        longitude,
      );

      if (placemarks.isNotEmpty) {
        Placemark place = placemarks.first;
        List<String> addressParts = [];

        // Building number / House number
        if (place.subThoroughfare != null && place.subThoroughfare!.isNotEmpty) {
          addressParts.add(place.subThoroughfare!);
        }

        // Street name
        if (place.thoroughfare != null && place.thoroughfare!.isNotEmpty) {
          addressParts.add(place.thoroughfare!);
        } else if (place.street != null && place.street!.isNotEmpty) {
          addressParts.add(place.street!);
        }

        // Area / Neighborhood
        if (place.subLocality != null && place.subLocality!.isNotEmpty) {
          addressParts.add(place.subLocality!);
        }

        // City
        if (place.locality != null && place.locality!.isNotEmpty) {
          addressParts.add(place.locality!);
        }

        // State
        if (place.administrativeArea != null &&
            place.administrativeArea!.isNotEmpty) {
          addressParts.add(place.administrativeArea!);
        }

        // Postal code
        if (place.postalCode != null && place.postalCode!.isNotEmpty) {
          addressParts.add(place.postalCode!);
        }

        if (addressParts.isNotEmpty) {
          return addressParts.join(', ');
        }

        // Fallback to name if available
        if (place.name != null && place.name!.isNotEmpty) {
          return place.name!;
        }
      }
    } catch (e) {
      debugPrint('Geocoding error: $e');
    }

    return 'Lat: ${latitude.toStringAsFixed(6)}, Lng: ${longitude.toStringAsFixed(6)}';
  }

  static Future<LocationData?> _selectLocationFromMap(
    BuildContext context,
    double? initialLatitude,
    double? initialLongitude,
    Color primaryColor,
  ) async {
    if (!context.mounted) return null;

    return Navigator.push<LocationData>(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerScreen(
          initialLatitude: initialLatitude,
          initialLongitude: initialLongitude,
          primaryColor: primaryColor,
        ),
      ),
    );
  }

}

enum _LocationOption { currentLocation, selectFromMap }

class _LocationOptionsSheet extends StatelessWidget {
  final Color primaryColor;

  const _LocationOptionsSheet({required this.primaryColor});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    return Container(
      padding: EdgeInsets.all(width * 0.05),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          /// Drag Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          /// Title
          Text(
            'Select Location',
            style: TextStyle(
              fontSize: width * 0.048,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),

          /// Current Location Option
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.my_location, color: primaryColor),
            ),
            title: const Text('Use Current Location'),
            subtitle: const Text('Get your current GPS location'),
            onTap: () => Navigator.pop(context, _LocationOption.currentLocation),
          ),
          const Divider(),

          /// Select from Map Option
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.map, color: primaryColor),
            ),
            title: const Text('Select from Map'),
            subtitle: const Text('Choose location on map'),
            onTap: () => Navigator.pop(context, _LocationOption.selectFromMap),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// Location Picker Screen with Google Maps
class LocationPickerScreen extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;
  final Color primaryColor;

  const LocationPickerScreen({
    super.key,
    this.initialLatitude,
    this.initialLongitude,
    this.primaryColor = const Color(0xFF0077C8),
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  static const String _apiKey = 'AIzaSyA111b89Exrm83RRWF-2hP1EPeUxvos87I';

  GoogleMapController? _mapController;
  LatLng? _selectedLocation;
  String _address = 'Tap on map to select location';
  bool _isLoading = true;
  bool _isFetchingAddress = false;

  // Search related
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<PlacePrediction> _predictions = [];
  bool _isSearching = false;
  bool _showSearchResults = false;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  Future<void> _initLocation() async {
    if (widget.initialLatitude != null && widget.initialLongitude != null) {
      _selectedLocation =
          LatLng(widget.initialLatitude!, widget.initialLongitude!);
      await _fetchAddress(_selectedLocation!);
      setState(() {
        _isLoading = false;
      });
    } else {
      // Try to get current location
      try {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }

        if (permission == LocationPermission.whileInUse ||
            permission == LocationPermission.always) {
          final position = await Geolocator.getCurrentPosition();
          _selectedLocation = LatLng(position.latitude, position.longitude);
          await _fetchAddress(_selectedLocation!);
          setState(() {
            _isLoading = false;
          });
        } else {
          // Default to India center
          setState(() {
            _selectedLocation = const LatLng(20.5937, 78.9629);
            _address = 'Select a location on the map';
            _isLoading = false;
          });
        }
      } catch (e) {
        // Default to India center
        setState(() {
          _selectedLocation = const LatLng(20.5937, 78.9629);
          _address = 'Select a location on the map';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchAddress(LatLng location) async {
    setState(() {
      _isFetchingAddress = true;
    });

    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        location.latitude,
        location.longitude,
      );

      if (placemarks.isNotEmpty) {
        Placemark place = placemarks.first;

        // Debug: Print all placemark fields
        debugPrint('=== Geocoding Result ===');
        debugPrint('name: ${place.name}');
        debugPrint('street: ${place.street}');
        debugPrint('thoroughfare: ${place.thoroughfare}');
        debugPrint('subThoroughfare: ${place.subThoroughfare}');
        debugPrint('subLocality: ${place.subLocality}');
        debugPrint('locality: ${place.locality}');
        debugPrint('administrativeArea: ${place.administrativeArea}');
        debugPrint('postalCode: ${place.postalCode}');
        debugPrint('country: ${place.country}');
        debugPrint('========================');

        _address = _buildAddressFromPlacemark(place);
        debugPrint('Final address: $_address');
      } else {
        debugPrint('Geocoding returned empty placemarks');
        _address = _buildFallbackAddress(location);
      }
    } catch (e) {
      debugPrint('Geocoding error: $e');
      _address = _buildFallbackAddress(location);
    }

    if (mounted) {
      setState(() {
        _isFetchingAddress = false;
      });
    }
  }

  String _buildAddressFromPlacemark(Placemark place) {
    List<String> addressParts = [];

    // Building number / House number
    if (place.subThoroughfare != null && place.subThoroughfare!.isNotEmpty) {
      addressParts.add(place.subThoroughfare!);
    }

    // Street name
    if (place.thoroughfare != null && place.thoroughfare!.isNotEmpty) {
      addressParts.add(place.thoroughfare!);
    } else if (place.street != null && place.street!.isNotEmpty) {
      // Fallback to street if thoroughfare is empty
      addressParts.add(place.street!);
    }

    // Area / Neighborhood
    if (place.subLocality != null && place.subLocality!.isNotEmpty) {
      addressParts.add(place.subLocality!);
    }

    // City
    if (place.locality != null && place.locality!.isNotEmpty) {
      addressParts.add(place.locality!);
    }

    // State (optional - can be removed if too long)
    if (place.administrativeArea != null &&
        place.administrativeArea!.isNotEmpty) {
      addressParts.add(place.administrativeArea!);
    }

    // Postal code (optional)
    if (place.postalCode != null && place.postalCode!.isNotEmpty) {
      addressParts.add(place.postalCode!);
    }

    if (addressParts.isNotEmpty) {
      return addressParts.join(', ');
    }

    // If all fields are empty, try using name
    if (place.name != null && place.name!.isNotEmpty) {
      return place.name!;
    }

    return 'Unknown location';
  }

  String _buildFallbackAddress(LatLng location) {
    return 'Lat: ${location.latitude.toStringAsFixed(6)}, Lng: ${location.longitude.toStringAsFixed(6)}';
  }

  void _onMapTap(LatLng latLng) {
    setState(() {
      _selectedLocation = latLng;
    });
    _fetchAddress(latLng);
  }

  void _onConfirm() {
    if (_selectedLocation == null || _isFetchingAddress) return;

    final locationData = LocationData(
      latitude: _selectedLocation!.latitude,
      longitude: _selectedLocation!.longitude,
      address: _address,
    );

    Navigator.pop(context, locationData);
  }

  void _goToCurrentLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          AppSnackbar.error('Location permission denied');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        AppSnackbar.error('Location permissions are permanently denied');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final newLocation = LatLng(position.latitude, position.longitude);

      setState(() {
        _selectedLocation = newLocation;
      });

      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(newLocation, 16),
      );

      _fetchAddress(newLocation);
    } catch (e) {
      AppSnackbar.error('Failed to get current location');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  /// Search for places using Google Places Autocomplete API
  Future<void> _searchPlaces(String query) async {
    if (query.isEmpty) {
      setState(() {
        _predictions = [];
        _isSearching = false;
        _showSearchResults = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _showSearchResults = true;
    });

    try {
      // Build location bias if initial coordinates are provided
      String locationBias = '';
      if (_selectedLocation != null) {
        locationBias =
            '&location=${_selectedLocation!.latitude},${_selectedLocation!.longitude}&radius=50000';
      }

      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/autocomplete/json'
        '?input=${Uri.encodeComponent(query)}'
        '&key=$_apiKey'
        '&components=country:in'
        '$locationBias',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'OK') {
          final predictions = (data['predictions'] as List)
              .map((p) => PlacePrediction.fromJson(p))
              .toList();

          setState(() {
            _predictions = predictions;
            _isSearching = false;
          });
        } else {
          setState(() {
            _predictions = [];
            _isSearching = false;
          });
        }
      } else {
        setState(() {
          _isSearching = false;
        });
      }
    } catch (e) {
      setState(() {
        _isSearching = false;
      });
      debugPrint('Search error: $e');
    }
  }

  /// Get place details and move map to location
  Future<void> _selectSearchResult(PlacePrediction prediction) async {
    // Hide keyboard and search results
    _searchFocusNode.unfocus();
    setState(() {
      _showSearchResults = false;
      _searchController.text = prediction.mainText;
    });

    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/details/json'
        '?place_id=${prediction.placeId}'
        '&fields=geometry,formatted_address'
        '&key=$_apiKey',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'OK') {
          final result = data['result'];
          final location = result['geometry']['location'];
          final formattedAddress =
              result['formatted_address'] ?? prediction.description;

          final newLocation = LatLng(
            location['lat'].toDouble(),
            location['lng'].toDouble(),
          );

          setState(() {
            _selectedLocation = newLocation;
            _address = formattedAddress;
          });

          // Move map to the selected location
          _mapController?.animateCamera(
            CameraUpdate.newLatLngZoom(newLocation, 16),
          );
        } else {
          AppSnackbar.error('Failed to get location details');
        }
      } else {
        AppSnackbar.error('Failed to get location details');
      }
    } catch (e) {
      AppSnackbar.error('Failed to get location details. Please try again.');
    }
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _searchPlaces(value);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _predictions = [];
      _showSearchResults = false;
    });
    _searchFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Location'),
        backgroundColor: widget.primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: widget.primaryColor),
            )
          : Stack(
              children: [
                /// Google Map
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _selectedLocation!,
                    zoom: 15,
                  ),
                  onMapCreated: (controller) {
                    _mapController = controller;
                  },
                  onTap: (latLng) {
                    // Hide search results when tapping on map
                    if (_showSearchResults) {
                      setState(() {
                        _showSearchResults = false;
                      });
                      _searchFocusNode.unfocus();
                    }
                    _onMapTap(latLng);
                  },
                  markers: _selectedLocation != null
                      ? {
                          Marker(
                            markerId: const MarkerId('selected'),
                            position: _selectedLocation!,
                            draggable: true,
                            onDragEnd: (newPosition) {
                              setState(() {
                                _selectedLocation = newPosition;
                              });
                              _fetchAddress(newPosition);
                            },
                          ),
                        }
                      : {},
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  padding: EdgeInsets.only(top: height * 0.08),
                ),

                /// Search Bar at the top
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.04,
                      vertical: height * 0.015,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: _onSearchChanged,
                      style: TextStyle(fontSize: width * 0.04),
                      decoration: InputDecoration(
                        hintText: 'Search for a place...',
                        hintStyle: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: width * 0.04,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: widget.primaryColor,
                        ),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: _clearSearch,
                              )
                            : null,
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: width * 0.04,
                          vertical: height * 0.015,
                        ),
                      ),
                    ),
                  ),
                ),

                /// Search Results Dropdown
                if (_showSearchResults)
                  Positioned(
                    top: height * 0.09,
                    left: width * 0.04,
                    right: width * 0.04,
                    child: Container(
                      constraints: BoxConstraints(
                        maxHeight: height * 0.35,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: _isSearching
                          ? Padding(
                              padding: EdgeInsets.all(width * 0.05),
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: widget.primaryColor,
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : _predictions.isEmpty
                              ? Padding(
                                  padding: EdgeInsets.all(width * 0.05),
                                  child: Text(
                                    'No results found',
                                    style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: width * 0.038,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  padding: EdgeInsets.symmetric(
                                    vertical: height * 0.01,
                                  ),
                                  itemCount: _predictions.length,
                                  itemBuilder: (context, index) {
                                    final prediction = _predictions[index];
                                    return InkWell(
                                      onTap: () =>
                                          _selectSearchResult(prediction),
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: width * 0.04,
                                          vertical: height * 0.012,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.location_on_outlined,
                                              color: widget.primaryColor,
                                              size: width * 0.055,
                                            ),
                                            SizedBox(width: width * 0.03),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    prediction.mainText,
                                                    style: TextStyle(
                                                      fontSize: width * 0.038,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: Colors.black87,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  if (prediction.secondaryText
                                                      .isNotEmpty)
                                                    Text(
                                                      prediction.secondaryText,
                                                      style: TextStyle(
                                                        fontSize: width * 0.032,
                                                        color:
                                                            Colors.grey.shade600,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                    ),
                  ),

                /// My Location Button
                Positioned(
                  right: 16,
                  bottom: height * 0.28,
                  child: FloatingActionButton(
                    mini: true,
                    backgroundColor: Colors.white,
                    onPressed: _goToCurrentLocation,
                    child: Icon(
                      Icons.my_location,
                      color: widget.primaryColor,
                    ),
                  ),
                ),

                /// Bottom Card with Address and Confirm Button
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 20,
                          offset: const Offset(0, -5),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        /// Drag Handle
                        Container(
                          margin: const EdgeInsets.only(top: 12),
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),

                        /// Location Info
                        Padding(
                          padding: EdgeInsets.all(width * 0.05),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              /// Title Row
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: widget.primaryColor
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      Icons.location_on,
                                      color: widget.primaryColor,
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Selected Location',
                                          style: TextStyle(
                                            fontSize: width * 0.042,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        if (_isFetchingAddress)
                                          Row(
                                            children: [
                                              SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: widget.primaryColor,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                'Fetching address...',
                                                style: TextStyle(
                                                  fontSize: width * 0.035,
                                                  color: Colors.grey.shade600,
                                                ),
                                              ),
                                            ],
                                          )
                                        else
                                          Text(
                                            _address,
                                            style: TextStyle(
                                              fontSize: width * 0.035,
                                              color: Colors.grey.shade700,
                                              height: 1.3,
                                            ),
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),

                              SizedBox(height: height * 0.025),

                              /// Confirm Button
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: (_selectedLocation != null &&
                                          !_isFetchingAddress)
                                      ? _onConfirm
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: widget.primaryColor,
                                    disabledBackgroundColor: Colors.grey.shade300,
                                    padding: EdgeInsets.symmetric(
                                      vertical: height * 0.018,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: _isFetchingAddress
                                      ? Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              'Getting Address...',
                                              style: TextStyle(
                                                fontSize: width * 0.042,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ],
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            const Icon(
                                              Icons.check_circle_outline,
                                              color: Colors.white,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Confirm Location',
                                              style: TextStyle(
                                                fontSize: width * 0.042,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),

                              /// Safe area padding
                              SizedBox(
                                  height:
                                      MediaQuery.of(context).padding.bottom),
                            ],
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
}
