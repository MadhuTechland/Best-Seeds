import 'dart:async';

import 'package:bestseeds/routes/api_clients.dart';
import 'package:bestseeds/routes/app_constants.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

class DriverLocationService {
  static Timer? _timer;

  static void start(String token) {
    print('DriverLocationService.start() called');
    print('DriverLocationService token: $token');

    _timer?.cancel(); // safety: avoid multiple timers

    Future<void> _sendLocation() async {
      print('DriverLocationService LOCATION TASK RUNNING');

      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );

        print(
          'DriverLocationService POSITION -> '
          'lat=${position.latitude}, lng=${position.longitude}',
        );

        final locationName = await _getLocationName(
          position.latitude,
          position.longitude,
        );

        await ApiClient().request(
          url: AppConstants.baseUrl + AppConstants.driverLocationUpdateApi,
          method: 'POST',
          token: token,
          body: {
            'lat': position.latitude,
            'lng': position.longitude,
            'location_name': locationName ?? 'Live vehicle location',
          },
        );

        print('DriverLocationService LOCATION SENT SUCCESSFULLY');
      } catch (e, stack) {
        print('DriverLocationService ERROR: $e');
        print('$stack');
      }
    }

    // 🔥 Run once immediately
    _sendLocation();

    // ⏱ Then run every 5 minutes
    _timer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _sendLocation(),
    );

    print('DriverLocationService TIMER STARTED');
  }

  static void stop() {
    print('DriverLocationService STOPPED');
    _timer?.cancel();
    _timer = null;
  }

  static Future<String?> _getLocationName(
    double latitude,
    double longitude,
  ) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        latitude,
        longitude,
      );

      if (placemarks.isEmpty) return null;

      final p = placemarks.first;

      // Build a clean, readable name
      return [
        p.subLocality,
        p.locality,
        p.administrativeArea,
      ].where((e) => e != null && e.isNotEmpty).join(', ');
    } catch (e) {
      print('Reverse geocoding failed: $e');
      return null;
    }
  }
}
