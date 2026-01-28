import 'package:bestseeds/employee/controllers/auth_controller.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SetPasswordScreen extends StatelessWidget {
  SetPasswordScreen({super.key});

  final AuthController controller = Get.find<AuthController>();
  final newPassCtrl = TextEditingController();
  final confirmPassCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final height = media.size.height;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        width: width,
        height: height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0077C8),
              Color(0xFF3FA9F5),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: height -
                    MediaQuery.of(context).padding.top -
                    MediaQuery.of(context).padding.bottom,
              ),
              child: IntrinsicHeight(
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: width * 0.06,
                        vertical: height * 0.02,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              GestureDetector(
                                onTap: () => Get.back(),
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.arrow_back,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              SizedBox(width: width * 0.04),
                              Text(
                                'Set New Password',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: width * 0.055,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: height * 0.07),
                          Center(
                            child: Text(
                              'Create Your\nNew Password',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: width * 0.07,
                                fontWeight: FontWeight.bold,
                                height: 1.3,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          SizedBox(height: height * 0.02),
                          Center(
                            child: Text(
                              'Please set a new password for your account.\nThis is required for first-time login.',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: width * 0.04,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: width * 0.06,
                        vertical: height * 0.035,
                      ),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(30),
                          topRight: Radius.circular(30),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Enter your new password',
                            style: TextStyle(
                              fontSize: width * 0.045,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: height * 0.025),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: TextField(
                              controller: newPassCtrl,
                              obscureText: true,
                              decoration: const InputDecoration(
                                hintText: 'New Password',
                                border: InputBorder.none,
                                prefixIcon: Icon(Icons.lock_outline),
                              ),
                            ),
                          ),
                          SizedBox(height: height * 0.02),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: TextField(
                              controller: confirmPassCtrl,
                              obscureText: true,
                              decoration: const InputDecoration(
                                hintText: 'Confirm Password',
                                border: InputBorder.none,
                                prefixIcon: Icon(Icons.lock_outline),
                              ),
                            ),
                          ),
                          SizedBox(height: height * 0.03),
                          Obx(() => SizedBox(
                                width: double.infinity,
                                height: height * 0.06,
                                child: ElevatedButton(
                                  onPressed: controller.isLoading.value
                                      ? null
                                      : () {
                                          final newPass = newPassCtrl.text.trim();
                                          final confirmPass = confirmPassCtrl.text.trim();

                                          if (newPass.isEmpty || confirmPass.isEmpty) {
                                            AppSnackbar.error('Please fill all fields');
                                            return;
                                          }

                                          if (newPass != confirmPass) {
                                            AppSnackbar.error('Passwords do not match');
                                            return;
                                          }

                                          if (newPass.length < 6) {
                                            AppSnackbar.error('Password must be at least 6 characters');
                                            return;
                                          }

                                          controller.setNewPassword(newPass);
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0077C8),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: controller.isLoading.value
                                      ? const CircularProgressIndicator(color: Colors.white)
                                      : const Text(
                                          'Set Password',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                ),
                              )),
                          SizedBox(height: height * 0.02),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
