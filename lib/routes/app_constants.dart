class AppConstants {
  static String appName = "Best Seeds";
  static String driverRole = "Driver";
  static String employeeRole = "Employee";

  // static String baseUrl = "https://bestseed.in/api/";
  // static String baseUrl = "http://192.168.29.111:8000/api/";
  static String baseUrl = "http://127.0.0.1:8000/api/";

  // Employee/Vendor APIs
  static String employeeLoginApi = "vendor/login";
  static String employeeLogoutApi = "vendor/logout";
  static String employeeSetNewPasswordApi = "vendor/set-new-password";
  static String employeeUpdateProfileApi = "vendor/update-profile";
  static String employeeProfileApi = "vendor/profile";
  static String employeeUpdateLocationApi = "vendor/update-location";

  // Employee Booking APIs
  static String employeeBookingsApi = "vendor/bookings";
  static String employeeAcceptBookingApi = "vendor/bookings"; // /{bookingId}/accept
  static String employeeRejectBookingApi = "vendor/bookings"; // /{bookingId}/reject
  static String employeeUpdateBookingApi = "vendor/bookings"; // /{bookingId}/update
  static String employeeChangeDriverApi = "vendor/bookings"; // /{bookingId}/change-driver
  static String employeeRemoveDriverApi = "vendor/bookings"; // /{bookingId}/remove-driver
  static String employeeAddDriverApi = "vendor/bookings"; // /{bookingId}/add-driver
  static String employeeGetDriversApi = "vendor/drivers"; // GET list of drivers
  static String employeeBookingTrackingApi = "vendor/bookings"; // /{bookingId}/tracking

  // Driver APIs
  static String driverLoginApi = "driver/login";
  static String driverVerifyOtpApi = "driver/verify-otp";
  static String driverResendOtpApi = "driver/resend-otp";
  static String driverUpdateProfileApi = "driver/update-profile";
  static String driverProfileApi = "driver/profile";
  static String driverLogoutApi = "driver/logout";
  static String driverBookingsApi = "driver/bookings";
  static String driverStartJourneyApi = "driver/start-journey";
  static String driverUpdateDropStatusApi = "driver/update-drop-status";
  static String driverLocationUpdateApi = "driver/location/update";
  static String driverUpdateCurrentLocationApi = "driver/update-location";
  static String driverTrackingAlertApi = "driver/tracking-alert";
  static String driverRegisterFcmTokenApi = "driver/register-fcm-token";

  // Vendor/Employee FCM
  static String vendorRegisterFcmTokenApi = "vendor/register-fcm-token";
}