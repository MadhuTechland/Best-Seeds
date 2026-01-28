import 'dart:io';

import 'package:bestseeds/employee/controllers/profile_controller.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

class EmployeeEditProfileScreen extends StatefulWidget {
  const EmployeeEditProfileScreen({super.key});

  @override
  State<EmployeeEditProfileScreen> createState() =>
      _EmployeeEditProfileScreenState();
}

class _EmployeeEditProfileScreenState extends State<EmployeeEditProfileScreen> {
  final EmployeeProfileController profileController =
      Get.find<EmployeeProfileController>();
  final AuthRepository _repo = AuthRepository();
  final StorageService _storage = StorageService();

  final nameController = TextEditingController();
  final mobileController = TextEditingController();
  final alternateMobileController = TextEditingController();
  final addressController = TextEditingController();
  final pincodeController = TextEditingController();

  File? _selectedImage;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  void _loadUserData() {
    final user = profileController.user.value;
    if (user != null) {
      nameController.text = user.name;

      // Strip +91 for editing
      mobileController.text = user.mobile.replaceFirst(RegExp(r'^\+91'), '');

      alternateMobileController.text =
          user.alternateMobile?.replaceFirst(RegExp(r'^\+91'), '') ?? '';

      addressController.text = user.address ?? '';
      pincodeController.text = user.pincode ?? '';
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      setState(() {
        _selectedImage = File(pickedFile.path);
      });
    }
  }

  Future<void> _updateProfile() async {
    if (nameController.text.trim().isEmpty) {
      AppSnackbar.error('Name is required');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final token = _storage.getToken();
      if (token == null) {
        AppSnackbar.error('Session expired. Please login again.');
        return;
      }

      final updatedUser = await _repo.updateProfile(
        token: token,
        name: nameController.text.trim(),
        // mobile: normalizeIndianMobile(mobileController.text),
        alternateMobile: alternateMobileController.text.trim().isEmpty
            ? null
            : normalizeIndianMobile(alternateMobileController.text),
        address: addressController.text.trim().isEmpty
            ? null
            : addressController.text.trim(),
        pincode: pincodeController.text.trim().isEmpty
            ? null
            : pincodeController.text.trim(),
        profileImage: _selectedImage,
      );

      await _storage.saveUser(updatedUser);
      profileController.user.value = updatedUser;

      Get.back();
      AppSnackbar.success('Profile updated successfully');
    } catch (e) {
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String normalizeIndianMobile(String input) {
    String number = input.trim();

    // Remove spaces, hyphens, etc.
    number = number.replaceAll(RegExp(r'\s+|-'), '');

    // Already in +91 format
    if (number.startsWith('+91')) {
      return number;
    }

    // Starts with 91 but missing +
    if (number.startsWith('91') && number.length == 12) {
      return '+$number';
    }

    // Plain 10-digit number
    if (number.length == 10) {
      return '+91$number';
    }

    // Fallback: return as-is (backend will validate)
    return number;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    final user = profileController.user.value;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0077C8),
        foregroundColor: Colors.white,
        title: const Text('Edit Profile'),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(width * 0.05),
        child: Column(
          children: [
            SizedBox(height: height * 0.02),
            // Profile Image
            GestureDetector(
              onTap: _pickImage,
              child: Stack(
                children: [
                  Container(
                    width: width * 0.3,
                    height: width * 0.3,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.grey.shade300,
                      image: _selectedImage != null
                          ? DecorationImage(
                              image: FileImage(_selectedImage!),
                              fit: BoxFit.cover,
                            )
                          : user?.fullProfileImageUrl.isNotEmpty == true
                              ? DecorationImage(
                                  image:
                                      NetworkImage(user!.fullProfileImageUrl),
                                  fit: BoxFit.cover,
                                )
                              : null,
                    ),
                    child: _selectedImage == null &&
                            user?.fullProfileImageUrl.isNotEmpty != true
                        ? Icon(
                            Icons.person,
                            size: width * 0.15,
                            color: Colors.grey.shade500,
                          )
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        color: Color(0xFF0077C8),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.camera_alt,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: height * 0.04),

            // Name Field
            _buildTextField(
              controller: nameController,
              label: 'Name',
              icon: Icons.person_outline,
            ),
            SizedBox(height: height * 0.02),

            // Mobile Field
            InkWell(
              onTap: () {
                AppSnackbar.info(
                  'Information',
                  'Mobile number cannot be changed',
                );
              },
              borderRadius: BorderRadius.circular(12),
              child: AbsorbPointer(
                child: _buildTextField(
                  controller: mobileController,
                  label: 'Mobile',
                  icon: Icons.phone_outlined,
                  prefixText: '+91 ',
                  readOnly: true,
                  enabled: true, // keep enabled so UI looks normal
                ),
              ),
            ),
            SizedBox(height: height * 0.02),

            // Alternate Mobile Field
            _buildTextField(
              controller: alternateMobileController,
              label: 'Alternate Mobile (Optional)',
              icon: Icons.phone_outlined,
              keyboardType: TextInputType.phone,
              prefixText: '+91 ',
            ),
            SizedBox(height: height * 0.02),

            // Address Field
            _buildTextField(
              controller: addressController,
              label: 'Address (Optional)',
              icon: Icons.location_on_outlined,
              maxLines: 2,
            ),
            SizedBox(height: height * 0.02),

            // Pincode Field
            _buildTextField(
              controller: pincodeController,
              label: 'Pincode (Optional)',
              icon: Icons.pin_drop_outlined,
              keyboardType: TextInputType.number,
            ),
            SizedBox(height: height * 0.04),

            // Update Button
            SizedBox(
              width: double.infinity,
              height: height * 0.06,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _updateProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0077C8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        'Update Profile',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    String? prefixText,
    bool readOnly = false,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      readOnly: readOnly,
      enabled: enabled,
      enableInteractiveSelection: false,
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefixText,
        prefixIcon: Icon(icon, color: const Color(0xFF0077C8)),
        filled: !enabled,
        fillColor: enabled ? null : Colors.grey.shade100,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF0077C8), width: 2),
        ),
      ),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    mobileController.dispose();
    alternateMobileController.dispose();
    addressController.dispose();
    pincodeController.dispose();
    super.dispose();
  }
}
