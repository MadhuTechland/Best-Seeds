import 'dart:io';

import 'package:bestseeds/driver/models/driver_booking_model.dart';
import 'package:bestseeds/driver/models/driver_model.dart';
import 'package:bestseeds/driver/service/auth_service.dart';

class DriverAuthRepository {
  final AuthService _service = AuthService();

  Future<Map<String, dynamic>> sendOtp(String mobile) async {
    print('Repository: sendOtp called');
    final res = await _service.driverLogin(mobile: mobile);
    print('Repository: sendOtp response -> $res');
    return res;
  }

  Future<Driver> verifyOtp(String mobile, String otpCode) async {
    print('Repository: verifyOtp called');
    final res = await _service.driverVerifyOtp(mobile: mobile, otpCode: otpCode);
    print('Repository: verifyOtp response -> $res');

    final token = res['token'] as String;
    print("Driver verified Token: $token");

    // Fetch driver profile after successful OTP verification
    final profileRes = await _service.getDriverProfile(token: token);
    print('Repository: profile response -> $profileRes');

    return Driver.fromApi(profileRes, token);
  }

  Future<Map<String, dynamic>> resendOtp(String mobile) async {
    print('Repository: resendOtp called');
    final res = await _service.driverResendOtp(mobile: mobile);
    print('Repository: resendOtp response -> $res');
    return res;
  }

  Future<Driver> getProfile(String token) async {
    print("Driver Token: $token");
    final res = await _service.getDriverProfile(token: token);
    return Driver.fromApi(res, token);
  }

  Future<Driver> updateProfile({
    required String token,
    required String name,
    File? profileImage,
  }) async {
    final res = await _service.updateDriverProfile(
      token: token,
      name: name,
      profileImage: profileImage,
    );
    return Driver.fromApi(res['driver'], token);
  }

  Future<void> logout(String token) async {
    await _service.driverLogout(token: token);
  }

  Future<DriverBookingResponse> getBookings(String token) async {
    final res = await _service.getDriverBookings(token: token);
    return DriverBookingResponse.fromJson(res);
  }

  Future<void> startJourney({
    required String token,
    required List<int> bookingIds,
  }) async {
    await _service.startJourney(token: token, bookingIds: bookingIds);
  }

  Future<Map<String, dynamic>> updateDropStatus({
    required String token,
    required int bookingId,
    required int status,
  }) async {
    return await _service.updateDropStatus(
      token: token,
      bookingId: bookingId,
      status: status,
    );
  }

  Future<Map<String, dynamic>> updateCurrentLocation({
    required String token,
    required double latitude,
    required double longitude,
    required String address,
  }) async {
    return await _service.updateDriverCurrentLocation(
      token: token,
      latitude: latitude,
      longitude: longitude,
      address: address,
    );
  }
}
