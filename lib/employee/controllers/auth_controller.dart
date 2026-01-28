import 'package:bestseeds/driver/models/user_model.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:get/get.dart';

class AuthController extends GetxController {
  final AuthRepository _repo = AuthRepository();
  final StorageService _storage = StorageService();

  RxBool isLoading = false.obs;
  RxBool requirePasswordReset = false.obs;
  RxInt vendorId = 0.obs;

  Future<void> employeeLogin(String id, String password) async {
    try {
      isLoading.value = true;

      final result = await _repo.employeeLogin(id, password);

      if (result is Map && result['resetRequired'] == true) {
        vendorId.value = result['vendorId'];
        requirePasswordReset.value = true;
        AppSnackbar.info(
          'Reset Password',
          result['message'] ?? 'Please set a new password',
        );
        Get.toNamed(AppRoutes.setPassword);
        return;
      }

      final user = result as User;
      await _storage.saveUser(user);
      Get.offAllNamed(AppRoutes.employeeHome);
    } catch (e) {
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> setNewPassword(String password) async {
    try {
      isLoading.value = true;
      await _repo.setNewPassword(vendorId.value, password);
      requirePasswordReset.value = false;
      AppSnackbar.success('Password updated. Please login again.');
      Get.offAllNamed(AppRoutes.employeeLogin);
    } catch (e) {
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      isLoading.value = false;
    }
  }
}
