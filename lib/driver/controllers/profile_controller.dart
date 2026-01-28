import 'package:bestseeds/driver/models/driver_booking_model.dart';
import 'package:bestseeds/driver/models/driver_model.dart';
import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class DriverProfileController extends GetxController {
  final DriverStorageService _storage = DriverStorageService();
  final DriverAuthRepository _repo = DriverAuthRepository();

  Rx<Driver?> driver = Rx<Driver?>(null);
  RxBool isLoading = false.obs;
  RxBool isCheckingBookings = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadDriver();
  }

  Future<void> loadDriver() async {
    driver.value = await _storage.getDriver();
  }

  Future<void> refreshProfile() async {
    try {
      isLoading.value = true;
      final token = _storage.getToken();
      if (token != null) {
        final updatedDriver = await _repo.getProfile(token);
        driver.value = updatedDriver;
        await _storage.saveDriver(updatedDriver);
      }
    } catch (e) {
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
  }

  /// Check if driver has ongoing bookings (status 4 = vehicle tracking/in progress)
  Future<bool> hasOngoingBookings() async {
    try {
      isCheckingBookings.value = true;
      final token = _storage.getToken();
      if (token == null) return false;

      final response = await _repo.getBookings(token);

      // Check if any route has status 4 (vehicle tracking - journey started)
      for (final route in response.routes) {
        if (route.routeStatus == 4) {
          return true;
        }
        // Also check individual bookings
        for (final booking in route.bookings) {
          if (booking.status == 4) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint('Error checking ongoing bookings: $e');
      return false;
    } finally {
      isCheckingBookings.value = false;
    }
  }

  Future<void> logout() async {
    try {
      isLoading.value = true;

      // Check for ongoing bookings before logout
      final hasOngoing = await hasOngoingBookings();
      if (hasOngoing) {
        isLoading.value = false;
        AppSnackbar.error('Please complete the ongoing booking before logout');
        return;
      }

      final token = _storage.getToken();
      if (token != null) {
        await _repo.logout(token);
      }
      await _storage.logout();
      Get.offAllNamed(AppRoutes.login);
    } catch (e) {
      // Even if API fails, clear local storage and logout
      await _storage.logout();
      Get.offAllNamed(AppRoutes.login);
    } finally {
      isLoading.value = false;
    }
  }
}
