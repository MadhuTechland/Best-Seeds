import 'package:bestseeds/driver/models/user_model.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:get/get.dart';

class EmployeeProfileController extends GetxController {
  final StorageService _storage = StorageService();
  final AuthRepository _repo = AuthRepository();

  Rx<User?> user = Rx<User?>(null);
  RxBool isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadUser();
  }

  Future<void> loadUser() async {
    user.value = await _storage.getUser();
  }

  Future<void> refreshProfile() async {
    try {
      isLoading.value = true;
      final token = _storage.getToken();
      if (token != null) {
        final updatedUser = await _repo.getProfile(token);
        user.value = updatedUser;
        await _storage.saveUser(updatedUser);
      }
    } catch (e) {
      AppSnackbar.error('Failed to refresh profile');
    } finally {
      isLoading.value = false;
    }
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
      // Even if API fails, clear local storage and logout
      await _storage.logout();
      Get.offAllNamed(AppRoutes.login);
    } finally {
      isLoading.value = false;
    }
  }
}
