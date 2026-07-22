import 'package:flutter/material.dart';
import 'package:get/get.dart';

class AppSnackbar {
  static void error(String message) {
    Get.snackbar(
      'Error',
      message,
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.red.shade600,
      colorText: Colors.white,
      margin: const EdgeInsets.all(16),
      borderRadius: 12,
      duration: const Duration(seconds: 3),
    );
  }

  static void success(String message) {
    Get.snackbar(
      'Success',
      message,
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.green.shade600,
      colorText: Colors.white,
      margin: const EdgeInsets.all(16),
      borderRadius: 12,
      duration: const Duration(seconds: 3),
    );
  }

  static void info(String title, String message) {
    Get.snackbar(
      title,
      message,
      snackPosition: SnackPosition.BOTTOM,
      margin: const EdgeInsets.all(16),
      borderRadius: 12,
      duration: const Duration(seconds: 3),
    );
  }
}

void toast(String message) {
  Get.rawSnackbar(
    message: message,
    snackPosition: SnackPosition.BOTTOM,
    backgroundColor: Colors.red.shade600,
    margin: const EdgeInsets.all(16),
    borderRadius: 12,
    duration: const Duration(seconds: 2),
  );
}

String extractErrorMessage(dynamic error) {
  if (error == null) return 'Something went wrong';

  String message = error.toString();

  // Remove "Exception:" prefix if present
  if (message.startsWith('Exception:')) {
    message = message.replaceFirst('Exception:', '').trim();
  }

  // If the message is empty or just whitespace, return default
  if (message.isEmpty || message.trim().isEmpty) {
    return 'Something went wrong';
  }

  // Convert raw network/system errors to user-friendly messages.
  //
  // Only genuine "phone has no network" signals map to the "No internet"
  // wording — SocketException, DNS/host-lookup failures, "network is
  // unreachable", "no address associated". Everything else (ClientException,
  // connection refused, TLS errors) is a server- or transport-side issue and
  // must not blame the driver's network.
  final lower = message.toLowerCase();
  if (lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('network is unreachable') ||
      lower.contains('no address associated')) {
    return 'No internet connection. Please check your network and try again.';
  }
  if (lower.contains('handshakeexception') || lower.contains('certificate')) {
    return 'Secure connection failed. Please try again.';
  }
  if (lower.contains('clientexception') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('connection closed')) {
    return 'Connection issue. Please try again.';
  }
  if (lower.contains('timeoutexception') || lower.contains('timed out')) {
    return 'Request timed out. Please try again.';
  }
  if (lower.contains('formatexception') ||
      lower.contains('unexpected character') ||
      lower.contains('invalid json') ||
      lower.contains('<html')) {
    return 'Server is temporarily unavailable. Please try again later.';
  }

  return message;
}