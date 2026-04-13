import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Crash-proof SQLite queue for location updates.
///
/// Stores GPS readings locally on the phone so they survive app crashes,
/// OEM kills, and phone reboots. Each isolate opens the database independently;
/// SQLite handles concurrent access via its own locking.
class TrackingDatabase {
  static const String _dbName = 'tracking_queue.db';
  static const String _table = 'pending_locations';
  static const int _dbVersion = 1;

  /// Open (or create) the tracking database.
  /// Call this from any isolate — each gets its own connection.
  static Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            location_name TEXT,
            timestamp TEXT NOT NULL,
            sent INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
  }

  /// Insert a new location into the queue.
  static Future<void> insert({
    required double lat,
    required double lng,
    String? locationName,
  }) async {
    final db = await _open();
    try {
      await db.insert(_table, {
        'lat': lat,
        'lng': lng,
        'location_name': locationName,
        'timestamp': DateTime.now().toIso8601String(),
        'sent': 0,
      });

      // Keep queue bounded — delete oldest unsent if > 200 rows
      final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $_table WHERE sent = 0'),
      );
      if (count != null && count > 200) {
        await db.rawDelete('''
          DELETE FROM $_table WHERE id IN (
            SELECT id FROM $_table WHERE sent = 0
            ORDER BY id ASC LIMIT ${count - 200}
          )
        ''');
      }
    } finally {
      await db.close();
    }
  }

  /// Get ALL unsent locations ordered oldest-first (insertion order).
  /// Used by the batch-flush path so the backend receives points in
  /// chronological order and spike-detection works correctly.
  static Future<List<Map<String, dynamic>>> getAllUnsent() async {
    final db = await _open();
    try {
      return await db.query(
        _table,
        where: 'sent = 0',
        orderBy: 'id ASC',
      );
    } finally {
      await db.close();
    }
  }

  /// Get the most recent unsent location (for sending to server).
  static Future<Map<String, dynamic>?> getLatestUnsent() async {
    final db = await _open();
    try {
      final rows = await db.query(
        _table,
        where: 'sent = 0',
        orderBy: 'id DESC',
        limit: 1,
      );
      return rows.isNotEmpty ? rows.first : null;
    } finally {
      await db.close();
    }
  }

  /// Get count of unsent locations.
  static Future<int> getUnsentCount() async {
    final db = await _open();
    try {
      return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $_table WHERE sent = 0'),
          ) ??
          0;
    } finally {
      await db.close();
    }
  }

  /// Mark all unsent locations as sent.
  static Future<void> markAllSent() async {
    final db = await _open();
    try {
      await db.update(_table, {'sent': 1}, where: 'sent = 0');
    } finally {
      await db.close();
    }
  }

  /// Delete old sent records (cleanup). Keep only last 24 hours.
  static Future<void> cleanup() async {
    final db = await _open();
    try {
      final cutoff =
          DateTime.now().subtract(const Duration(hours: 24)).toIso8601String();
      await db.delete(
        _table,
        where: 'sent = 1 AND timestamp < ?',
        whereArgs: [cutoff],
      );
    } finally {
      await db.close();
    }
  }

  /// Get the most recent location (sent or unsent) — used by WorkManager
  /// to send a heartbeat even if the foreground service is dead.
  static Future<Map<String, dynamic>?> getLastKnownLocation() async {
    final db = await _open();
    try {
      final rows = await db.query(
        _table,
        orderBy: 'id DESC',
        limit: 1,
      );
      return rows.isNotEmpty ? rows.first : null;
    } finally {
      await db.close();
    }
  }

  /// Clear all data (used on logout/journey end).
  static Future<void> clearAll() async {
    final db = await _open();
    try {
      await db.delete(_table);
    } finally {
      await db.close();
    }
  }
}
