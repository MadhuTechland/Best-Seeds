import 'dart:async';

import 'package:bestseeds/driver/controllers/driver_auth_controller.dart';
import 'package:bestseeds/employee/screens/login_screens/employee_login_screen.dart';
import 'package:bestseeds/screens/privacy_policy_screen.dart';
import 'package:bestseeds/screens/terms_and_conditions_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:smart_auth/smart_auth.dart';

class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  final DriverAuthController controller = Get.put(DriverAuthController());
  final mobileCtrl = TextEditingController();

  // Track if mobile number is valid (10 digits)
  bool _isValidMobile = false;
  bool _isTermsAccepted = false;

  @override
  void initState() {
    super.initState();
    mobileCtrl.addListener(_onMobileChanged);
  }

  @override
  void dispose() {
    mobileCtrl.removeListener(_onMobileChanged);
    mobileCtrl.dispose();
    super.dispose();
  }

  void _onMobileChanged() {
    final isValid = mobileCtrl.text.length == 10;
    if (isValid != _isValidMobile) {
      setState(() {
        _isValidMobile = isValid;
      });
    }
  }

  /// Register a fresh SMS Retriever subscription right before the OTP request
  /// leaves the app. Google Play Services will deliver the incoming SMS
  /// (matching our app hash) to whichever subscription is active at the
  /// moment the message arrives — so registering earlier than sendOtp gives
  /// us the widest window and avoids losing a fast-delivered SMS.
  Future<void> _primeSmsRetriever() async {
    final smart = SmartAuth.instance;
    // One-time debug: print the hash the CURRENTLY-INSTALLED APK reports.
    // Must match the DLT template suffix (ATdoAuJ3d8y) — mismatch here is the
    // #1 cause of "auto-read doesn't work" on debug builds.
    if (kDebugMode) {
      final sig = await smart.getAppSignature();
      debugPrint('SMS App Signature (this APK): ${sig.data}');
    }
    // Reset any stale value from a previous login attempt.
    controller.autofilledOtp.value = '';
    // Fire-and-forget: when the SMS arrives Google hands it back here.
    // Not awaited so the send-OTP call proceeds in parallel.
    unawaited(smart
        .getSmsWithRetrieverApi(matcher: r'\d{6}')
        .then((res) {
      final code = res.hasData ? res.data?.code : null;
      if (code != null && code.length == 6) {
        controller.autofilledOtp.value = code;
      }
    }));
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
          child: SingleChildScrollView(
            reverse: true,
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
                          SizedBox(height: height * 0.04),
                          Text(
                            'Ready To Begin Your\nFirst Delivery',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: width * 0.07,
                              fontWeight: FontWeight.bold,
                              height: 1.3,
                            ),
                          ),
                          SizedBox(height: height * 0.015),
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
                    SizedBox(
                      height: height * 0.28,
                      child: Image.asset(
                        'assets/images/login_truck.png',
                        width: width,
                        fit: BoxFit.contain,
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.only(
                        left: width * 0.06,
                        right: width * 0.06,
                        top: height * 0.03,
                        bottom: height * 0.04,
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
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: Colors.grey.shade300),
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
                                      FilteringTextInputFormatter
                                          .digitsOnly,
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
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Checkbox(
                                value: _isTermsAccepted,
                                activeColor: const Color(0xFF0077C8),
                                onChanged: (val) {
                                  setState(() {
                                    _isTermsAccepted = val ?? false;
                                  });
                                },
                              ),
                              Expanded(
                                child: Wrap(
                                  children: [
                                    Text(
                                      'I agree to the ',
                                      style: TextStyle(
                                        fontSize: width * 0.032,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const TermsAndConditionsScreen(),
                                        ),
                                      ),
                                      child: Text(
                                        'Terms & Conditions',
                                        style: TextStyle(
                                          fontSize: width * 0.032,
                                          color: const Color(0xFF0077C8),
                                          fontWeight: FontWeight.w600,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      ' and ',
                                      style: TextStyle(
                                        fontSize: width * 0.032,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const PrivacyPolicyScreen(),
                                        ),
                                      ),
                                      child: Text(
                                        'Privacy Policy',
                                        style: TextStyle(
                                          fontSize: width * 0.032,
                                          color: const Color(0xFF0077C8),
                                          fontWeight: FontWeight.w600,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      ' of BestSeed.',
                                      style: TextStyle(
                                        fontSize: width * 0.032,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: height * 0.02),
                          Obx(() => SizedBox(
                                width: double.infinity,
                                height: height * 0.06,
                                child: ElevatedButton(
                                  onPressed:
                                      controller.isLoading.value ||
                                              !_isValidMobile ||
                                              !_isTermsAccepted
                                          ? null
                                          : () {
                                              final mobile =
                                                  mobileCtrl.text.trim();
                                              // Start the SMS Retriever
                                              // listener BEFORE the OTP is
                                              // sent — Google's API is
                                              // register-then-receive, so if
                                              // the SMS lands before the
                                              // listener is up we lose it.
                                              _primeSmsRetriever();
                                              controller.sendOtp(mobile);
                                            },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        (_isValidMobile && _isTermsAccepted)
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
                                            color: (_isValidMobile && _isTermsAccepted)
                                                ? Colors.white
                                                : Colors.white.withValues(
                                                    alpha: 0.7),
                                          ),
                                        ),
                                ),
                              )),
                        ],
                      ),
                    ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
