import 'dart:io';

import 'package:bestseeds/driver/controllers/profile_controller.dart';
import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

class DriverEditProfileScreen extends StatefulWidget {
  const DriverEditProfileScreen({super.key});

  @override
  State<DriverEditProfileScreen> createState() =>
      _DriverEditProfileScreenState();
}

class _DriverEditProfileScreenState extends State<DriverEditProfileScreen> {
  final DriverProfileController profileController =
      Get.find<DriverProfileController>();
  final DriverAuthRepository _repo = DriverAuthRepository();
  final DriverStorageService _storage = DriverStorageService();

  final nameController = TextEditingController();

  File? _selectedImage;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadDriverData();
  }

  void _loadDriverData() {
    final driver = profileController.driver.value;
    if (driver != null) {
      nameController.text = driver.name;
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

      final updatedDriver = await _repo.updateProfile(
        token: token,
        name: nameController.text.trim(),
        profileImage: _selectedImage,
      );

      await _storage.saveDriver(updatedDriver);
      profileController.driver.value = updatedDriver;

      AppSnackbar.success('Profile updated successfully');
      Get.back();
    } catch (e) {
      AppSnackbar.error(extractErrorMessage(e));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    final driver = profileController.driver.value;

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
                          : driver?.fullProfileImageUrl.isNotEmpty == true
                              ? DecorationImage(
                                  image:
                                      NetworkImage(driver!.fullProfileImageUrl),
                                  fit: BoxFit.cover,
                                )
                              : null,
                    ),
                    child: _selectedImage == null &&
                            driver?.fullProfileImageUrl.isNotEmpty != true
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
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Name',
                prefixIcon:
                    const Icon(Icons.person_outline, color: Color(0xFF0077C8)),
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
                  borderSide:
                      const BorderSide(color: Color(0xFF0077C8), width: 2),
                ),
              ),
            ),
            SizedBox(height: height * 0.02),

            // Mobile Field (Read-only)
            TextField(
              readOnly: true,
              controller: TextEditingController(text: driver?.mobile ?? ''),
              decoration: InputDecoration(
                labelText: 'Mobile',
                prefixIcon:
                    const Icon(Icons.phone_outlined, color: Color(0xFF0077C8)),
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
            SizedBox(height: height * 0.01),
            Text(
              'Mobile number cannot be changed',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
              ),
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

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }
}
