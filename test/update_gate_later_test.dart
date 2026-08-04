import 'package:bestseeds/widgets/update_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression cover for: tapping "Later" on the driver force-update screen
/// appeared to do nothing, stranding a mid-journey driver on the gate.
///
/// Two things have to hold for that button to work:
///   1. it must persist the journey fingerprint, so the NEXT version check
///      suppresses the gate instead of showing it again, and
///   2. it must invoke onLater, which is what actually leaves the screen.
///
/// The key the widget writes. Must match update_gate.dart.
const _kSkippedJourneyFp = 'update_gate_skipped_journey_fp';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget host(Widget child) => MaterialApp(home: child);

  group('Later button', () {
    testWidgets('is shown only while a journey is live', (tester) async {
      await tester.pumpWidget(host(const DriverForceUpdateScreen(
        useInAppUpdate: false,
        storeUrlAndroid: '',
        storeUrlIos: '',
        allowLater: false,
        journeyFingerprint: '',
      )));
      await tester.pump();

      expect(find.text('Later'), findsNothing,
          reason: 'no Later when not mid-journey — the update is mandatory');
      expect(find.text('Update Required'), findsOneWidget);
    });

    testWidgets('is shown when mid-journey', (tester) async {
      await tester.pumpWidget(host(const DriverForceUpdateScreen(
        useInAppUpdate: false,
        storeUrlAndroid: '',
        storeUrlIos: '',
        allowLater: true,
        journeyFingerprint: '16.1_81.2_16.9_81.9',
      )));
      await tester.pump();

      expect(find.text('Later'), findsOneWidget);
    });

    testWidgets('invokes onLater so the driver actually leaves the screen',
        (tester) async {
      var called = 0;
      await tester.pumpWidget(host(DriverForceUpdateScreen(
        useInAppUpdate: false,
        storeUrlAndroid: '',
        storeUrlIos: '',
        allowLater: true,
        journeyFingerprint: '16.1_81.2_16.9_81.9',
        onLater: () async => called++,
      )));
      await tester.pump();

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();

      expect(called, 1, reason: 'a tap that leads nowhere is the reported bug');
    });

    testWidgets('persists the fingerprint so the gate does not re-show',
        (tester) async {
      const fp = '16.1_81.2_16.9_81.9';
      await tester.pumpWidget(host(DriverForceUpdateScreen(
        useInAppUpdate: false,
        storeUrlAndroid: '',
        storeUrlIos: '',
        allowLater: true,
        journeyFingerprint: fp,
        onLater: () async {},
      )));
      await tester.pump();

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kSkippedJourneyFp), fp,
          reason: 'without this the next check re-blocks the driver');
    });

    testWidgets('persists BEFORE navigating away', (tester) async {
      const fp = 'pickup_drop';
      String? seenAtNavigationTime;

      await tester.pumpWidget(host(DriverForceUpdateScreen(
        useInAppUpdate: false,
        storeUrlAndroid: '',
        storeUrlIos: '',
        allowLater: true,
        journeyFingerprint: fp,
        onLater: () async {
          final prefs = await SharedPreferences.getInstance();
          seenAtNavigationTime = prefs.getString(_kSkippedJourneyFp);
        },
      )));
      await tester.pump();

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();

      expect(seenAtNavigationTime, fp,
          reason: 'the skip must be durable before the screen is torn down, '
              'otherwise a fast re-check races it and re-blocks');
    });

    testWidgets('a null onLater leaves the driver stranded — the failure mode',
        (tester) async {
      await tester.pumpWidget(host(const DriverForceUpdateScreen(
        useInAppUpdate: false,
        storeUrlAndroid: '',
        storeUrlIos: '',
        allowLater: true,
        journeyFingerprint: 'fp',
        // onLater deliberately omitted.
      )));
      await tester.pump();

      // Must not throw, but nothing can move the driver on — which is exactly
      // why splash must always pass onLater.
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();

      expect(find.text('Update Required'), findsOneWidget);
    });

    testWidgets('the update button is always present', (tester) async {
      await tester.pumpWidget(host(const DriverForceUpdateScreen(
        useInAppUpdate: false,
        storeUrlAndroid: '',
        storeUrlIos: '',
        allowLater: true,
        journeyFingerprint: 'fp',
      )));
      await tester.pump();

      expect(
        find.textContaining('Update from'),
        findsOneWidget,
        reason: 'updating must stay available even when Later is offered',
      );
    });
  });
}
