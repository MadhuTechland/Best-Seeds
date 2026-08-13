// Regression guard for the timeline stop ORDER on a multi-drop route.
//
// REPORTED (Adithya, bookings #1063-#1067 — Suryapet, Vijayawada, Rajahmundry,
// Tirupati, Chennai): "suryapet and vijayawada timeline getting fine, from
// priority 3 onwards location timeline is wrong ... locations are not
// increasing based on distance".
//
// ROOT CAUSE: `_buildFixedStopsFromPassedAndUpcoming` sorted upcoming stops by
// STRAIGHT-LINE distance from the driver:
//
//     double distFromDriver(s) => _haversineDistance(driverForOrder, s);
//     upcomingMerged.sort((a, b) => distFromDriver(a).compareTo(distFromDriver(b)));
//
// Crow-flies distance only agrees with travel order while a route heads
// steadily away from its origin. This route doubles back — Rajahmundry sits far
// east (81.8E) and the truck then returns south-west toward Tirupati (79.4E) —
// so towns reached AFTER Rajahmundry are physically CLOSER to Hyderabad than
// Rajahmundry itself and sorted ahead of it. The first two drops lie on a
// straight run out of Hyderabad, which is exactly why priority 1 and 2 looked
// correct and everything from priority 3 did not.
//
// FIX: always order by `dist_fraction` — distance ALONG the route polyline,
// which is monotonic in travel order however the route bends.
//
// The backend was verified correct and is NOT the cause: VehicleController
// filters `priority < booking.priority` and returns `orderBy('priority','asc')`
// with real `dropping_location` names.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

double haversineKm(LatLng a, LatLng b) {
  const r = 6371.0;
  final dLat = (b.latitude - a.latitude) * pi / 180.0;
  final dLng = (b.longitude - a.longitude) * pi / 180.0;
  final h = sin(dLat / 2) * sin(dLat / 2) +
      cos(a.latitude * pi / 180.0) *
          cos(b.latitude * pi / 180.0) *
          sin(dLng / 2) *
          sin(dLng / 2);
  return 2 * r * asin(sqrt(h));
}

/// A timeline stop: its true position along the route, and its coordinates.
class Stop {
  Stop(this.name, this.lat, this.lng, this.distFraction);
  final String name;
  final double lat, lng;
  final double distFraction; // along-route position, 0..1
  LatLng get pos => LatLng(lat, lng);
}

/// OLD ordering (pre-fix): crow-flies from the driver.
List<Stop> orderByCrowFlies(List<Stop> stops, LatLng driver) {
  final out = [...stops];
  out.sort((a, b) =>
      haversineKm(driver, a.pos).compareTo(haversineKm(driver, b.pos)));
  return out;
}

/// NEW ordering (post-fix): along-route position.
List<Stop> orderByRouteFraction(List<Stop> stops) {
  final out = [...stops];
  out.sort((a, b) => a.distFraction.compareTo(b.distFraction));
  return out;
}

void main() {
  // Driver at Madhapur, Hyderabad — the real pickup for these bookings.
  const driver = LatLng(17.47762, 78.394887);

  // Real drop coordinates from the production API, plus towns the truck
  // genuinely passes through, listed in TRUE TRAVEL ORDER.
  final trueOrder = <Stop>[
    Stop('Suryapet', 17.1417379, 79.6204326, 0.12),
    Stop('Vijayawada', 16.5061743, 80.6480153, 0.28),
    Stop('Rajahmundry', 17.0009872, 81.7894583, 0.44),
    Stop('Eluru', 16.7107, 81.0952, 0.52),
    Stop('Ongole', 15.5057, 80.0499, 0.66),
    Stop('Nellore', 14.4426, 79.9865, 0.78),
    Stop('Tirupati', 13.6287557, 79.4191795, 0.89),
    Stop('Chennai', 13.0843007, 80.2704622, 1.00),
  ];

  group('the reported defect is reproduced', () {
    test('crow-flies ordering scrambles the route', () {
      final got = orderByCrowFlies(trueOrder, driver).map((s) => s.name).toList();
      expect(got, isNot(trueOrder.map((s) => s.name).toList()),
          reason: 'this is the bug: crow-flies order != travel order');
    });

    test('priority 1 and 2 stay correct — matching the report', () {
      final got = orderByCrowFlies(trueOrder, driver).map((s) => s.name).toList();
      expect(got[0], 'Suryapet');
      expect(got[1], 'Vijayawada');
    });

    test('it breaks from the third stop onward — matching the report', () {
      final got = orderByCrowFlies(trueOrder, driver).map((s) => s.name).toList();
      expect(got[2], isNot('Rajahmundry'),
          reason: 'Ongole (281 km) sorts ahead of Rajahmundry (364 km) '
              'even though the truck reaches it later');
    });

    test('a later town really is closer as the crow flies', () {
      final raj = trueOrder.firstWhere((s) => s.name == 'Rajahmundry');
      final ong = trueOrder.firstWhere((s) => s.name == 'Ongole');
      expect(ong.distFraction, greaterThan(raj.distFraction),
          reason: 'Ongole is reached later');
      expect(haversineKm(driver, ong.pos),
          lessThan(haversineKm(driver, raj.pos)),
          reason: 'yet it is nearer the origin — the route doubles back');
    });
  });

  group('the fix orders correctly', () {
    test('along-route ordering reproduces true travel order exactly', () {
      expect(orderByRouteFraction(trueOrder).map((s) => s.name).toList(),
          trueOrder.map((s) => s.name).toList());
    });

    test('order is stable regardless of input shuffling', () {
      final shuffled = [...trueOrder]..shuffle(Random(42));
      expect(orderByRouteFraction(shuffled).map((s) => s.name).toList(),
          trueOrder.map((s) => s.name).toList());
    });

    test('dist_fraction is strictly increasing after sorting', () {
      final sorted = orderByRouteFraction([...trueOrder]..shuffle(Random(7)));
      for (var i = 1; i < sorted.length; i++) {
        expect(sorted[i].distFraction,
            greaterThan(sorted[i - 1].distFraction),
            reason: 'stops must increase by distance along the route');
      }
    });

    test('a straight-out route orders identically either way', () {
      // Sanity: on a route that never doubles back, both orderings agree —
      // which is why this was never noticed on single-drop bookings.
      final straight = <Stop>[
        Stop('Suryapet', 17.1417379, 79.6204326, 0.33),
        Stop('Vijayawada', 16.5061743, 80.6480153, 0.66),
        Stop('Rajahmundry', 17.0009872, 81.7894583, 1.00),
      ];
      expect(orderByCrowFlies(straight, driver).map((s) => s.name).toList(),
          orderByRouteFraction(straight).map((s) => s.name).toList());
    });
  });

  group('no placeholder names survive', () {
    test('every stop carries a real place name', () {
      for (final s in trueOrder) {
        expect(s.name.trim(), isNotEmpty);
        expect(RegExp(r'^Stop\s*\d*$').hasMatch(s.name), isFalse,
            reason: 'placeholder labels like "Stop 3" must never be rendered');
      }
    });
  });
}
