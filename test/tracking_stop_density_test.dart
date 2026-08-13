// Stop DENSITY on long multi-drop routes.
//
// REPORTED (Adithya, bookings #1063-#1067): on the Hyderabad→Chennai run the
// leg from Tirupati to Chennai showed no intermediate places — "have 12 hours
// gap and in that gap fill 6-10 locations".
//
// The old counts were fixed buckets: 12 stops for anything 200-500 km, 15 up to
// 1000 km. On a 524 km route that put stops ~42 km apart, so the ~130 km final
// leg earned only about 3. Past 200 km the count is now proportional to
// distance, holding density roughly constant however long the route runs.
//
// Stops are generated CLIENT-SIDE (TrackingStopsService → GoogleMapsService).
// The backend has a RouteTimelineService that could do this, but it is not
// wired into /farmer/vehicle_tracking/{id} and was deliberately left untouched.

import 'package:flutter_test/flutter_test.dart';
import 'package:bestseeds/employee/services/tracking_stops_service.dart';

void main() {
  int stops(double km) => TrackingStopsService.recommendedStopCount(km);

  /// Stops that fall in a leg of [legKm] on a route of [routeKm], assuming the
  /// even spacing the selection now guarantees.
  int stopsInLeg(double routeKm, double legKm) {
    final n = stops(routeKm);
    if (n == 0) return 0;
    return (legKm / (routeKm / n)).round();
  }

  group('the reported route gets 6-10 stops in its final leg', () {
    test('#1067 Hyderabad→Chennai: Tirupati→Chennai leg', () {
      final got = stopsInLeg(524.2, 130);
      expect(got, greaterThanOrEqualTo(6));
      expect(got, lessThanOrEqualTo(10));
    });

    test('#1066 Hyderabad→Tirupati: Bapatla→Tirupati leg', () {
      final got = stopsInLeg(437.6, 130);
      expect(got, greaterThanOrEqualTo(6));
      expect(got, lessThanOrEqualTo(10));
    });

    test('old fixed buckets could not have reached 6', () {
      // Reproduce the previous behaviour: 12 stops for a 200-500 km route,
      // 15 up to 1000 km.
      int oldCount(double km) => km <= 500 ? 12 : 15;
      final oldInLeg = (130 / (524.2 / oldCount(524.2))).round();
      expect(oldInLeg, lessThan(6),
          reason: 'this is why the final leg looked empty');
    });
  });

  group('density stays roughly constant on long routes', () {
    test('spacing stays between ~15 and ~26 km on routes over 200 km', () {
      // Just above 200 km the minimum-of-14 floor dominates (220 km → 14 stops
      // → ~15.7 km apart). That floor is deliberate: without it, 220 km would
      // return 10 stops — FEWER than the 14 a 200 km route gets — and the count
      // would go backwards. From roughly 310 km onward the proportional term
      // takes over and spacing settles at ~22 km.
      for (final km in [220.0, 350.0, 524.2, 700.0, 880.0]) {
        final spacing = km / stops(km);
        expect(spacing, greaterThan(15.0));
        expect(spacing, lessThan(26.0),
            reason: '$km km produced ${stops(km)} stops');
      }
    });

    test('count increases monotonically with distance', () {
      var prev = 0;
      for (final km in [1.0, 5.0, 15.0, 45.0, 90.0, 180.0, 300.0, 524.2, 900.0]) {
        final n = stops(km);
        expect(n, greaterThanOrEqualTo(prev), reason: 'regressed at $km km');
        prev = n;
      }
    });

    test('capped so a very long haul stays scannable', () {
      expect(stops(5000), lessThanOrEqualTo(40));
      expect(stops(20000), lessThanOrEqualTo(40));
    });
  });

  group('short routes keep their hand-tuned counts', () {
    test('a sub-500 m hop has no intermediate stops', () {
      expect(stops(0.3), 0);
    });

    test('city deliveries stay modest', () {
      expect(stops(8), lessThanOrEqualTo(4));
      expect(stops(18), lessThanOrEqualTo(6));
      expect(stops(45), lessThanOrEqualTo(8));
    });

    test('every non-trivial distance yields at least one stop', () {
      for (final km in [1.0, 3.0, 8.0, 15.0, 30.0, 75.0, 150.0]) {
        expect(stops(km), greaterThan(0), reason: 'no stops at $km km');
      }
    });
  });
}
