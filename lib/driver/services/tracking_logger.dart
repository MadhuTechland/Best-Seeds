import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent ring-buffer logger for the driver location pipeline.
///
/// The background location service and the foreground UI run in
/// separate Dart isolates, so an in-memory log list cannot be shared
/// between them. Every log call writes to an in-memory buffer in the
/// current isolate AND persists the latest window to SharedPreferences
/// (throttled). The in-app viewer reads directly from SharedPreferences
/// each time so it sees logs from both isolates.
///
/// Tag every console line with `[TRACKING]` so the developer can
/// filter `adb logcat` or `flutter logs` to just the tracking events.
class TrackingLogger {
  static const int _maxLogs = 300;
  static const String _prefsKey = 'tracking_logs_v1';
  static const String _consoleTag = '[TRACKING]';

  static final Queue<String> _buffer = Queue<String>();
  static bool _loaded = false;
  static DateTime? _lastPersistAt;
  static int _logsSinceLastPersist = 0;

  /// Minimum time between SharedPreferences writes. Below this,
  /// consecutive log calls just accumulate in-memory.
  static const Duration _persistThrottle = Duration(seconds: 3);
  static const int _persistEveryNLogs = 5;

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final saved = prefs.getStringList(_prefsKey) ?? [];
      _buffer.addAll(saved);
      while (_buffer.length > _maxLogs) {
        _buffer.removeFirst();
      }
    } catch (_) {}
  }

  /// Append a log line. Non-blocking — persistence happens in the
  /// background and never throws.
  static void log(String message) {
    final now = DateTime.now();
    final ts = now.toIso8601String().substring(11, 23); // HH:mm:ss.SSS
    final line = '$ts | $message';
    // Console output (goes to adb logcat / flutter logs)
    debugPrint('$_consoleTag $line');
    // In-memory buffer
    _buffer.addLast(line);
    while (_buffer.length > _maxLogs) {
      _buffer.removeFirst();
    }
    // Throttled persistence
    _maybePersist();
  }

  static void _maybePersist() {
    _logsSinceLastPersist++;
    final now = DateTime.now();
    final shouldByTime = _lastPersistAt == null ||
        now.difference(_lastPersistAt!) >= _persistThrottle;
    final shouldByCount = _logsSinceLastPersist >= _persistEveryNLogs;
    if (!shouldByTime && !shouldByCount) return;
    _lastPersistAt = now;
    _logsSinceLastPersist = 0;
    _persistNow();
  }

  static Future<void> _persistNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Merge with any logs written by the OTHER isolate since our
      // last read. Without this, two isolates would race and the last
      // writer would clobber entries written concurrently.
      final existing = prefs.getStringList(_prefsKey) ?? const <String>[];
      final merged = <String>{...existing, ..._buffer}.toList()
        ..sort(); // timestamps at the head keep chronological order
      while (merged.length > _maxLogs) {
        merged.removeAt(0);
      }
      await prefs.setStringList(_prefsKey, merged);
    } catch (_) {
      // Logging failures must never crash the tracking pipeline.
    }
  }

  /// Returns the most recent logs from persistent storage. Safe to
  /// call from any isolate. Always fetches fresh — used by the UI
  /// viewer that auto-refreshes while the driver watches the screen.
  static Future<List<String>> getLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getStringList(_prefsKey) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// Clear every log, in-memory and persisted.
  static Future<void> clear() async {
    _buffer.clear();
    _logsSinceLastPersist = 0;
    _lastPersistAt = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }

  /// Force an immediate persist. Call before the service shuts down
  /// so the last handful of logs don't get lost in the throttle window.
  static Future<void> flush() async {
    await _ensureLoaded();
    await _persistNow();
  }
}
