import 'dart:io';

import 'package:bestseeds/driver/models/user_model.dart';
import 'package:bestseeds/driver/service/auth_service.dart';
import 'package:bestseeds/employee/models/booking_model.dart';
import 'package:bestseeds/employee/services/booking_cache_service.dart';

class AuthRepository {
  final AuthService _service = AuthService();
  final EmployeeBookingCacheService _cache = EmployeeBookingCacheService();

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
    // Fetch all bookings across all pages
    final res = await _service.getAllEmployeeBookings(token: token);
    return BookingsResponse.fromJson(res);
  }

  /// Fetch a single page of bookings (for pagination with server-side filters)
  Future<BookingsResponse> getBookingsPage(
    String token, {
    int page = 1,
    String? tab,
    String? search,
    String? bookingType,
    String? vehicleAvailability,
  }) async {
    final res = await _service.getEmployeeBookings(
      token: token,
      page: page,
      tab: tab,
      search: search,
      bookingType: bookingType,
      vehicleAvailability: vehicleAvailability,
    );

    // Cache page 1 responses with no search/filters
    final isCacheable = page == 1 &&
        (search == null || search.isEmpty) &&
        bookingType == null &&
        vehicleAvailability == null;
    if (isCacheable) {
      _cache.cacheBookings(tab, res);
    }

    return BookingsResponse.fromJson(res);
  }

  /// Load bookings from local SQLite cache
  Future<BookingsResponse?> getCachedBookings(String? tab) async {
    return _cache.getCachedBookings(tab);
  }

  /// Fetch fresh tracking data for a single booking
  Future<Booking> getBookingTracking({
    required String token,
    required int bookingId,
  }) async {
    final res = await _service.getBookingTracking(
      token: token,
      bookingId: bookingId,
    );
    return Booking.fromJson(res['booking']);
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
    double? dropLat,
    double? dropLng,
    int? status,
    int? deliveryReason,
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
      dropLat: dropLat,
      dropLng: dropLng,
      status: status,
      deliveryReason: deliveryReason,
    );
  }

  Future<Map<String, dynamic>> getDrivers({required String token}) async {
    return await _service.getDrivers(token: token);
  }

  Future<Map<String, dynamic>> changeDriver({
    required String token,
    required int bookingId,
    int? driverId,
    String? driverName,
    required String driverMobile,
    required String vehicleNumber,
    String? vehicleStartDate,
    String? vehicleEndDate,
    double? vehicleStartLat,
    double? vehicleStartLng,
    String? vehicleStartAddress,
    int? priority,
  }) async {
    return await _service.changeDriver(
      token: token,
      bookingId: bookingId,
      driverId: driverId,
      driverName: driverName,
      driverMobile: driverMobile,
      vehicleNumber: vehicleNumber,
      vehicleStartDate: vehicleStartDate,
      vehicleEndDate: vehicleEndDate,
      vehicleStartLat: vehicleStartLat,
      vehicleStartLng: vehicleStartLng,
      vehicleStartAddress: vehicleStartAddress,
      priority: priority,
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

  Future<Map<String, dynamic>> updateCurrentLocation({
    required String token,
    required double latitude,
    required double longitude,
    required String address,
  }) async {
    return await _service.updateEmployeeCurrentLocation(
      token: token,
      latitude: latitude,
      longitude: longitude,
      address: address,
    );
  }
}

