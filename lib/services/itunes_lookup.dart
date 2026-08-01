import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Result of a successful iTunes Lookup for an app.
class ITunesLookupResult {
  /// Latest version published on the App Store (semver, e.g. "1.0.17").
  final String version;

  /// Canonical App Store deep-link — `https://apps.apple.com/<cc>/app/<slug>/id<numeric>`.
  /// Empty string if Apple's response was malformed.
  final String trackViewUrl;

  const ITunesLookupResult({
    required this.version,
    required this.trackViewUrl,
  });
}

/// iOS equivalent of Google Play's `in_app_update` version check. Queries
/// Apple's public iTunes Lookup endpoint by bundle ID. Unauthenticated,
/// no API key needed. Returns null on any error — callers should
/// soft-fail so an outage never bricks the app.
class ITunesLookup {
  ITunesLookup._();

  /// Look up the current App Store version for [bundleId] in [country]
  /// (ISO-3166; "in" = India, "us" = US). If the primary storefront has
  /// no result, retries ONCE against the US storefront with HALF the
  /// remaining timeout so a slow network can't double the caller's
  /// budget. Returns null on any failure.
  static Future<ITunesLookupResult?> lookup({
    required String bundleId,
    String country = 'in',
    Duration timeout = const Duration(seconds: 6),
  }) async {
    try {
      final uri = Uri.https(
        'itunes.apple.com',
        '/lookup',
        {'bundleId': bundleId, 'country': country},
      );
      final res = await http.get(uri).timeout(timeout);
      if (res.statusCode != 200) {
        debugPrint('ITunesLookup: HTTP ${res.statusCode}');
        return null;
      }
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return null;
      final results = data['results'];
      if (results is! List || results.isEmpty) {
        if (country.toLowerCase() != 'us') {
          return lookup(
            bundleId: bundleId,
            country: 'us',
            timeout: Duration(milliseconds: timeout.inMilliseconds ~/ 2),
          );
        }
        return null;
      }
      final r = results.first;
      if (r is! Map<String, dynamic>) return null;
      final vRaw = r['version'];
      final version = (vRaw is String) ? vRaw.trim() : '';
      final tRaw = r['trackViewUrl'];
      final trackUrl = (tRaw is String) ? tRaw.trim() : '';
      if (version.isEmpty) return null;
      return ITunesLookupResult(
        version: version,
        trackViewUrl: trackUrl,
      );
    } catch (e) {
      debugPrint('ITunesLookup: $e');
      return null;
    }
  }
}
