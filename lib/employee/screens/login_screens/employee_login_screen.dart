import 'package:bestseeds/driver/screens/login_screens/login_screen.dart';
import 'package:bestseeds/employee/controllers/auth_controller.dart';
import 'package:bestseeds/employee/screens/employee_main_nav_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class EmployeeLoginScreen extends StatefulWidget {
  const EmployeeLoginScreen({super.key});

  @override
  State<EmployeeLoginScreen> createState() => _EmployeeLoginScreenState();
}

class _EmployeeLoginScreenState extends State<EmployeeLoginScreen> {
  final AuthController controller = Get.put(AuthController());

  final idCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  // Track if form is valid (ID not empty and password min 6 chars)
  bool _isFormValid = false;

  @override
  void initState() {
    super.initState();
    idCtrl.addListener(_checkFormValid);
    passCtrl.addListener(_checkFormValid);
  }

  @override
  void dispose() {
    idCtrl.removeListener(_checkFormValid);
    passCtrl.removeListener(_checkFormValid);
    idCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  void _checkFormValid() {
    final isValid = idCtrl.text.trim().isNotEmpty && passCtrl.text.length >= 6;
    if (isValid != _isFormValid) {
      setState(() {
        _isFormValid = isValid;
      });
    }
  }
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        width: width,
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
          child: CustomScrollView(
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
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
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
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

                    Flexible(
                      child: Center(
                        child: Image.asset(
                          'assets/images/employee_login.png',
                          width: width,
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
                            'Log in with your Best Seeds ID',
                            style: TextStyle(
                              fontSize: width * 0.045,
                              fontWeight: FontWeight.w600,
                            ),
                          ),

                          SizedBox(height: height * 0.025),

                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: Colors.grey.shade300),
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
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: Colors.grey.shade300),
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

                          Obx(() => SizedBox(
                                width: double.infinity,
                                height: height * 0.06,
                                child: ElevatedButton(
                                  onPressed:
                                      controller.isLoading.value ||
                                              !_isFormValid
                                          ? null
                                          : () {
                                              controller.employeeLogin(
                                                idCtrl.text.trim(),
                                                passCtrl.text.trim(),
                                              );
                                            },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isFormValid
                                        ? const Color(0xFF0077C8)
                                        : const Color(0xFF0077C8)
                                            .withValues(alpha: 0.4),
                                    disabledBackgroundColor:
                                        const Color(0xFF0077C8)
                                            .withValues(alpha: 0.4),
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: controller.isLoading.value
                                      ? const CircularProgressIndicator(
                                          color: Colors.white)
                                      : Text(
                                          'Continue',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: _isFormValid
                                                ? Colors.white
                                                : Colors.white.withValues(
                                                    alpha: 0.7),
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
            ],
          ),
        ),
      ),
    );
  }
}
