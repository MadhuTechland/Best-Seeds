import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const Color primaryColor = Color(0xFF0077C8);

  Future<void> _openWhatsApp() async {
    // Replace with your actual WhatsApp number
    const phoneNumber = '918431148811'; // Without + for WhatsApp URL
    final whatsappUrl = Uri.parse('https://wa.me/$phoneNumber');

    try {
      // Try launching directly - canLaunchUrl may return false on Android 11+
      final launched = await launchUrl(
        whatsappUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        // Fallback: try with whatsapp:// scheme
        final fallbackUrl = Uri.parse('whatsapp://send?phone=$phoneNumber');
        await launchUrl(fallbackUrl, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error opening WhatsApp: $e');
    }
  }

  Future<void> _makePhoneCall() async {
    // Replace with your actual phone number
    const phoneNumber = '+918431148811';
    final phoneUrl = Uri.parse('tel:$phoneNumber');

    try {
      await launchUrl(phoneUrl);
    } catch (e) {
      debugPrint('Error making phone call: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Help',
          style: TextStyle(
            color: Colors.black,
            fontSize: width * 0.045,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: width * 0.06),
                  child: Column(
                    children: [
                      SizedBox(height: height * 0.05),

                      /// Help Image
                      Image.asset(
                        'assets/images/help_support.png',
                        width: width * 0.7,
                        height: height * 0.3,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            width: width * 0.7,
                            height: height * 0.3,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.support_agent,
                                  size: width * 0.2,
                                  color: primaryColor,
                                ),
                                SizedBox(height: height * 0.02),
                                Text(
                                  'Support',
                                  style: TextStyle(
                                    fontSize: width * 0.04,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                      SizedBox(height: height * 0.04),

                      /// Title
                      Text(
                        "We're here to help — choose an option",
                        style: TextStyle(
                          fontSize: width * 0.052,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      SizedBox(height: height * 0.02),

                      /// Description
                      Text(
                        "If you're experiencing any difficulties while using the app, contact admin support here and we'll work to resolve the issue smoothly and efficiently.",
                        style: TextStyle(
                          fontSize: width * 0.038,
                          color: Colors.grey.shade600,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      SizedBox(height: height * 0.05),

                      /// WhatsApp Button
                      _buildContactButton(
                        context: context,
                        width: width,
                        height: height,
                        icon: 'assets/icons/whatsapp_icon.png',
                        fallbackIcon: Icons.chat,
                        label: 'WhatsApp',
                        onTap: _openWhatsApp,
                        isWhatsApp: true,
                      ),

                      SizedBox(height: height * 0.02),

                      /// Call Button
                      _buildContactButton(
                        context: context,
                        width: width,
                        height: height,
                        icon: 'assets/icons/call_icon.png',
                        fallbackIcon: Icons.phone,
                        label: 'Call',
                        onTap: _makePhoneCall,
                        isWhatsApp: false,
                      ),

                      SizedBox(height: height * 0.05),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactButton({
    required BuildContext context,
    required double width,
    required double height,
    required String icon,
    required IconData fallbackIcon,
    required String label,
    required VoidCallback onTap,
    required bool isWhatsApp,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          vertical: height * 0.018,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: Colors.grey.shade300,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              icon,
              width: width * 0.08,
              height: width * 0.08,
              errorBuilder: (context, error, stackTrace) {
                return Icon(
                  fallbackIcon,
                  size: width * 0.08,
                  color: isWhatsApp ? const Color(0xFF25D366) : primaryColor,
                );
              },
            ),
            SizedBox(width: width * 0.03),
            Text(
              label,
              style: TextStyle(
                fontSize: width * 0.042,
                fontWeight: FontWeight.w500,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
