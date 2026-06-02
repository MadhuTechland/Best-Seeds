import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:bestseeds/utils/google_maps_service.dart';
import 'package:bestseeds/routes/api_clients.dart';
import 'package:bestseeds/routes/app_constants.dart';

/// Service to manage vehicle tracking stops.
/// Passed stops come from API (saved in DB).
/// Upcoming stops generated client-side from Google Directions.
class TrackingStopsService {
  /// Calculate recommended stop count based on total distance.
  static int recommendedStopCount(double totalDistanceKm) {
    if (totalDistanceKm <= 0.5) return 0;
    if (totalDistanceKm <= 2) return 1;
    if (totalDistanceKm <= 5) return 2;
    if (totalDistanceKm <= 10) return 3;
    if (totalDistanceKm <= 20) return 4;
    if (totalDistanceKm <= 50) return 5;
    if (totalDistanceKm <= 100) return 7;
    if (totalDistanceKm <= 200) return 9;
    if (totalDistanceKm <= 500) return 12;
    if (totalDistanceKm <= 1000) return 15;
    return 18;
  }

  /// Calculate sub-stop count based on gap between two main stops.
  static int recommendedSubStopCount(double gapKm) {
    if (gapKm < 5) return 0;
    if (gapKm < 15) return 1;
    if (gapKm < 40) return 2;
    if (gapKm < 80) return 3;
    if (gapKm < 150) return 4;
    return 5;
  }

  /// Generate upcoming stops from driver's current position to destination.
  /// Uses Google Directions API to get the route, then samples stops along it.
  static Future<List<Map<String, dynamic>>> generateUpcomingStops({
    required LatLng driverPosition,
    required LatLng destination,
    required double remainingDistanceKm,
    List<LatLng> waypoints = const [],
  }) async {
    try {
      final stopCount = recommendedStopCount(remainingDistanceKm);
      debugPrint('🛣️ [STOPS] Generating $stopCount upcoming stops for ${remainingDistanceKm.toStringAsFixed(1)} km');

      final result = await GoogleMapsService.getRouteWithStops(
        origin: driverPosition,
        destination: destination,
        routeWaypoints: waypoints,
        maxStops: stopCount,
      );

      final stops = (result['stops'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      debugPrint('🛣️ [STOPS] Generated ${stops.length} upcoming stops');

      return stops.map((stop) {
        final loc = stop['location'];
        double? lat, lng;
        if (loc is LatLng) {
          lat = loc.latitude;
          lng = loc.longitude;
        }
        return {
          'name': stop['name'] ?? 'Unknown',
          'lat': lat ?? 0.0,
          'lng': lng ?? 0.0,
          'status': 'upcoming',
          'dist_from_driver_km': _haversineKm(
            driverPosition.latitude, driverPosition.longitude,
            lat ?? 0, lng ?? 0,
          ),
        };
      }).toList();
    } catch (e) {
      debugPrint('🛣️ [STOPS] Error generating upcoming: $e');
      return [];
    }
  }

  /// Save a passed stop to the backend DB.
  static Future<bool> savePassedStop({
    required String bookingId,
    required String name,
    required double lat,
    required double lng,
    required String token,
    String type = 'main',
    String? parentStopName,
    int order = 0,
    double distFromPickupKm = 0,
  }) async {
    try {
      final apiClient = ApiClient();
      final response = await apiClient.request(
        url: '${AppConstants.baseUrl}${AppConstants.driverVehicleTrackingApi}/$bookingId/save_stop',
        method: 'POST',
        token: token,
        body: {
          'name': name,
          'lat': lat.toString(),
          'lng': lng.toString(),
          'type': type,
          if (parentStopName != null) 'parent_stop_name': parentStopName,
          'order': order.toString(),
          'dist_from_pickup_km': distFromPickupKm.toString(),
        },
      );

      if (response['status'] == true) {
        debugPrint('🛣️ [STOPS] ✅ Saved stop "$name" to DB');
        return true;
      } else {
        debugPrint('🛣️ [STOPS] ❌ Failed to save stop: $response');
        return false;
      }
    } catch (e) {
      debugPrint('🛣️ [STOPS] ❌ Error saving stop: $e');
      return false;
    }
  }

  /// Check if driver has passed an upcoming stop.
  static bool hasDriverPassed({
    required LatLng driverPos,
    required LatLng pickup,
    required double stopLat,
    required double stopLng,
  }) {
    final driverDist = _haversineKm(pickup.latitude, pickup.longitude, driverPos.latitude, driverPos.longitude);
    final stopDist = _haversineKm(pickup.latitude, pickup.longitude, stopLat, stopLng);
    return driverDist > stopDist + 0.5; // 500m tolerance
  }

  /// Haversine distance in km.
  static double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) * math.cos(_toRad(lat2)) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  static double _toRad(double deg) => deg * math.pi / 180;
}
