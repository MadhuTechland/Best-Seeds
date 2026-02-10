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

  return message;
}