import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:bestseeds/utils/app_cache_helper.dart';

class GoogleMapsService {
  static const String _apiKey = 'AIzaSyDLVwCSkXWOjo49WNNwx7o0DSwomoFvbP0';

  // ───────────────────────────────────────────────────────────────────────
  // PERSISTENT RESPONSE CACHE (SQLite, via AppCacheHelper)
  // ───────────────────────────────────────────────────────────────────────
  // Every Directions / Geocoding / Reverse-Geocoding call costs money
  // (~$5 per 1000). The vehicle tracking screen re-runs all of them on
  // every hot reload AND every back-and-re-enter, so a chatty user
  // reopening the screen 20× a day was burning ~$1/day per booking.
  //
  // Cache key is the rounded inputs (so identical fixtures collapse to
  // one row). 24 h TTL — fresh enough that a re-routed road / changed
  // pickup eventually overrides the cache, persistent enough that
  // back-and-re-enter is free.
  //
  // Driver position (when used as input to `getRouteWithStops`) is rounded
  // to 3 decimals (~110 m) so successive close-together opens still hit
  // the cache; the resulting route is visually identical at map zoom.
  static const Duration _cacheTTL = Duration(hours: 24);
  static const String _cachePrefix = 'gms_v1:';

  static String _r4(double d) => d.toStringAsFixed(4);
  static String _r3(double d) => d.toStringAsFixed(3);

  static Future<Map<String, dynamic>?> _cacheGet(String key) async {
    try {
      final raw =
          await AppCacheHelper.getFresh(_cachePrefix + key, _cacheTTL);
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _cachePut(String key, Map<String, dynamic> data) async {
    try {
      await AppCacheHelper.save(_cachePrefix + key, jsonEncode(data));
    } catch (_) {
      // Cache write failures are non-fatal — caller already has the live
      // API response in hand.
    }
  }

  /// Flatten a `List<LatLng>` to `[lat0, lng0, lat1, lng1, ...]` for compact
  /// JSON storage (about half the size of a list-of-maps form).
  static List<double> _latLngsToFlat(List<LatLng> pts) {
    final out = <double>[];
    for (final p in pts) {
      out.add(p.latitude);
      out.add(p.longitude);
    }
    return out;
  }

  static List<LatLng> _flatToLatLngs(List<dynamic> flat) {
    final out = <LatLng>[];
    for (int i = 0; i + 1 < flat.length; i += 2) {
      out.add(LatLng(
        (flat[i] as num).toDouble(),
        (flat[i + 1] as num).toDouble(),
      ));
    }
    return out;
  }

  /// Serialize a `getRouteWithStops` result map for JSON storage.
  static Map<String, dynamic> _routeResultToJson(Map<String, dynamic> r) {
    final stops = (r['stops'] as List? ?? []).map((s) {
      final m = Map<String, dynamic>.from(s as Map);
      final loc = m['location'];
      if (loc is LatLng) {
        m['location'] = [loc.latitude, loc.longitude];
      }
      return m;
    }).toList();

    return {
      'polyline_points':
          _latLngsToFlat((r['polyline_points'] as List?)?.cast<LatLng>() ?? []),
      'completed_points': _latLngsToFlat(
          (r['completed_points'] as List?)?.cast<LatLng>() ?? []),
      'remaining_points': _latLngsToFlat(
          (r['remaining_points'] as List?)?.cast<LatLng>() ?? []),
      'stops': stops,
      'total_duration_seconds': r['total_duration_seconds'] ?? 0,
      'total_distance_meters': r['total_distance_meters'] ?? 0,
      'driver_split_index': r['driver_split_index'] ?? 0,
      'driver_progress_fraction':
          (r['driver_progress_fraction'] as num?)?.toDouble() ?? 0.0,
      'remaining_duration_seconds': r['remaining_duration_seconds'] ?? 0,
      'cumulative_distances':
          (r['cumulative_distances'] as List?)?.cast<double>() ?? <double>[],
    };
  }

  /// Reverse of `_routeResultToJson`. Returns null if the cached payload
  /// can't be re-hydrated (corrupted / older schema) — caller falls back to
  /// the live API call.
  static Map<String, dynamic>? _routeResultFromJson(Map<String, dynamic> j) {
    try {
      final stops = (j['stops'] as List? ?? []).map((s) {
        final m = Map<String, dynamic>.from(s as Map);
        final loc = m['location'];
        if (loc is List && loc.length >= 2) {
          m['location'] = LatLng(
            (loc[0] as num).toDouble(),
            (loc[1] as num).toDouble(),
          );
        }
        return m;
      }).toList();

      return {
        'polyline_points':
            _flatToLatLngs(j['polyline_points'] as List? ?? const []),
        'completed_points':
            _flatToLatLngs(j['completed_points'] as List? ?? const []),
        'remaining_points':
            _flatToLatLngs(j['remaining_points'] as List? ?? const []),
        'stops': stops,
        'total_duration_seconds':
            (j['total_duration_seconds'] as num?)?.toInt() ?? 0,
        'total_distance_meters':
            (j['total_distance_meters'] as num?)?.toInt() ?? 0,
        'driver_split_index': (j['driver_split_index'] as num?)?.toInt() ?? 0,
        'driver_progress_fraction':
            (j['driver_progress_fraction'] as num?)?.toDouble() ?? 0.0,
        'remaining_duration_seconds':
            (j['remaining_duration_seconds'] as num?)?.toInt() ?? 0,
        'cumulative_distances': (j['cumulative_distances'] as List? ?? const [])
            .map((d) => (d as num).toDouble())
            .toList(),
      };
    } catch (e) {
      debugPrint('Cache rehydrate failed: $e');
      return null;
    }
  }

  /// Get directions between two points and return polyline points
  static Future<List<LatLng>> getDirections({
    required LatLng origin,
    required LatLng destination,
    List<LatLng>? waypoints,
    bool useViaWaypoints = false,
  }) async {
    final waypointsKey = (waypoints == null || waypoints.isEmpty)
        ? '-'
        : waypoints
            .map((w) => '${_r4(w.latitude)},${_r4(w.longitude)}')
            .join('|');
    final cacheKey = 'dir:'
        '${_r4(origin.latitude)},${_r4(origin.longitude)}>'
        '${_r4(destination.latitude)},${_r4(destination.longitude)}|'
        'wp=$waypointsKey|via=$useViaWaypoints';
    final cached = await _cacheGet(cacheKey);
    if (cached != null && cached['points'] is List) {
      return _flatToLatLngs(cached['points'] as List);
    }

    try {
      String waypointsStr = '';
      if (waypoints != null && waypoints.isNotEmpty) {
        if (useViaWaypoints) {
          waypointsStr =
              '&waypoints=${waypoints.map((wp) => 'via:${wp.latitude},${wp.longitude}').join('|')}';
        } else {
          waypointsStr =
              '&waypoints=${waypoints.map((wp) => '${wp.latitude},${wp.longitude}').join('|')}';
        }
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

      final encodedPolyline =
          data['routes'][0]['overview_polyline']['points'] as String;
      final points = _decodePolyline(encodedPolyline);
      await _cachePut(cacheKey, {'points': _latLngsToFlat(points)});
      return points;
    } catch (e) {
      debugPrint('Error getting directions: $e');
      return [];
    }
  }

  /// HIGH-RESOLUTION directions. Decodes `steps[].polyline.points` instead of
  /// `overview_polyline`. overview_polyline is Douglas–Peucker-simplified and
  /// collapses tight curves/side-streets to straight chords — causing the green
  /// line to appear to cut through buildings. Step polylines are full-resolution.
  static Future<List<LatLng>> getDirectionsHighRes({
    required LatLng origin,
    required LatLng destination,
    List<LatLng>? waypoints,
  }) async {
    final waypointsKey = (waypoints == null || waypoints.isEmpty)
        ? '-'
        : waypoints
            .map((w) => '${_r4(w.latitude)},${_r4(w.longitude)}')
            .join('|');
    final cacheKey = 'dirHR:'
        '${_r4(origin.latitude)},${_r4(origin.longitude)}>'
        '${_r4(destination.latitude)},${_r4(destination.longitude)}|'
        'wp=$waypointsKey';
    final cached = await _cacheGet(cacheKey);
    if (cached != null && cached['points'] is List) {
      return _flatToLatLngs(cached['points'] as List);
    }

    try {
      String waypointsStr = '';
      if (waypoints != null && waypoints.isNotEmpty) {
        waypointsStr =
            '&waypoints=${waypoints.map((wp) => '${wp.latitude},${wp.longitude}').join('|')}';
      }

      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '$waypointsStr'
        '&key=$_apiKey',
      );

      final response = await http.get(url);
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body);
      if (data['status'] != 'OK') return [];

      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return [];
      final legs = routes[0]['legs'] as List?;
      if (legs == null || legs.isEmpty) return [];

      final List<LatLng> merged = [];
      for (final leg in legs) {
        final steps = leg['steps'] as List?;
        if (steps == null) continue;
        for (final step in steps) {
          final encoded = step['polyline']?['points'] as String?;
          if (encoded == null || encoded.isEmpty) continue;
          final stepPts = _decodePolyline(encoded);
          // Skip step-boundary duplicates
          final start = (merged.isNotEmpty && stepPts.isNotEmpty &&
                  stepPts.first.latitude == merged.last.latitude &&
                  stepPts.first.longitude == merged.last.longitude)
              ? 1
              : 0;
          for (int i = start; i < stepPts.length; i++) {
            merged.add(stepPts[i]);
          }
        }
      }

      if (merged.isEmpty) return [];
      await _cachePut(cacheKey, {'points': _latLngsToFlat(merged)});
      return merged;
    } catch (e) {
      debugPrint('Error getting high-res directions: $e');
      return [];
    }
  }

  /// Get directions with duration info (returns polyline points + duration text)
  static Future<Map<String, dynamic>> getDirectionsWithDuration({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&key=$_apiKey',
      );

      final response = await http.get(url);
      if (response.statusCode != 200) return {};

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return {};

      final route = data['routes'][0];
      final leg = route['legs'][0];

      final encodedPolyline = route['overview_polyline']['points'] as String;
      final points = _decodePolyline(encodedPolyline);

      return {
        'points': points,
        'duration_text': leg['duration']['text'] ?? '',
        'duration_seconds': leg['duration']['value'] ?? 0,
        'distance_text': leg['distance']['text'] ?? '',
      };
    } catch (e) {
      debugPrint('Error getting directions with duration: $e');
      return {};
    }
  }

  /// Geocode an address to get LatLng coordinates
  static Future<LatLng?> geocodeAddress(String address) async {
    final cacheKey = 'geocode:${address.trim().toLowerCase()}';
    final cached = await _cacheGet(cacheKey);
    if (cached != null && cached['lat'] != null && cached['lng'] != null) {
      return LatLng(
        (cached['lat'] as num).toDouble(),
        (cached['lng'] as num).toDouble(),
      );
    }

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
      final result = LatLng(
        (location['lat'] as num).toDouble(),
        (location['lng'] as num).toDouble(),
      );

      await _cachePut(cacheKey, {
        'lat': result.latitude,
        'lng': result.longitude,
      });
      return result;
    } catch (e) {
      debugPrint('Error geocoding address: $e');
      return null;
    }
  }

  /// Reverse geocode coordinates to get neighborhood/area name.
  /// Prefers locality/town names over tiny neighborhoods or hamlets.
  static Future<String?> reverseGeocode(LatLng location) async {
    // Round to 3 decimals (~110 m). Two stops within 110 m of each other
    // resolve to the same town anyway, so collapsing them into one cache
    // key is correct, not a bug.
    final cacheKey =
        'rgeocode:${_r3(location.latitude)},${_r3(location.longitude)}';
    final cached = await _cacheGet(cacheKey);
    if (cached != null && cached.containsKey('name')) {
      return cached['name'] as String?;
    }

    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?latlng=${location.latitude},${location.longitude}'
        '&result_type=locality|administrative_area_level_3|administrative_area_level_2|sublocality_level_1|sublocality|neighborhood'
        '&language=en'
        '&key=$_apiKey',
      );

      final response = await http.get(url);
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return null;

      final results = data['results'] as List;
      if (results.isEmpty) return null;

      // Priority: recognizable town/city > mandal/sub-district > small locality
      const priority = [
        'locality',
        'administrative_area_level_3',
        'administrative_area_level_2',
        'sublocality_level_1',
        'sublocality',
        'neighborhood',
      ];

      String? resolved;
      for (final type in priority) {
        for (final result in results) {
          final components = result['address_components'] as List;
          for (final component in components) {
            final types = component['types'] as List;
            if (types.contains(type)) {
              resolved = component['long_name'] as String?;
              break;
            }
          }
          if (resolved != null) break;
        }
        if (resolved != null) break;
      }
      resolved ??= results[0]['formatted_address']?.toString().split(',').first;

      if (resolved != null) {
        await _cachePut(cacheKey, {'name': resolved});
      }
      return resolved;
    } catch (e) {
      debugPrint('Error reverse geocoding: $e');
      return null;
    }
  }

  /// Get full route from origin to destination with intermediate stops.
  /// When [driverPosition] is provided, the polyline is split into
  /// completed (green) and remaining (blue) segments.
  /// Supports multi-drop routes with [routeWaypoints].
  ///
  /// Set [bypassCache] to true for periodic ETA refreshes that need fresh
  /// traffic-aware Google duration.
  static Future<Map<String, dynamic>> getRouteWithStops({
    required LatLng origin,
    required LatLng destination,
    LatLng? driverPosition,
    List<LatLng> routeWaypoints = const [],
    int maxStops = 5,
    bool bypassCache = false,
  }) async {
    // Cache key: pickup + drop at fine precision (~11 m), driver at coarse
    // (~110 m so close-together polls collapse), and waypoints/maxStops.
    final waypointsKey = routeWaypoints.isEmpty
        ? '-'
        : routeWaypoints
            .map((w) => '${_r4(w.latitude)},${_r4(w.longitude)}')
            .join('|');
    final driverKey = driverPosition == null
        ? '-'
        : '${_r3(driverPosition.latitude)},${_r3(driverPosition.longitude)}';
    final cacheKey = 'rws:'
        '${_r4(origin.latitude)},${_r4(origin.longitude)}>'
        '${_r4(destination.latitude)},${_r4(destination.longitude)}|'
        'd=$driverKey|wp=$waypointsKey|max=$maxStops';
    if (!bypassCache) {
      final cached = await _cacheGet(cacheKey);
      if (cached != null) {
        final hydrated = _routeResultFromJson(cached);
        if (hydrated != null) return hydrated;
      }
    }

    try {
      // Build waypoints for Directions API.
      // When route waypoints exist (multi-drop), only use drop waypoints — NOT driver position.
      // The driver position will be used to split the polyline into completed/remaining.
      // When no route waypoints, use driver position as waypoint (original behavior).
      //
      // Filter out waypoints that are:
      // 1. Too close to origin (< 5km) — would cause unnecessary loop back
      // 2. Too close to destination (< 5km) — redundant
      // 3. Too close to each other (< 5km) — duplicates
      List<String> allWaypoints = [];
      if (routeWaypoints.isNotEmpty) {
        List<LatLng> filteredWaypoints = [];
        for (final wp in routeWaypoints) {
          if (_haversineDistance(origin, wp) < 5000) {
            debugPrint('Skipping waypoint too close to origin: ${wp.latitude},${wp.longitude} '
                '(${_haversineDistance(origin, wp).toStringAsFixed(0)}m)');
            continue;
          }
          if (_haversineDistance(destination, wp) < 5000) {
            debugPrint('Skipping waypoint too close to destination: ${wp.latitude},${wp.longitude}');
            continue;
          }
          bool isDuplicate = false;
          for (final existing in filteredWaypoints) {
            if (_haversineDistance(existing, wp) < 5000) {
              isDuplicate = true;
              debugPrint('Skipping duplicate waypoint: ${wp.latitude},${wp.longitude}');
              break;
            }
          }
          if (!isDuplicate) {
            filteredWaypoints.add(wp);
            allWaypoints.add('${wp.latitude},${wp.longitude}');
          }
        }
        debugPrint('Waypoints: ${routeWaypoints.length} raw → ${filteredWaypoints.length} after filtering');
      } else if (driverPosition != null) {
        allWaypoints.add('${driverPosition.latitude},${driverPosition.longitude}');
      }
      String waypointsParam = '';
      if (allWaypoints.isNotEmpty) {
        waypointsParam = '&waypoints=${allWaypoints.join('|')}';
      }

      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '$waypointsParam'
        '&key=$_apiKey',
      );

      debugPrint('Directions API: origin=${origin.latitude},${origin.longitude} '
          'dest=${destination.latitude},${destination.longitude} '
          'waypoints=${routeWaypoints.length} driver=${driverPosition != null}');

      final response = await http.get(url);
      if (response.statusCode != 200) return {};

      final data = json.decode(response.body);
      if (data['status'] != 'OK') return {};

      final route = data['routes'][0];
      final legs = route['legs'] as List;

      for (int i = 0; i < legs.length; i++) {
        final leg = legs[i];
        debugPrint('Leg $i: ${leg['start_address']} → ${leg['end_address']} '
            'duration=${leg['duration']['text']} distance=${leg['distance']['text']}');
      }

      List<LatLng> completedPoints = [];
      List<LatLng> remainingPoints = [];
      int totalDurationSeconds = 0;
      int totalDistanceMeters = 0;
      int remainingSeconds = 0;
      int completedSeconds = 0;

      if (routeWaypoints.isNotEmpty && driverPosition != null) {
        // Multi-drop route with driver position:
        // Route goes: origin → drop1 → drop2 → ... → destination (driver NOT a waypoint)
        // Split the polyline at the driver's actual position for green/blue coloring
        List<LatLng> allPoints = [];
        List<int> legDurations = [];
        List<int> legDistances = [];
        List<int> legStartIndices = [0];

        for (int legIdx = 0; legIdx < legs.length; legIdx++) {
          final legPoints = _decodeStepsPolyline(legs[legIdx]['steps'] as List);
          if (legIdx > 0 && allPoints.isNotEmpty && legPoints.isNotEmpty) {
            legStartIndices.add(allPoints.length);
            allPoints.addAll(legPoints.sublist(1));
          } else {
            allPoints.addAll(legPoints);
          }
          final legDur = legs[legIdx]['duration']['value'] as int;
          final legDist = legs[legIdx]['distance']['value'] as int;
          legDurations.add(legDur);
          legDistances.add(legDist);
          totalDurationSeconds += legDur;
          totalDistanceMeters += legDist;
        }

        // Find driver position on polyline using bounded search
        // (prevents matching a far-away point when driver is near the start)
        double pickupToDriverDist = allPoints.isNotEmpty
            ? _haversineDistance(allPoints.first, driverPosition)
            : 0;

        int driverIdx;
        if (pickupToDriverDist < 1000) {
          driverIdx = 0;
        } else {
          double searchLimit = pickupToDriverDist * 1.5 + 10000;
          double accDist = 0;
          driverIdx = 0;
          double minDist = double.infinity;
          for (int i = 0; i < allPoints.length; i++) {
            if (i > 0) {
              accDist += _haversineDistance(allPoints[i - 1], allPoints[i]);
            }
            if (accDist > searchLimit) break;
            double dist = _haversineDistance(allPoints[i], driverPosition);
            if (dist < minDist) {
              minDist = dist;
              driverIdx = i;
            }
          }
        }

        debugPrint('Multi-drop route split: pickupToDriver=${pickupToDriverDist.toStringAsFixed(0)}m, '
            'driverIdx=$driverIdx/${allPoints.length}, totalDuration=${totalDurationSeconds}s');

        completedPoints = allPoints.sublist(0, driverIdx + 1);
        remainingPoints = allPoints.sublist(driverIdx);

        // Calculate remaining duration using per-leg durations (more accurate than distance fraction)
        int driverLegIdx = 0;
        for (int i = legStartIndices.length - 1; i >= 0; i--) {
          if (driverIdx >= legStartIndices[i]) {
            driverLegIdx = i;
            break;
          }
        }

        remainingSeconds = 0;
        for (int i = driverLegIdx + 1; i < legDurations.length; i++) {
          remainingSeconds += legDurations[i];
        }
        int currentLegStart = legStartIndices[driverLegIdx];
        int currentLegEnd = (driverLegIdx + 1 < legStartIndices.length)
            ? legStartIndices[driverLegIdx + 1]
            : allPoints.length;
        double currentLegTotalDist = 0;
        for (int i = currentLegStart + 1; i < currentLegEnd; i++) {
          currentLegTotalDist += _haversineDistance(allPoints[i - 1], allPoints[i]);
        }
        double currentLegCompletedDist = 0;
        for (int i = currentLegStart + 1; i <= driverIdx; i++) {
          currentLegCompletedDist += _haversineDistance(allPoints[i - 1], allPoints[i]);
        }
        double currentLegRemainingFraction = currentLegTotalDist > 0
            ? 1.0 - (currentLegCompletedDist / currentLegTotalDist)
            : 1.0;
        remainingSeconds += (legDurations[driverLegIdx] * currentLegRemainingFraction).round();
        completedSeconds = totalDurationSeconds - remainingSeconds;

        debugPrint('Duration: driverInLeg=$driverLegIdx/${legs.length}, '
            'remaining=${(remainingSeconds / 3600).toStringAsFixed(1)}h, '
            'completed=${(completedSeconds / 3600).toStringAsFixed(1)}h');
      } else if (driverPosition != null && legs.length >= 2) {
        // Single-drop route with driver as waypoint (original behavior)
        completedPoints = _decodeStepsPolyline(legs[0]['steps'] as List);
        remainingPoints = _decodeStepsPolyline(legs[1]['steps'] as List);
        completedSeconds = legs[0]['duration']['value'] as int;
        remainingSeconds = legs[1]['duration']['value'] as int;
        totalDurationSeconds = completedSeconds + remainingSeconds;
        totalDistanceMeters = (legs[0]['distance']['value'] as int) +
            (legs[1]['distance']['value'] as int);
      } else if (routeWaypoints.isNotEmpty && legs.length >= 2) {
        // Waypoints but no driver position — all legs combined as remaining
        for (final leg in legs) {
          remainingPoints.addAll(_decodeStepsPolyline(leg['steps'] as List));
          totalDurationSeconds += leg['duration']['value'] as int;
          totalDistanceMeters += leg['distance']['value'] as int;
        }
        remainingSeconds = totalDurationSeconds;
      } else {
        // No driver position, no waypoints — single leg, full route as remaining
        final encodedPolyline =
            route['overview_polyline']['points'] as String;
        remainingPoints = _decodePolyline(encodedPolyline);
        totalDurationSeconds = legs[0]['duration']['value'] as int;
        totalDistanceMeters = legs[0]['distance']['value'] as int;
        remainingSeconds = totalDurationSeconds;
      }

      // Combine for full route polyline
      List<LatLng> fullPolyline = [...completedPoints, ...remainingPoints];
      int driverSplitIndex =
          completedPoints.isNotEmpty ? completedPoints.length - 1 : 0;
      double driverFraction = totalDurationSeconds > 0
          ? completedSeconds / totalDurationSeconds
          : 0;

      // Calculate cumulative distances along full polyline
      List<double> cumulativeDistances = [0.0];
      for (int i = 1; i < fullPolyline.length; i++) {
        double segDist =
            _haversineDistance(fullPolyline[i - 1], fullPolyline[i]);
        cumulativeDistances.add(cumulativeDistances.last + segDist);
      }
      double totalPolylineDist = cumulativeDistances.last;
      double driverDistanceOnRoute = driverSplitIndex < cumulativeDistances.length
          ? cumulativeDistances[driverSplitIndex]
          : 0;

      // Determine number of stops based on route distance (minimum 3)
      int numStops;
      if (totalDistanceMeters < 200000) {
        numStops = min(3, maxStops);
      } else if (totalDistanceMeters < 500000) {
        numStops = min(5, maxStops);
      } else {
        numStops = maxStops;
      }

      // Sample evenly-spaced intermediate stops
      List<Map<String, dynamic>> stops = [];
      if (numStops > 0 && totalPolylineDist > 0) {
        double interval = totalPolylineDist / (numStops + 1);
        for (int i = 1; i <= numStops; i++) {
          double targetDist = interval * i;
          LatLng point = _interpolatePointOnPolyline(
              targetDist, fullPolyline, cumulativeDistances);
          double fraction = targetDist / totalPolylineDist;
          bool passed = targetDist <= driverDistanceOnRoute;
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

      final result = {
        'polyline_points': fullPolyline,
        'completed_points': completedPoints,
        'remaining_points': remainingPoints,
        'stops': stops,
        'total_duration_seconds': totalDurationSeconds,
        'total_distance_meters': totalDistanceMeters,
        'driver_split_index': driverSplitIndex,
        'driver_progress_fraction': driverFraction,
        'remaining_duration_seconds': remainingSeconds,
        'cumulative_distances': cumulativeDistances,
      };
      await _cachePut(cacheKey, _routeResultToJson(result));
      return result;
    } catch (e) {
      debugPrint('Error getting route with stops: $e');
      return {};
    }
  }

  /// Generate sub-stops between two fractions along the route polyline.
  /// Returns a list of maps with 'name', 'estimated_seconds', and
  /// 'distance_fraction' for each sub-stop.
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

    // Scale candidate count by segment length for denser long-distance routes
    final segmentKm = segmentDist / 1000;
    final desiredCount = segmentKm >= 220
        ? 7
        : segmentKm >= 160
        ? 6
        : segmentKm >= 120
        ? 5
        : segmentKm >= 80
        ? 4
        : count;
    final targetCount = max(count, desiredCount);
    final candidateCount = min(max(targetCount * 4, 8), 24);
    final interval = segmentDist / (candidateCount + 1);
    List<Map<String, dynamic>> candidates = [];

    for (int i = 1; i <= candidateCount; i++) {
      final targetDist = startDist + interval * i;
      final point = _interpolatePointOnPolyline(
        targetDist,
        fullPolyline,
        cumulativeDistances,
      );
      final fraction = targetDist / totalDist;
      candidates.add({
        'location': point,
        'estimated_seconds': (totalDurationSeconds * fraction).round(),
        'distance_fraction': fraction,
      });
    }

    // Reverse geocode many candidate points, then keep the best ordered localities.
    final names = await Future.wait(
      candidates.map((s) => reverseGeocode(s['location'] as LatLng)),
    );
    for (int i = 0; i < candidates.length; i++) {
      candidates[i]['name'] = names[i] ?? 'Unknown';
    }

    // Remove duplicates/unknowns while preserving route order.
    List<Map<String, dynamic>> unique = [];
    Set<String> seen = {};
    for (var stop in candidates) {
      final name = stop['name'] as String;
      if (name != 'Unknown' && !seen.contains(name)) {
        unique.add(stop);
        seen.add(name);
      }
    }

    if (unique.length <= targetCount) return unique;

    // Keep a broader but still readable set of towns/cities in route order.
    final trimmed = <Map<String, dynamic>>[];
    final step = (unique.length - 1) / (targetCount - 1);
    for (int i = 0; i < targetCount; i++) {
      trimmed.add(unique[(i * step).round()]);
    }

    // Final de-duplication after thinning.
    final finalStops = <Map<String, dynamic>>[];
    final finalNames = <String>{};
    for (final stop in trimmed) {
      final name = stop['name'] as String;
      if (!finalNames.contains(name)) {
        finalStops.add(stop);
        finalNames.add(name);
      }
    }

    return finalStops;
  }

  /// Decode polylines from all steps in a Directions API leg
  static List<LatLng> _decodeStepsPolyline(List steps) {
    List<LatLng> points = [];
    for (var step in steps) {
      final stepPoints =
          _decodePolyline(step['polyline']['points'] as String);
      if (points.isNotEmpty && stepPoints.isNotEmpty) {
        points.addAll(stepPoints.sublist(1));
      } else {
        points.addAll(stepPoints);
      }
    }
    return points;
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

      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }
}
