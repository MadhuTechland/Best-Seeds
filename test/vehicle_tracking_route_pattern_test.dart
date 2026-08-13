// Regression guard for the iOS patterned-polyline truncation, vendor/driver side.
//
// ROOT CAUSE (confirmed on an iPhone 16 Plus simulator against live production
// data in the customer app, bookings #1060/#1061/#1062; reported here too):
//
//   iOS renders `PatternItem` dot/dash + gap by generating GMSStyleSpans along
//   the path. On a long route the spans run out before the line does, so the
//   map draws only the leading portion and stops. The polyline handed to the
//   platform was COMPLETE — the render log recorded
//     last=(16.57748,82.00320)
//   which is booking #1062's exact destination (Kakinada). Android implements
//   patterns natively and never truncated, hence iOS-only.
//
//   Disabling the pattern made the full route draw. That experiment is the
//   proof; `_routePattern` is the shipped form of it.
//
// This app is the WORSE case: its tracking screens used `PatternItem.dot`,
// and a dot is effectively a zero-length dash — far more spans per kilometre
// than dash(20), so it exhausts them sooner.
//
// Observed in the customer app, and the basis for the 75 km threshold:
//   183 km  patterned -> drew correctly
//   324 km  patterned -> truncated at the priority-1 drop
//   506 km  patterned -> truncated at the priority-2 drop

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

const double maxPatternedRouteMeters = 75000;

double patternDistMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * pi / 180.0;
  final dLng = (b.longitude - a.longitude) * pi / 180.0;
  final h = sin(dLat / 2) * sin(dLat / 2) +
      cos(a.latitude * pi / 180.0) *
          cos(b.latitude * pi / 180.0) *
          sin(dLng / 2) *
          sin(dLng / 2);
  return 2 * r * asin(sqrt(h));
}

/// Verbatim copy of the implementation under test.
List<PatternItem> routePattern(List<LatLng> pts) {
  if (pts.length < 2) return const <PatternItem>[];
  double metres = 0;
  for (int i = 1; i < pts.length; i++) {
    metres += patternDistMeters(pts[i - 1], pts[i]);
    if (metres > maxPatternedRouteMeters) return const <PatternItem>[];
  }
  return [PatternItem.dot, PatternItem.gap(10)];
}

bool isSolid(List<PatternItem> p) => p.isEmpty;

List<LatLng> leg(LatLng from, LatLng to, [int n = 200]) => [
      for (int i = 0; i < n; i++)
        LatLng(
          from.latitude + (to.latitude - from.latitude) * (i / (n - 1)),
          from.longitude + (to.longitude - from.longitude) * (i / (n - 1)),
        )
    ];

void main() {
  // Real coordinates from the production API.
  const driver = LatLng(17.47762, 78.394887);
  const dropA = LatLng(17.1417379, 79.6204326); // Suryapet
  const dropB = LatLng(16.5061743, 80.6480153); // Vijayawada
  const dropC = LatLng(16.5774798, 82.0031455); // Kakinada

  group('long inter-city runs render solid', () {
    test('324 km two-leg route is solid', () {
      expect(isSolid(routePattern([...leg(driver, dropA), ...leg(dropA, dropB)])),
          isTrue);
    });

    test('506 km three-leg route is solid', () {
      final route = [
        ...leg(driver, dropA),
        ...leg(dropA, dropB),
        ...leg(dropB, dropC),
      ];
      expect(isSolid(routePattern(route)), isTrue);
    });

    test('183 km single-leg route is solid', () {
      expect(isSolid(routePattern(leg(driver, dropA))), isTrue);
    });
  });

  group('short city runs keep the dotted styling', () {
    test('a ~12 km hop stays dotted', () {
      final p = routePattern(
          leg(const LatLng(17.4849, 78.3915), const LatLng(17.4401, 78.3489)));
      expect(isSolid(p), isFalse);
      expect(p.length, 2);
    });

    test('just under the threshold stays dotted', () {
      final route = leg(const LatLng(17.0, 78.0), const LatLng(17.6, 78.0));
      expect(patternDistMeters(route.first, route.last),
          lessThan(maxPatternedRouteMeters));
      expect(isSolid(routePattern(route)), isFalse);
    });

    test('just over the threshold flips to solid', () {
      final route = leg(const LatLng(17.0, 78.0), const LatLng(17.8, 78.0));
      expect(patternDistMeters(route.first, route.last),
          greaterThan(maxPatternedRouteMeters));
      expect(isSolid(routePattern(route)), isTrue);
    });
  });

  group('degenerate inputs', () {
    test('empty and single-point lists are solid, never crash', () {
      expect(isSolid(routePattern(const <LatLng>[])), isTrue);
      expect(isSolid(routePattern(const [dropA])), isTrue);
    });

    test('early-out does not scan the whole list on a long route', () {
      final huge = leg(driver, dropC, 20000);
      final sw = Stopwatch()..start();
      final p = routePattern(huge);
      sw.stop();
      expect(isSolid(p), isTrue);
      expect(sw.elapsedMilliseconds, lessThan(500));
    });
  });
}
