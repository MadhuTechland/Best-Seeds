import 'package:bestseeds/driver/models/driver_model.dart';
import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/driver/services/tracking_alert_service.dart';
import 'package:bestseeds/routes/api_clients.dart';
import 'package:bestseeds/services/notification_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:bestseeds/widgets/login_location_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class DriverAuthController extends GetxController {
  final DriverAuthRepository _repo = DriverAuthRepository();
  final DriverStorageService _storage = DriverStorageService();

  RxBool isLoading = false.obs;
  RxString mobile = ''.obs;
  RxInt resendTimer = 0.obs;
  // Incremented whenever the OTP screen should clear its input boxes
  // (after a failed verify, or after a successful resend).
  RxInt otpClearSignal = 0.obs;
  // The 6-digit code SMS Retriever extracted from the OTP SMS. The listener
  // is primed on the login screen BEFORE the send-OTP request goes out
  // (Google's Retriever API is register-then-receive — starting it inside
  // the OTP screen's initState can lose a fast-delivered SMS), then the
  // OTP screen watches this Rx and auto-fills + auto-verifies.
  RxString autofilledOtp = ''.obs;

  Future<void> sendOtp(String phoneNumber) async {
    try {
      print('Controller: sendOtp called with $phoneNumber');
      isLoading.value = true;

      final result = await _repo.sendOtp(phoneNumber);
      print('Controller: OTP sent -> $result');

      mobile.value = phoneNumber;
      await _storage.saveMobile(phoneNumber);

      // Check if it's existing OTP (already sent within 2 minutes)
      final isExistingOtp = result['existing_otp'] == true;

      if (isExistingOtp) {
        AppSnackbar.info('OTP', result['message'] ?? 'OTP already sent. Check your SMS.');
      } else {
        AppSnackbar.success(result['message'] ?? 'OTP sent successfully');
      }

      Get.toNamed(AppRoutes.driverOtpVerification);
    } catch (e) {
      print('Controller ERROR: $e');
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> verifyOtp(String otpCode) async {
    try {
      print('Controller: verifyOtp called');
      isLoading.value = true;

      final driver = await _repo.verifyOtp(mobile.value, otpCode);
      print('Controller: OTP verified, driver=${driver.name}');

      await _storage.saveDriver(driver);
      print('Controller: Driver saved, navigating to location setup');

      // Register FCM token with backend
      NotificationService().registerDriverToken();

      // Navigate to location setup screen
      Get.offAll(() => LoginLocationScreen(
            userType: 'driver',
            onLocationSelected: (location) async {
              // Save location to local storage
              await _storage.saveLocation(
                latitude: location.latitude,
                longitude: location.longitude,
                address: location.address,
              );
              print('Controller: Location saved locally');

              // Save location to backend
              try {
                await _repo.updateCurrentLocation(
                  token: driver.token,
                  latitude: location.latitude,
                  longitude: location.longitude,
                  address: location.address,
                );
                print('Controller: Location saved to backend');
              } catch (e) {
                print('Controller: Failed to save location to backend: $e');
              }

              print('Controller: Navigating to home');
              // Navigate to home
              Get.offAllNamed(AppRoutes.driverHome);
            },
          ));
    } on DriverInJourneyException catch (e) {
      // Old device is mid-journey — block this login and tell the user.
      // No navigation, no token saved; the existing device keeps its session.
      print('Controller: Driver in journey on another device — blocking login');
      _showInJourneyDialog(e.message);
    } catch (e) {
      print('Controller ERROR: $e');
      AppSnackbar.error(extractErrorMessage(e));
      // Wrong / expired OTP — wipe the boxes so the driver can re-enter cleanly.
      otpClearSignal.value++;
    } finally {
      isLoading.value = false;
    }
  }

  void _showInJourneyDialog(String message) {
    Get.dialog(
      PopScope(
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text(
            'Already Logged In',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Get.back(),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF0077C8),
              ),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
      barrierDismissible: false,
    );
  }

  Future<void> resendOtp() async {
    try {
      print('Controller: resendOtp called');
      isLoading.value = true;

      final result = await _repo.resendOtp(mobile.value);
      print('Controller: OTP resent -> $result');

      AppSnackbar.success(
        result['message'] ?? 'OTP resent successfully',
      );
      startResendTimer();
      // Wipe digits from the now-invalidated previous OTP.
      otpClearSignal.value++;
    } catch (e) {
      print('Controller ERROR: $e');
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
  }

  void startResendTimer() {
    resendTimer.value = 120; // 2 minutes
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (resendTimer.value > 0) {
        resendTimer.value--;
        return true;
      }
      return false;
    });
  }

  Future<void> logout() async {
    try {
      isLoading.value = true;
      TrackingAlertService.stop();
      await BackgroundLocationService.stop();
      final token = _storage.getToken();
      if (token != null) {
        await _repo.logout(token);
      }
      try { await FirebaseMessaging.instance.deleteToken(); } catch (_) {}
      await _storage.logout();
      Get.offAllNamed(AppRoutes.login);
    } catch (e) {
      print('Controller ERROR: $e');
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
  }

  Driver? get currentDriver {
    return null; // Will be loaded from storage when needed
  }
}
