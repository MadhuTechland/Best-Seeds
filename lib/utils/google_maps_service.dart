import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

class GoogleMapsService {
  static const String _apiKey = 'AIzaSyDLVwCSkXWOjo49WNNwx7o0DSwomoFvbP0';

  /// Get directions between two points and return polyline points
  static Future<List<LatLng>> getDirections({
    required LatLng origin,
    required LatLng destination,
    List<LatLng>? waypoints,
  }) async {
    try {
      String waypointsStr = '';
      if (waypoints != null && waypoints.isNotEmpty) {
        waypointsStr = '&waypoints=${waypoints.map((wp) => '${wp.latitude},${wp.longitude}').join('|')}';
      }

      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '$waypointsStr'
        '&key=$_apiKey',
      );

      final response = await http.get(url);

      if (response.statusCode != 200) {
        debugPrint('Directions API error: ${response.statusCode}');
        return [];
      }

      final data = json.decode(response.body);

      if (data['status'] != 'OK') {
        debugPrint('Directions API status: ${data['status']}');
        return [];
      }

      // Decode the polyline from the response
      final encodedPolyline =
          data['routes'][0]['overview_polyline']['points'] as String;

      return _decodePolyline(encodedPolyline);
    } catch (e) {
      debugPrint('Error getting directions: $e');
      return [];
    }
  }

  /// Geocode an address to get LatLng coordinates
  static Future<LatLng?> geocodeAddress(String address) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?address=${Uri.encodeComponent(address)}'
        '&key=$_apiKey',
      );

      final response = await http.get(url);

      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);

      if (data['status'] != 'OK') return null;

      final location = data['results'][0]['geometry']['location'];

      return LatLng(location['lat'], location['lng']);
    } catch (e) {
      debugPrint('Error geocoding address: $e');
      return null;
    }
  }

  /// Reverse geocode coordinates to get neighborhood/area name.
  /// Prefers sublocality (e.g. "Kothaguda", "Madhapur") over city ("Hyderabad").
  static Future<String?> reverseGeocode(LatLng location) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?latlng=${location.latitude},${location.longitude}'
        '&result_type=sublocality_level_1|sublocality|neighborhood|locality|administrative_area_level_3'
        '&language=en'
        '&key=$_apiKey',
      );

      final response = await http.get(url);
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return null;

      final results = data['results'] as List;
      if (results.isEmpty) return null;

      // Priority: sublocality > neighborhood > locality (city)
      const priority = [
        'sublocality_level_1',
        'sublocality',
        'neighborhood',
        'locality',
        'administrative_area_level_3',
      ];

      for (final type in priority) {
        for (final result in results) {
          final components = result['address_components'] as List;
          for (final component in components) {
            final types = component['types'] as List;
            if (types.contains(type)) {
              return component['long_name'];
            }
          }
        }
      }

      return results[0]['formatted_address']?.toString().split(',').first;
    } catch (e) {
      debugPrint('Error reverse geocoding: $e');
      return null;
    }
  }

  /// Get full route from origin to destination with intermediate stops.
  /// When [driverPosition] is provided, it's used as a waypoint so the route
  /// goes: origin → driver → destination (two legs with proper road routing).
  static Future<Map<String, dynamic>> getRouteWithStops({
    required LatLng origin,
    required LatLng destination,
    LatLng? driverPosition,
    int maxStops = 5,
  }) async {
    try {
      // Build waypoints string if driver position is available
      String waypointsParam = '';
      if (driverPosition != null) {
        waypointsParam =
            '&waypoints=${driverPosition.latitude},${driverPosition.longitude}';
      }

      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '$waypointsParam'
        '&key=$_apiKey',
      );

      final response = await http.get(url);
      if (response.statusCode != 200) return {};

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return {};

      final route = data['routes'][0];
      final legs = route['legs'] as List;
      final encodedPolyline = route['overview_polyline']['points'] as String;
      final polylinePoints = _decodePolyline(encodedPolyline);

      // Calculate totals from all legs
      int totalDurationSeconds = 0;
      int totalDistanceMeters = 0;
      for (final leg in legs) {
        totalDurationSeconds += leg['duration']['value'] as int;
        totalDistanceMeters += leg['distance']['value'] as int;
      }
      final durationText = legs.last['duration']['text'] as String;
      final distanceText = legs.last['distance']['text'] as String;

      // Calculate cumulative distances along polyline
      List<double> cumulativeDistances = [0.0];
      for (int i = 1; i < polylinePoints.length; i++) {
        double segDist =
            _haversineDistance(polylinePoints[i - 1], polylinePoints[i]);
        cumulativeDistances.add(cumulativeDistances.last + segDist);
      }
      double totalPolylineDist = cumulativeDistances.last;

      // Determine number of stops based on route distance (minimum 3)
      int numStops;
      if (totalDistanceMeters < 200000) {
        numStops = 3; // < 200 km — 3 stops
      } else if (totalDistanceMeters < 500000) {
        numStops = min(5, maxStops); // 200–500 km
      } else {
        numStops = maxStops; // 500+ km
      }

      // Find driver's position on the route
      double driverDistanceOnRoute = 0;
      int driverSplitIndex = 0;
      int remainingDurationSeconds = totalDurationSeconds;

      if (driverPosition != null && legs.length >= 2) {
        // With waypoints: leg[0] = origin→driver, leg[1] = driver→drop
        remainingDurationSeconds = legs[1]['duration']['value'] as int;

        // Find the closest polyline point to driver position for split index
        double minDist = double.infinity;
        for (int i = 0; i < polylinePoints.length; i++) {
          double d = _haversineDistance(driverPosition, polylinePoints[i]);
          if (d < minDist) {
            minDist = d;
            driverSplitIndex = i;
          }
        }
        driverDistanceOnRoute = cumulativeDistances[driverSplitIndex];
      } else if (driverPosition != null) {
        // Single leg fallback: project driver onto route
        double minDist = double.infinity;
        for (int i = 0; i < polylinePoints.length; i++) {
          double d = _haversineDistance(driverPosition, polylinePoints[i]);
          if (d < minDist) {
            minDist = d;
            driverSplitIndex = i;
          }
        }
        driverDistanceOnRoute = cumulativeDistances[driverSplitIndex];
      }

      double driverFraction = totalPolylineDist > 0
          ? driverDistanceOnRoute / totalPolylineDist
          : 0;

      // If we didn't get separate legs, calculate remaining from fraction
      if (driverPosition != null && legs.length < 2) {
        remainingDurationSeconds =
            ((1 - driverFraction) * totalDurationSeconds).round();
      }

      // Sample evenly-spaced intermediate stops
      List<Map<String, dynamic>> stops = [];
      if (numStops > 0 && totalPolylineDist > 0) {
        double interval = totalPolylineDist / (numStops + 1);
        for (int i = 1; i <= numStops; i++) {
          double targetDist = interval * i;
          LatLng point = _interpolatePointOnPolyline(
              targetDist, polylinePoints, cumulativeDistances);
          double fraction = targetDist / totalPolylineDist;
          bool passed =
              driverPosition != null && targetDist <= driverDistanceOnRoute;
          stops.add({
            'location': point,
            'distance_fraction': fraction,
            'estimated_seconds': (totalDurationSeconds * fraction).round(),
            'passed': passed,
          });
        }

        // Reverse geocode all stops in parallel
        List<String?> names = await Future.wait(
          stops.map((s) => reverseGeocode(s['location'] as LatLng)),
        );
        for (int i = 0; i < stops.length; i++) {
          stops[i]['name'] = names[i] ?? 'Unknown';
        }

        // Remove all duplicate names (keep first occurrence)
        List<Map<String, dynamic>> uniqueStops = [];
        Set<String> seenNames = {};
        for (var stop in stops) {
          final name = stop['name'] as String;
          if (name != 'Unknown' && !seenNames.contains(name)) {
            uniqueStops.add(stop);
            seenNames.add(name);
          }
        }
        stops = uniqueStops;
      }

      return {
        'polyline_points': polylinePoints,
        'stops': stops,
        'total_duration_seconds': totalDurationSeconds,
        'total_distance_meters': totalDistanceMeters,
        'duration_text': durationText,
        'distance_text': distanceText,
        'driver_split_index': driverSplitIndex,
        'driver_progress_fraction': driverFraction,
        'remaining_duration_seconds': remainingDurationSeconds,
        'cumulative_distances': cumulativeDistances,
      };
    } catch (e) {
      debugPrint('Error getting route with stops: $e');
      return {};
    }
  }

  /// Generate sub-stops between two fractions along the route polyline.
  static Future<List<Map<String, dynamic>>> generateSubStops({
    required List<LatLng> fullPolyline,
    required List<double> cumulativeDistances,
    required double startFraction,
    required double endFraction,
    required int totalDurationSeconds,
    int count = 3,
  }) async {
    if (fullPolyline.isEmpty || cumulativeDistances.isEmpty) return [];

    final totalDist = cumulativeDistances.last;
    final startDist = totalDist * startFraction;
    final endDist = totalDist * endFraction;
    final segmentDist = endDist - startDist;
    if (segmentDist <= 0) return [];

    final interval = segmentDist / (count + 1);
    List<Map<String, dynamic>> subStops = [];

    for (int i = 1; i <= count; i++) {
      final targetDist = startDist + interval * i;
      final point = _interpolatePointOnPolyline(
        targetDist,
        fullPolyline,
        cumulativeDistances,
      );
      final fraction = targetDist / totalDist;
      subStops.add({
        'location': point,
        'estimated_seconds': (totalDurationSeconds * fraction).round(),
        'distance_fraction': fraction,
      });
    }

    // Reverse geocode all sub-stops in parallel
    final names = await Future.wait(
      subStops.map((s) => reverseGeocode(s['location'] as LatLng)),
    );
    for (int i = 0; i < subStops.length; i++) {
      subStops[i]['name'] = names[i] ?? 'Unknown';
    }

    // Remove duplicates and unknowns
    List<Map<String, dynamic>> unique = [];
    Set<String> seen = {};
    for (var stop in subStops) {
      final name = stop['name'] as String;
      if (name != 'Unknown' && !seen.contains(name)) {
        unique.add(stop);
        seen.add(name);
      }
    }

    return unique;
  }

  /// Interpolate a point along the polyline at a given cumulative distance
  static LatLng _interpolatePointOnPolyline(
    double targetDist,
    List<LatLng> polylinePoints,
    List<double> cumulativeDistances,
  ) {
    for (int j = 1; j < cumulativeDistances.length; j++) {
      if (cumulativeDistances[j] >= targetDist) {
        double segStart = cumulativeDistances[j - 1];
        double segEnd = cumulativeDistances[j];
        double fraction =
            (segEnd - segStart) > 0 ? (targetDist - segStart) / (segEnd - segStart) : 0;
        return LatLng(
          polylinePoints[j - 1].latitude +
              (polylinePoints[j].latitude - polylinePoints[j - 1].latitude) *
                  fraction,
          polylinePoints[j - 1].longitude +
              (polylinePoints[j].longitude - polylinePoints[j - 1].longitude) *
                  fraction,
        );
      }
    }
    return polylinePoints.last;
  }

  /// Calculate haversine distance between two points in meters
  static double _haversineDistance(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    double dLat = _toRadians(b.latitude - a.latitude);
    double dLng = _toRadians(b.longitude - a.longitude);
    double h = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(a.latitude)) *
            cos(_toRadians(b.latitude)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return 2 * earthRadius * asin(sqrt(h));
  }

  static double _toRadians(double degrees) => degrees * pi / 180;

  /// Decode Google's encoded polyline algorithm
  static List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int shift = 0;
      int result = 0;

      // Decode latitude
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      // Decode longitude
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }
}
