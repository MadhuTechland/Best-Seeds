import 'package:bestseeds/driver/controllers/driver_auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class OtpVerificationScreen extends StatefulWidget {
  const OtpVerificationScreen({super.key});

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final DriverAuthController controller = Get.find<DriverAuthController>();
  final List<TextEditingController> otpControllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> focusNodes = List.generate(6, (_) => FocusNode());

  // Track if OTP is complete (6 digits)
  bool _isOtpComplete = false;

  String get otpCode => otpControllers.map((c) => c.text).join();

  @override
  void initState() {
    super.initState();
    // Start resend timer when screen opens
    controller.startResendTimer();
    // Add listeners to track OTP completion
    for (var ctrl in otpControllers) {
      ctrl.addListener(_checkOtpComplete);
    }
  }

  @override
  void dispose() {
    for (var ctrl in otpControllers) {
      ctrl.removeListener(_checkOtpComplete);
      ctrl.dispose();
    }
    for (var node in focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _checkOtpComplete() {
    final isComplete = otpCode.length == 6;
    if (isComplete != _isOtpComplete) {
      setState(() {
        _isOtpComplete = isComplete;
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
                                children: [
                                  GestureDetector(
                                    onTap: () => Get.back(),
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: const BoxDecoration(
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
                                    'OTP Verification',
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
                                  'Verify Your\nMobile Number',
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
                                child: Obx(() => Text(
                                      'We have sent a 6-digit OTP to\n${controller.mobile.value}',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: width * 0.04,
                                      ),
                                      textAlign: TextAlign.center,
                                    )),
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
                                'Enter OTP',
                                style: TextStyle(
                                  fontSize: width * 0.045,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: height * 0.025),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: List.generate(
                                  6,
                                  (index) => SizedBox(
                                    width: (width - width * 0.12 - 30) / 6,
                                    height: width * 0.13,
                                    child: TextField(
                                      controller: otpControllers[index],
                                      focusNode: focusNodes[index],
                                      textAlign: TextAlign.center,
                                      keyboardType: TextInputType.number,
                                      maxLength: 1,
                                      style: TextStyle(
                                        fontSize: width * 0.05,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      decoration: InputDecoration(
                                        counterText: '',
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                vertical: 12),
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          borderSide: BorderSide(
                                              color: Colors.grey.shade300),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          borderSide: const BorderSide(
                                            color: Color(0xFF0077C8),
                                            width: 2,
                                          ),
                                        ),
                                      ),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                      onChanged: (value) {
                                        if (value.isNotEmpty && index < 5) {
                                          focusNodes[index + 1].requestFocus();
                                        }
                                        if (value.isEmpty && index > 0) {
                                          focusNodes[index - 1].requestFocus();
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(height: height * 0.03),
                              Obx(() => SizedBox(
                                    width: double.infinity,
                                    height: height * 0.06,
                                    child: ElevatedButton(
                                      onPressed:
                                          controller.isLoading.value ||
                                                  !_isOtpComplete
                                              ? null
                                              : () {
                                                  controller
                                                      .verifyOtp(otpCode);
                                                },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _isOtpComplete
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
                                              'Verify OTP',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: _isOtpComplete
                                                    ? Colors.white
                                                    : Colors.white.withValues(
                                                        alpha: 0.7),
                                              ),
                                            ),
                                    ),
                                  )),
                              SizedBox(height: height * 0.02),
                              Center(
                                child: Obx(() {
                                  if (controller.resendTimer.value > 0) {
                                    final minutes =
                                        controller.resendTimer.value ~/ 60;
                                    final seconds =
                                        controller.resendTimer.value % 60;
                                    final timeStr = minutes > 0
                                        ? '${minutes}m ${seconds.toString().padLeft(2, '0')}s'
                                        : '${seconds}s';
                                    return Text(
                                      'Resend OTP in $timeStr',
                                      style: TextStyle(
                                        fontSize: width * 0.035,
                                        color: Colors.grey,
                                      ),
                                    );
                                  }
                                  return GestureDetector(
                                    onTap: controller.isLoading.value
                                        ? null
                                        : () => controller.resendOtp(),
                                    child: Text(
                                      'Resend OTP',
                                      style: TextStyle(
                                        fontSize: width * 0.035,
                                        color: const Color(0xFF0077C8),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  );
                                }),
                              ),
                              SizedBox(height: height * 0.02),
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
