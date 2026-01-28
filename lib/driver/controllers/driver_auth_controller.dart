import 'package:bestseeds/driver/models/driver_model.dart';
import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:get/get.dart';

class DriverAuthController extends GetxController {
  final DriverAuthRepository _repo = DriverAuthRepository();
  final DriverStorageService _storage = DriverStorageService();

  RxBool isLoading = false.obs;
  RxString mobile = ''.obs;
  RxInt resendTimer = 0.obs;

  Future<void> sendOtp(String phoneNumber) async {
    try {
      print('Controller: sendOtp called with $phoneNumber');
      isLoading.value = true;

      final result = await _repo.sendOtp(phoneNumber);
      print('Controller: OTP sent -> $result');

      mobile.value = phoneNumber;
      await _storage.saveMobile(phoneNumber);

      AppSnackbar.success(
        result['message'] ?? 'OTP sent successfully',
      );
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
      print('Controller: Driver saved, navigating to home');

      Get.offAllNamed(AppRoutes.driverHome);
    } catch (e) {
      print('Controller ERROR: $e');
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
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
    } catch (e) {
      print('Controller ERROR: $e');
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
  }

  void startResendTimer() {
    resendTimer.value = 30;
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
      final token = _storage.getToken();
      if (token != null) {
        await _repo.logout(token);
      }
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
