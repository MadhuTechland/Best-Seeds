import 'package:bestseeds/driver/screens/login_screens/login_screen.dart';
import 'package:bestseeds/employee/controllers/auth_controller.dart';
import 'package:bestseeds/employee/screens/employee_main_nav_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class EmployeeLoginScreen extends StatelessWidget {
  EmployeeLoginScreen({super.key});
  final AuthController controller = Get.put(AuthController());

  final idCtrl = TextEditingController();
  final passCtrl = TextEditingController();
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
                    /// ================= Header + Text =================
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: width * 0.06,
                        vertical: height * 0.02,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          /// Header row
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Login as Employee',
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
                                        DriverLoginScreen(),
                                    ),
                                  ),
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
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

                          /// Title
                          Center(
                            child: Text(
                              'Secure Access for \n Best Seeds Employees',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: width * 0.07,
                                fontWeight: FontWeight.bold,
                                height: 1.3,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),

                    /// ================= Image Section =================
                    Flexible(
                      child: Center(
                        child: Image.asset(
                          'assets/images/employee_login.png',
                          width: width * 1,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),

                    /// ================= Bottom Card =================
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
                            'Log in with your Best Seeds ID',
                            style: TextStyle(
                              fontSize: width * 0.045,
                              fontWeight: FontWeight.w600,
                            ),
                          ),

                          SizedBox(height: height * 0.025),

                          /// Mobile input
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: idCtrl,
                                    keyboardType: TextInputType.text,
                                    decoration: const InputDecoration(
                                      hintText: 'Enter Best Seeds ID',
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: height * 0.03),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: passCtrl,
                                    keyboardType: TextInputType.text,
                                    decoration: const InputDecoration(
                                      hintText: 'Enter Password',
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: height * 0.03),

                          /// Continue button
                          Obx(() => SizedBox(
                                width: double.infinity,
                                height: height * 0.06,
                                child: ElevatedButton(
                                  onPressed: controller.isLoading.value
                                      ? null
                                      : () {
                                          print('UI: Continue button pressed');
                                          print(
                                              'UI: ID = ${idCtrl.text.trim()}');
                                          print(
                                              'UI: Password = ${passCtrl.text.trim()}');
                                          controller.employeeLogin(
                                            idCtrl.text.trim(),
                                            passCtrl.text.trim(),
                                          );
                                        },
                                  child: controller.isLoading.value
                                      ? const CircularProgressIndicator(
                                          color: Colors.white)
                                      : const Text('Continue'),
                                ),
                              )),

                          SizedBox(height: height * 0.02),

                          /// Footer text
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
