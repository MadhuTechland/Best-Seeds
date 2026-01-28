import 'dart:convert';
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
