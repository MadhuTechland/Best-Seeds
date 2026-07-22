import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/driver_booking_model.dart';

/// Bridges the driver-home bookings list to the iOS Live Activity tile by
/// persisting the currently-active journey's pickup + next-drop into
/// SharedPreferences. `IosLocationService` reads these keys on every
/// successful position send and uses them to render the Maps-style route
/// bar (pickup ━●━━━ drop, with the truck position based on coords).
///
/// Background isolates and the main isolate share the same SharedPreferences
/// store, so writes from the driver-home `_fetchBookings` path are visible
/// to the foreground iOS location service without any extra plumbing.
class ActiveJourneyPrefs {
  ActiveJourneyPrefs._();

  // Keep these names short — they end up replicated in iOS UserDefaults
  // under the "flutter." prefix.
  static const _kPickupName = 'aj_pickup_name';
  static const _kPickupLat = 'aj_pickup_lat';
  static const _kPickupLng = 'aj_pickup_lng';
  static const _kDropName = 'aj_drop_name';
  static const _kDropLat = 'aj_drop_lat';
  static const _kDropLng = 'aj_drop_lng';
  static const _kNextStopLabel = 'aj_next_stop_label';
  // JSON-encoded `[{name, lat, lng, status}, ...]` for all drops on the
  // route. `ios_location_service` uses this to compute the dots' positions
  // on the route bar (progress = distance_pickup_to_stop / total).
  static const _kStops = 'aj_stops_json';

  /// Scan the given routes for the journey the driver is currently on
  /// (status == 4) and persist its pickup + next-drop. If no live journey
  /// is found, clear all keys so the Live Activity falls back to its
  /// simpler layout.
  static Future<void> syncFromRoutes(List<DriverRoute> routes) async {
    final prefs = await SharedPreferences.getInstance();

    DriverRoute? live;
    for (final r in routes) {
      if (r.routeStatus == 4) {
        live = r;
        break;
      }
    }

    if (live == null) {
      await _clear(prefs);
      return;
    }

    // Pickup — the route's start location (typically the hatchery).
    final pickupName = live.startLocation?.locationName;
    final pickupLat = live.startLat;
    final pickupLng = live.startLng;

    // Drop — the FINAL booking on the route. Constant for the lifetime of
    // the journey, so the route bar shows the full pickup → final-drop
    // span; intermediate drops become dots that turn green as delivered.
    // Falls back to nothing if the route has no bookings with coords.
    final bookingsWithCoords = live.bookings
        .where((b) => b.dropLat != null && b.dropLng != null)
        .toList();
    final finalDrop = bookingsWithCoords.isNotEmpty
        ? bookingsWithCoords.last
        : null;

    final dropName = finalDrop?.droppingLocation;
    final dropLat = finalDrop?.dropLat;
    final dropLng = finalDrop?.dropLng;

    // "Drop 2 of 5 — Komaragiri" label points at the CURRENT TARGET (next
    // undelivered drop), not the final one. This is the badge shown in the
    // tile header so the driver always sees "where I'm heading next."
    final pending = live.bookings.where(
      (b) => b.status != 5 && b.status != 6,
    );
    final nextTarget = pending.isNotEmpty ? pending.first : live.bookings.lastOrNull;
    final totalDrops = live.bookings.length;
    final targetIndex = nextTarget == null
        ? 0
        : live.bookings.indexOf(nextTarget) + 1;
    final nextStopLabel = (nextTarget != null && totalDrops > 1)
        ? 'Drop $targetIndex of $totalDrops${nextTarget.droppingLocation != null ? " — ${nextTarget.droppingLocation}" : ""}'
        : (nextTarget?.droppingLocation ?? '');

    await _writeOrRemove(prefs, _kPickupName, pickupName);
    await _writeDouble(prefs, _kPickupLat, pickupLat);
    await _writeDouble(prefs, _kPickupLng, pickupLng);
    await _writeOrRemove(prefs, _kDropName, dropName);
    await _writeDouble(prefs, _kDropLat, dropLat);
    await _writeDouble(prefs, _kDropLng, dropLng);
    await _writeOrRemove(prefs, _kNextStopLabel, nextStopLabel.isEmpty ? null : nextStopLabel);

    // Serialize every drop on the route as a stop. The current target
    // (next undelivered, == nextStop above) gets status=1; delivered drops
    // get status=2; the rest get status=0. ios_location_service later
    // computes each dot's progress position from its coords.
    final stopMaps = <Map<String, dynamic>>[];
    for (final b in live.bookings) {
      if (b.dropLat == null || b.dropLng == null) continue;
      final int statusCode;
      if (b.status == 5) {
        statusCode = 2; // delivered
      } else if (nextTarget != null && identical(b, nextTarget)) {
        statusCode = 1; // current target
      } else {
        statusCode = 0; // upcoming (or cancelled status==6, still drawn as upcoming)
      }
      stopMaps.add({
        'name': b.droppingLocation ?? 'Stop',
        'lat': b.dropLat,
        'lng': b.dropLng,
        'status': statusCode,
      });
    }
    if (stopMaps.isEmpty) {
      await prefs.remove(_kStops);
    } else {
      await prefs.setString(_kStops, jsonEncode(stopMaps));
    }
  }

  /// Snapshot read used by [IosLocationService] before each Live Activity
  /// update. Returns null fields when a key is missing — the Swift side
  /// gracefully degrades the UI in that case.
  static Future<ActiveJourneySnapshot> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final stopsRaw = prefs.getString(_kStops);
    List<ActiveJourneyStop> stops = const [];
    if (stopsRaw != null && stopsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(stopsRaw);
        if (decoded is List) {
          stops = decoded
              .whereType<Map>()
              .map((m) {
                final lat = (m['lat'] as num?)?.toDouble();
                final lng = (m['lng'] as num?)?.toDouble();
                if (lat == null || lng == null) return null;
                return ActiveJourneyStop(
                  name: (m['name'] as String?) ?? 'Stop',
                  lat: lat,
                  lng: lng,
                  status: (m['status'] as num?)?.toInt() ?? 0,
                );
              })
              .whereType<ActiveJourneyStop>()
              .toList();
        }
      } catch (_) {
        // Corrupted JSON — drop silently, the tile falls back to no dots.
      }
    }
    return ActiveJourneySnapshot(
      pickupName: prefs.getString(_kPickupName),
      pickupLat: prefs.getDouble(_kPickupLat),
      pickupLng: prefs.getDouble(_kPickupLng),
      dropName: prefs.getString(_kDropName),
      dropLat: prefs.getDouble(_kDropLat),
      dropLng: prefs.getDouble(_kDropLng),
      nextStopLabel: prefs.getString(_kNextStopLabel),
      stops: stops,
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await _clear(prefs);
  }

  static Future<void> _clear(SharedPreferences prefs) async {
    for (final k in [
      _kPickupName,
      _kPickupLat,
      _kPickupLng,
      _kDropName,
      _kDropLat,
      _kDropLng,
      _kNextStopLabel,
      _kStops,
    ]) {
      await prefs.remove(k);
    }
  }

  static Future<void> _writeOrRemove(
    SharedPreferences prefs,
    String key,
    String? value,
  ) async {
    if (value == null || value.trim().isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  static Future<void> _writeDouble(
    SharedPreferences prefs,
    String key,
    double? value,
  ) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setDouble(key, value);
    }
  }
}

class ActiveJourneySnapshot {
  ActiveJourneySnapshot({
    this.pickupName,
    this.pickupLat,
    this.pickupLng,
    this.dropName,
    this.dropLat,
    this.dropLng,
    this.nextStopLabel,
    this.stops = const [],
  });

  final String? pickupName;
  final double? pickupLat;
  final double? pickupLng;
  final String? dropName;
  final double? dropLat;
  final double? dropLng;
  final String? nextStopLabel;
  /// All drops on the journey, including delivered ones. Used by
  /// `IosLocationService` to compute the dot positions along the route bar.
  final List<ActiveJourneyStop> stops;

  bool get hasPickup => pickupLat != null && pickupLng != null;
  bool get hasDrop => dropLat != null && dropLng != null;
}

/// A single intermediate drop pulled out of `aj_stops_json`. `status`
/// mirrors `LiveActivityStop.status` (0 = upcoming, 1 = current, 2 = delivered).
class ActiveJourneyStop {
  ActiveJourneyStop({
    required this.name,
    required this.lat,
    required this.lng,
    required this.status,
  });

  final String name;
  final double lat;
  final double lng;
  final int status;
}
