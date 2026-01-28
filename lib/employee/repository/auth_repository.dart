import 'dart:io';

import 'package:bestseeds/driver/models/user_model.dart';
import 'package:bestseeds/driver/service/auth_service.dart';
import 'package:bestseeds/employee/models/booking_model.dart';

class AuthRepository {
  final AuthService _service = AuthService();

  Future<dynamic> employeeLogin(String id, String password) async {
    print('Repository: employeeLogin called');

    final res = await _service.employeeLogin(
      bestSeedsId: id,
      password: password,
    );

    print('Repository: API response -> $res');

    if (res['require_password_reset'] == true) {
      return {
        'resetRequired': true,
        'vendorId': res['vendor_id'],
        'message': res['message'],
      };
    }

    return User.fromApi(res['vendor'], res['token']);
  }

  Future<void> setNewPassword(int vendorId, String password) async {
    await _service.setNewPassword(
      employeeId: vendorId,
      newPassword: password,
    );
  }

  Future<User> getProfile(String token) async {
    final res = await _service.getEmployeeProfile(token: token);
    return User.fromApi(res, token);
  }

  Future<User> updateProfile({
    required String token,
    required String name,
    // required String mobile,
    String? alternateMobile,
    String? address,
    String? pincode,
    File? profileImage,
  }) async {
    final res = await _service.updateEmployeeProfile(
      token: token,
      name: name,
      // mobile: mobile,
      alternateMobile: alternateMobile,
      address: address,
      pincode: pincode,
      profileImage: profileImage,
    );
    return User.fromApi(res['vendor'], token);
  }

  Future<void> logout(String token) async {
    await _service.employeeLogout(token: token);
  }

  Future<BookingsResponse> getBookings(String token) async {
    final res = await _service.getEmployeeBookings(token: token);
    print("Token: $token");
    return BookingsResponse.fromJson(res);
  }

  Future<Map<String, dynamic>> acceptBooking({
    required String token,
    required int bookingId,
  }) async {
    return await _service.acceptBooking(token: token, bookingId: bookingId);
  }

  Future<Map<String, dynamic>> rejectBooking({
    required String token,
    required int bookingId,
    required int reasonCode,
  }) async {
    return await _service.rejectBooking(
      token: token,
      bookingId: bookingId,
      reasonCode: reasonCode,
    );
  }

  Future<Map<String, dynamic>> updateBooking({
    required String token,
    required int bookingId,
    required int noOfPieces,
    required String salinity,
    required String dropLocation,
    required String preferredDate,
    required String travelCost,
    required String expectedDeliveryDate,
    String? bookingDescription,
    String? vehicleDescription,
    String? driverName,
    String? driverMobile,
    String? vehicleNumber,
  }) async {
    return await _service.updateBooking(
      token: token,
      bookingId: bookingId,
      noOfPieces: noOfPieces,
      salinity: salinity,
      dropLocation: dropLocation,
      preferredDate: preferredDate,
      travelCost: travelCost,
      expectedDeliveryDate: expectedDeliveryDate,
      bookingDescription: bookingDescription,
      vehicleDescription: vehicleDescription,
      driverName: driverName,
      driverMobile: driverMobile,
      vehicleNumber: vehicleNumber,
    );
  }

  Future<Map<String, dynamic>> changeDriver({
    required String token,
    required int bookingId,
    required String driverName,
    required String driverMobile,
    required String vehicleNumber,
  }) async {
    return await _service.changeDriver(
      token: token,
      bookingId: bookingId,
      driverName: driverName,
      driverMobile: driverMobile,
      vehicleNumber: vehicleNumber,
    );
  }

  Future<Map<String, dynamic>> removeDriver({
    required String token,
    required int bookingId,
  }) async {
    return await _service.removeDriver(
      token: token,
      bookingId: bookingId,
    );
  }

  Future<Map<String, dynamic>> addDriver({
    required String token,
    required String bookingId,
    required int driverId,
  }) async {
    return await _service.addDriver(
      token: token,
      bookingId: bookingId,
      driverId: driverId,
    );
  }
}

