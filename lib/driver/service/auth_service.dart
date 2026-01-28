import 'dart:io';

import 'package:bestseeds/routes/api_clients.dart';
import 'package:bestseeds/routes/app_constants.dart';

class AuthService {
  final ApiClient _apiClient = ApiClient();

  // ==================== Employee/Vendor APIs ====================

  Future<Map<String, dynamic>> employeeLogin({
    required String bestSeedsId,
    required String password,
  }) async {
    print('Service: employeeLogin called');
    print('Service: ID=$bestSeedsId, Password=$password');

    return await _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.employeeLoginApi,
      body: {
        'best_seeds_id': bestSeedsId,
        'password': password,
      },
    );
  }

  Future<Map<String, dynamic>> setNewPassword({
    required int employeeId,
    required String newPassword,
  }) {
    return _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.employeeSetNewPasswordApi,
      body: {
        'vendor_id': employeeId,
        'new_password': newPassword,
        'new_password_confirmation': newPassword,
      },
    );
  }

  Future<Map<String, dynamic>> getEmployeeProfile({required String token}) {
    return _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.employeeProfileApi,
      body: {},
      method: 'GET',
      token: token,
    );
  }

  Future<Map<String, dynamic>> employeeLogout({required String token}) {
    return _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.employeeLogoutApi,
      body: {},
      token: token,
    );
  }

  Future<Map<String, dynamic>> updateEmployeeProfile({
    required String token,
    required String name,
    // required String mobile,
    String? alternateMobile,
    String? address,
    String? pincode,
    File? profileImage,
  }) {
    return _apiClient.multipartRequest(
      url: AppConstants.baseUrl + AppConstants.employeeUpdateProfileApi,
      fields: {
        'name': name,
        // 'mobile': mobile,
        if (alternateMobile != null) 'alternate_mobile': alternateMobile,
        if (address != null) 'address': address,
        if (pincode != null) 'pincode': pincode,
      },
      imageFile: profileImage,
      token: token,
    );
  }

  Future<Map<String, dynamic>> getEmployeeBookings({required String token}) {
    return _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.employeeBookingsApi,
      body: {},
      method: 'GET',
      token: token,
    );
  }

  Future<Map<String, dynamic>> acceptBooking({
    required String token,
    required int bookingId,
  }) {
    return _apiClient.request(
      url:
          '${AppConstants.baseUrl}${AppConstants.employeeAcceptBookingApi}/$bookingId/accept',
      body: {},
      token: token,
    );
  }

  Future<Map<String, dynamic>> rejectBooking({
    required String token,
    required int bookingId,
    required int reasonCode,
  }) {
    return _apiClient.request(
      url:
          '${AppConstants.baseUrl}${AppConstants.employeeRejectBookingApi}/$bookingId/reject',
      body: {
        'reason_code': reasonCode,
      },
      token: token,
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
  }) {
    return _apiClient.request(
      url:
          '${AppConstants.baseUrl}${AppConstants.employeeUpdateBookingApi}/$bookingId/update',
      method: 'PUT',
      body: {
        'no_of_pieces': noOfPieces,
        'salinity': salinity,
        'dropping_location': dropLocation,
        'packing_date': preferredDate,
        'price': travelCost,
        'delivery_datetime': expectedDeliveryDate,
        if (bookingDescription != null)
          'vendor_booking_description': bookingDescription,
        if (vehicleDescription != null)
          'vendor_vehicle_description': vehicleDescription,
        if (driverName != null) 'driver_name': driverName,
        if (driverMobile != null) 'driver_mobile': driverMobile,
        if (vehicleNumber != null) 'vehicle_number': vehicleNumber,
      },
      token: token,
    );
  }

  Future<Map<String, dynamic>> changeDriver({
    required String token,
    required int bookingId,
    required String driverName,
    required String driverMobile,
    required String vehicleNumber,
  }) {
    return _apiClient.request(
      url:
          '${AppConstants.baseUrl}${AppConstants.employeeChangeDriverApi}/$bookingId/change-driver',
      body: {
        'driver_name': driverName,
        'driver_mobile': driverMobile,
        'vehicle_number': vehicleNumber,
      },
      token: token,
    );
  }

  Future<Map<String, dynamic>> removeDriver({
    required String token,
    required int bookingId,
  }) {
    return _apiClient.request(
      url:
          '${AppConstants.baseUrl}${AppConstants.employeeRemoveDriverApi}/$bookingId/remove-driver',
      body: {},
      token: token,
    );
  }

  Future<Map<String, dynamic>> addDriver({
    required String token,
    required String bookingId,
    required int driverId,
  }) {
    return _apiClient.request(
      url:
          '${AppConstants.baseUrl}${AppConstants.employeeAddDriverApi}/$bookingId/add-driver',
      body: {
        'driver_id': driverId,
      },
      token: token,
    );
  }

  // ==================== Driver APIs ====================

  Future<Map<String, dynamic>> driverLogin({required String mobile}) async {
    print('Service: driverLogin called');
    print('Service: Mobile=$mobile');

    return await _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.driverLoginApi,
      body: {
        'mobile': mobile,
      },
    );
  }

  Future<Map<String, dynamic>> driverVerifyOtp({
    required String mobile,
    required String otpCode,
  }) async {
    print('Service: driverVerifyOtp called');
    print('Service: Mobile=$mobile, OTP=$otpCode');

    return await _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.driverVerifyOtpApi,
      body: {
        'mobile': mobile,
        'otp_code': otpCode,
      },
    );
  }

  Future<Map<String, dynamic>> driverResendOtp({required String mobile}) async {
    print('Service: driverResendOtp called');

    return await _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.driverResendOtpApi,
      body: {
        'mobile': mobile,
      },
    );
  }

  Future<Map<String, dynamic>> getDriverProfile({required String token}) {
    return _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.driverProfileApi,
      body: {},
      method: 'GET',
      token: token,
    );
  }

  Future<Map<String, dynamic>> driverLogout({required String token}) {
    return _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.driverLogoutApi,
      body: {},
      token: token,
    );
  }

  Future<Map<String, dynamic>> updateDriverProfile({
    required String token,
    required String name,
    File? profileImage,
  }) {
    return _apiClient.multipartRequest(
      url: AppConstants.baseUrl + AppConstants.driverUpdateProfileApi,
      fields: {
        'name': name,
      },
      imageFile: profileImage,
      token: token,
    );
  }

  Future<Map<String, dynamic>> getDriverBookings({required String token}) {
    return _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.driverBookingsApi,
      body: {},
      method: 'GET',
      token: token,
    );
  }

  Future<void> startJourney({
  required String token,
  required List<int> bookingIds,
}) async {
  await _apiClient.request(
    url: AppConstants.baseUrl + AppConstants.driverStartJourneyApi,
    method: 'POST',
    token: token,
    body: {
      'booking_ids': bookingIds,
    },
  );
}

  Future<Map<String, dynamic>> updateDropStatus({
    required String token,
    required int bookingId,
    required int status,
  }) async {
    return await _apiClient.request(
      url: AppConstants.baseUrl + AppConstants.driverUpdateDropStatusApi,
      method: 'POST',
      token: token,
      body: {
        'booking_id': bookingId,
        'status': status,
      },
    );
  }
}
