import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// Thrown when the backend rejects a driver login because the driver is
/// currently in an active journey on another device. The auth controller
/// catches this and shows a blocking dialog instead of a generic error.
class DriverInJourneyException implements Exception {
  final String message;
  DriverInJourneyException(this.message);
  @override
  String toString() => message;
}

/// Thrown when the backend rejects an employee login because the employee is
/// already logged in on another device. The auth controller catches this and
/// shows a blocking dialog instead of a generic error.
class EmployeeAlreadyLoggedInException implements Exception {
  final String message;
  EmployeeAlreadyLoggedInException(this.message);
  @override
  String toString() => message;
}

class ApiClient {
  /// Extracts error message from Laravel API response
  /// Handles various error formats:
  /// - {"message": "Error"} - simple message
  /// - {"errors": {"field": ["Error message"]}} - validation errors
  /// - {"error": "Error"} - alternative format
  String _extractErrorFromResponse(Map<String, dynamic> data) {
    // Check for 'message' field first
    if (data['message'] != null && data['message'].toString().isNotEmpty) {
      return data['message'].toString();
    }

    // Check for Laravel validation errors format
    if (data['errors'] != null && data['errors'] is Map) {
      final errors = data['errors'] as Map;
      if (errors.isNotEmpty) {
        // Get the first error message from the first field
        final firstFieldErrors = errors.values.first;
        if (firstFieldErrors is List && firstFieldErrors.isNotEmpty) {
          return firstFieldErrors.first.toString();
        }
        // If it's a string directly
        if (firstFieldErrors is String) {
          return firstFieldErrors;
        }
      }
    }

    // Check for 'error' field
    if (data['error'] != null && data['error'].toString().isNotEmpty) {
      return data['error'].toString();
    }

    return 'Something went wrong';
  }

  /// Force logout when driver logged in on another device (401 = token revoked)
  /// Silent — no messages, just kick to login screen immediately.
  void _handleForceLogout() {
    StorageService().logout();
    DriverStorageService().logout();
    BackgroundLocationService.stop();
    try { FirebaseMessaging.instance.deleteToken(); } catch (_) {}
    Get.offAllNamed(AppRoutes.login);
  }

  /// Force logout when admin deactivates the vendor/driver account
  void _handleAccountDeactivated(String message) {
    print('API CLIENT: Account deactivated — forcing logout');
    StorageService().logout();
    DriverStorageService().logout();
    BackgroundLocationService.stop();
    try { FirebaseMessaging.instance.deleteToken(); } catch (_) {}
    AppSnackbar.error(message);
    Get.offAllNamed(AppRoutes.login);
  }

  Future<Map<String, dynamic>> request({
    required String url,
    required Map<String, dynamic> body,
    String method = 'POST',
    String? token,
  }) async {
    print('API CLIENT: URL -> $url');
    print('API CLIENT: METHOD -> $method');
    print('API CLIENT: BODY -> $body');
    print("API CLIENT Token: $token");

    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };

    Future<http.Response> doHttp() async {
      switch (method.toUpperCase()) {
        case 'GET':
          return http.get(Uri.parse(url), headers: headers)
              .timeout(const Duration(seconds: 30));
        case 'PUT':
          return http.put(Uri.parse(url), headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 30));
        case 'DELETE':
          return http.delete(Uri.parse(url), headers: headers)
              .timeout(const Duration(seconds: 30));
        case 'POST':
        default:
          return http.post(Uri.parse(url), headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 30));
      }
    }

    http.Response response;

    // Perform the HTTP call with retry-once on any of:
    //   - SocketException / http.ClientException — brief network hiccup
    //     (mobile↔WiFi handoff, DNS timeout, socket teardown)
    //   - 401 with token present — transient auth 401 from a middlebox
    //     during the handoff (see network-transition comment below)
    //
    // Both classes of transient failure resolve on retry after ~1.5 s. The
    // "No internet" toast and the "session expired" logout were both the
    // same underlying network-hiccup symptom before this guard was added.
    try {
      try {
        response = await doHttp();
      } on SocketException {
        await Future.delayed(const Duration(milliseconds: 1500));
        response = await doHttp();
      } on http.ClientException {
        await Future.delayed(const Duration(milliseconds: 1500));
        response = await doHttp();
      }

      // Network-transition guard: retry ONCE on 401 with a token present.
      //
      // A 401 from our backend means auth failed and no side effects were
      // applied server-side, so retrying is safe. During a mobile ↔ WiFi
      // handoff (or on WiFi networks with captive-portal / proxy middleboxes),
      // a transient 401 can come back from an intermediary instead of our
      // server — treating that as "token revoked" and immediately kicking
      // the driver to the login screen is the bug the driver reported.
      //
      // 1.5 s delay is long enough for iOS/Android to finish the handoff
      // (usually completes in < 500 ms) but short enough that a real
      // revoked-token 401 still logs out in < 2 s total.
      if (response.statusCode == 401 && token != null) {
        await Future.delayed(const Duration(milliseconds: 1500));
        try {
          final retry = await doHttp();
          response = retry;
        } catch (_) {
          // Network still unstable — surface as a network error rather
          // than logging out. Driver keeps their session; next attempt
          // will typically succeed once WiFi finishes attaching.
          throw Exception('Network issue during request. Please try again.');
        }
      }
    } on SocketException {
      throw Exception('No internet connection. Please check your network and try again.');
    } on TimeoutException {
      throw Exception('Request timed out. Please try again.');
    } on http.ClientException {
      throw Exception('No internet connection. Please check your network and try again.');
    } on FormatException {
      throw Exception('Invalid server response. Please try again later.');
    }

    print('API CLIENT: Status Code -> ${response.statusCode}');
    print('API CLIENT: Raw Response -> ${response.body}');

    // Handle empty response body
    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {};
      }
      throw Exception('Empty response from server. Please try again.');
    }

    // Check if response is HTML (server error page) before parsing
    final bodyTrimmed = response.body.trimLeft();
    if (bodyTrimmed.startsWith('<') || bodyTrimmed.startsWith('<!')) {
      print('API CLIENT: Server returned HTML instead of JSON');
      throw Exception('Server is temporarily unavailable. Please try again later.');
    }

    // Parse JSON safely
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } on FormatException {
      throw Exception('Server is temporarily unavailable. Please try again later.');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      print('API CLIENT: Parsed Response -> $data');
      return data;
    } else {
      // 401 = token revoked (driver logged in on another device).
      // Only force-logout when the failing request actually carried a token —
      // pre-login endpoints (send/verify/resend OTP) also return 401 on bad
      // input and must not kick the user back to the login screen.
      if (response.statusCode == 401 && token != null) {
        _handleForceLogout();
      }

      // Check if account was deactivated by admin
      if (response.statusCode == 403 && data['account_inactive'] == true) {
        _handleAccountDeactivated(data['message'] ?? 'Your account has been deactivated.');
      }

      // Driver is in active journey on another device → typed exception so
      // the auth controller can show a blocking dialog instead of a snackbar.
      if (data is Map && data['error_code'] == 'DRIVER_IN_JOURNEY') {
        throw DriverInJourneyException(
          data['message']?.toString() ??
              'You are currently in an active journey on another device.',
        );
      }

      // Employee already logged in on another device → typed exception so
      // the auth controller can show a blocking dialog instead of a snackbar.
      if (data is Map && data['error_code'] == 'EMPLOYEE_ALREADY_LOGGED_IN') {
        throw EmployeeAlreadyLoggedInException(
          data['message']?.toString() ??
              'You are already logged in on another device.',
        );
      }
      print('API CLIENT ERROR: $data');

      // Handle 500+ server errors with friendly message
      if (response.statusCode >= 500) {
        throw Exception('Server error. Please try again later.');
      }

      final errorMessage = _extractErrorFromResponse(data);
      print('API CLIENT: Extracted Error Message -> $errorMessage');
      throw Exception(errorMessage);
    }
  }

  Future<Map<String, dynamic>> multipartRequest({
    required String url,
    required Map<String, String> fields,
    File? imageFile,
    String imageFieldName = 'profile_image',
    String? token,
  }) async {
    print('API CLIENT MULTIPART: URL -> $url');
    print('API CLIENT MULTIPART: FIELDS -> $fields');

    // Build fresh MultipartRequest on each attempt — http.MultipartRequest
    // is single-use (files are stream-consumed on send), so we can't reuse
    // the same instance for a retry.
    Future<http.Response> doMultipart() async {
      final req = http.MultipartRequest('POST', Uri.parse(url));
      req.headers.addAll({
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      });
      req.fields.addAll(fields);
      if (imageFile != null) {
        req.files.add(
          await http.MultipartFile.fromPath(imageFieldName, imageFile.path),
        );
      }
      final streamed = await req.send().timeout(const Duration(seconds: 60));
      return http.Response.fromStream(streamed);
    }

    http.Response response;

    // Same retry-once behaviour as request(): network hiccups AND transient
    // 401s both get a second attempt after a 1.5 s delay. Uploads are safe
    // to retry because a 401 means the server rejected before storage.
    try {
      try {
        response = await doMultipart();
      } on SocketException {
        await Future.delayed(const Duration(milliseconds: 1500));
        response = await doMultipart();
      } on http.ClientException {
        await Future.delayed(const Duration(milliseconds: 1500));
        response = await doMultipart();
      }
      if (response.statusCode == 401 && token != null) {
        await Future.delayed(const Duration(milliseconds: 1500));
        try {
          response = await doMultipart();
        } catch (_) {
          throw Exception('Network issue during upload. Please try again.');
        }
      }
    } on SocketException {
      throw Exception('No internet connection. Please check your network and try again.');
    } on TimeoutException {
      throw Exception('Request timed out. Please try again.');
    } on http.ClientException {
      throw Exception('No internet connection. Please check your network and try again.');
    } on FormatException {
      throw Exception('Invalid server response. Please try again later.');
    }

    print('API CLIENT MULTIPART: Status Code -> ${response.statusCode}');
    print('API CLIENT MULTIPART: Raw Response -> ${response.body}');

    // Handle empty response body
    if (response.body.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {};
      }
      throw Exception('Empty response from server. Please try again.');
    }

    // Check if response is HTML (server error page) before parsing
    final bodyTrimmed = response.body.trimLeft();
    if (bodyTrimmed.startsWith('<') || bodyTrimmed.startsWith('<!')) {
      print('API CLIENT MULTIPART: Server returned HTML instead of JSON');
      throw Exception('Server is temporarily unavailable. Please try again later.');
    }

    // Parse JSON safely
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } on FormatException {
      throw Exception('Server is temporarily unavailable. Please try again later.');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      print('API CLIENT MULTIPART: Parsed Response -> $data');
      return data;
    } else {
      // 401 = token revoked (driver logged in on another device).
      // Only force-logout when this multipart request actually carried a token.
      if (response.statusCode == 401 && token != null) {
        _handleForceLogout();
      }

      // Check if account was deactivated by admin
      if (response.statusCode == 403 && data['account_inactive'] == true) {
        _handleAccountDeactivated(data['message'] ?? 'Your account has been deactivated.');
      }
      print('API CLIENT MULTIPART ERROR: $data');

      // Handle 500+ server errors with friendly message
      if (response.statusCode >= 500) {
        throw Exception('Server error. Please try again later.');
      }

      final errorMessage = _extractErrorFromResponse(data);
      print('API CLIENT MULTIPART: Extracted Error Message -> $errorMessage');
      throw Exception(errorMessage);
    }
  }
}
