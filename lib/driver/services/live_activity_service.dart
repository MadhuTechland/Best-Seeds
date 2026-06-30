import 'dart:io';

import 'package:flutter/services.dart';

/// Thin wrapper around the iOS Live Activity MethodChannel exposed by
/// AppDelegate.swift. All methods are no-ops on Android or older iOS
/// versions — the native side already gates on iOS 16.1+, so calling these
/// from cross-platform code is safe.
class LiveActivityService {
  LiveActivityService._();

  static const _channel = MethodChannel('com.bestseed/live_activity');

  /// Start the Live Activity for an active delivery journey. Idempotent — if
  /// one is already running, the native side will treat this as an update
  /// instead of starting a duplicate.
  static Future<void> start({
    required String journeyId,
    required String driverName,
    required double latitude,
    required double longitude,
    required String locationName,
    DateTime? lastSentAt,
    String? nextStop,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('start', {
        'journeyId': journeyId,
        'driverName': driverName,
        'latitude': latitude,
        'longitude': longitude,
        'locationName': locationName,
        'lastSentAtEpoch':
            (lastSentAt ?? DateTime.now()).millisecondsSinceEpoch / 1000.0,
        if (nextStop != null) 'nextStop': nextStop,
      });
    } catch (e) {
      // Live Activities are best-effort — never fail the journey because of
      // a missing widget extension or denied authorization.
      print('LiveActivityService.start failed: $e');
    }
  }

  /// Update the running Live Activity with a fresh position. Call on every
  /// successful location send so the lock-screen tile stays current.
  static Future<void> update({
    required double latitude,
    required double longitude,
    required String locationName,
    DateTime? lastSentAt,
    String? nextStop,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('update', {
        'latitude': latitude,
        'longitude': longitude,
        'locationName': locationName,
        'lastSentAtEpoch':
            (lastSentAt ?? DateTime.now()).millisecondsSinceEpoch / 1000.0,
        if (nextStop != null) 'nextStop': nextStop,
      });
    } catch (e) {
      print('LiveActivityService.update failed: $e');
    }
  }

  /// End the running Live Activity. Call at journey completion, logout, or
  /// when the backend signals `status: false`. The tile fades out within a
  /// few seconds rather than waiting for the default 4-hour timeout.
  static Future<void> end() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('end');
    } catch (e) {
      print('LiveActivityService.end failed: $e');
    }
  }
}
