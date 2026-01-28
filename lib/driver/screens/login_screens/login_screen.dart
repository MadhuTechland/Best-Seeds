import 'package:bestseeds/driver/controllers/driver_auth_controller.dart';
import 'package:bestseeds/employee/screens/login_screens/employee_login_screen.dart';
import 'package:bestseeds/utils/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class DriverLoginScreen extends StatelessWidget {
  DriverLoginScreen({super.key});

  final DriverAuthController controller = Get.put(DriverAuthController());
  final mobileCtrl = TextEditingController();

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
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Login as Driver',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: width * 0.055,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              GestureDetector(
                                onTap: () => {
                                  Navigator.pushReplacement(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          EmployeeLoginScreen(),
                                    ),
                                  ),
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: const BoxDecoration(
                                    color: Colors.white24,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.more_horiz,
                                    color: Colors.white,
                                  ),
                                ),
                              )
                            ],
                          ),
                          SizedBox(height: height * 0.07),
                          Text(
                            'Ready To Begin Your\nFirst Delivery',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: width * 0.07,
                              fontWeight: FontWeight.bold,
                              height: 1.3,
                            ),
                          ),
                          SizedBox(height: height * 0.02),
                          Text(
                            'Just One Quick Step Remains To Get Started\nWith Your Deliveries.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: width * 0.038,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: Center(
                        child: Image.asset(
                          'assets/images/login_truck.png',
                          width: width * 1,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
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
                            'Log in using your mobile number to\nstart delivering',
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
                            child: Row(
                              children: [
                                const Text(
                                  '+91',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: mobileCtrl,
                                    keyboardType: TextInputType.phone,
                                    maxLength: 10,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                    ],
                                    decoration: const InputDecoration(
                                      hintText: 'Enter Mobile Number',
                                      border: InputBorder.none,
                                      counterText: '',
                                    ),
                                  ),
                                ),
                              ],
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
                                          final mobile = mobileCtrl.text.trim();
                                          if (mobile.length != 10) {
                                              AppSnackbar.error('Please enter a valid 10-digit mobile number');
                                            return;
                                          }
                                          controller.sendOtp(mobile);
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0077C8),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: controller.isLoading.value
                                      ? const CircularProgressIndicator(
                                          color: Colors.white)
                                      : const Text(
                                          'Continue',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                ),
                              )),
                          SizedBox(height: height * 0.02),
                          Center(
                            child: Text(
                              'By sign-in, I agree to the Terms & Conditions\nand Privacy Policy of BestSeed.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: width * 0.032,
                                color: Colors.grey,
                              ),
                            ),
                          ),
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
