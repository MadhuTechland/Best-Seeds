import 'dart:convert';

import 'package:bestseeds/driver/models/driver_model.dart';
import 'package:bestseeds/main.dart';

class DriverStorageService {
  static const _key = 'driver';
  static const _tokenKey = 'driver_token';
  static const _mobileKey = 'driver_mobile';
  static const _locationLatKey = 'driver_location_lat';
  static const _locationLngKey = 'driver_location_lng';
  static const _locationAddressKey = 'driver_location_address';

  Future<void> saveDriver(Driver driver) async {
    await prefs.setString(_key, jsonEncode(driver.toJson()));
    await prefs.setString(_tokenKey, driver.token);
  }

  Future<Driver?> getDriver() async {
    final data = prefs.getString(_key);
    if (data == null) return null;

    final json = jsonDecode(data);
    return Driver.fromJson(json);
  }

  String? getToken() {
    return prefs.getString(_tokenKey);
  }

  Future<void> saveMobile(String mobile) async {
    await prefs.setString(_mobileKey, mobile);
  }

  String? getMobile() {
    return prefs.getString(_mobileKey);
  }

  Future<void> logout() async {
    await prefs.remove(_key);
    await prefs.remove(_tokenKey);
    await prefs.remove(_mobileKey);
    await prefs.remove(_locationLatKey);
    await prefs.remove(_locationLngKey);
    await prefs.remove(_locationAddressKey);
  }

  Future<void> saveLocation({
    required double latitude,
    required double longitude,
    required String address,
  }) async {
    await prefs.setDouble(_locationLatKey, latitude);
    await prefs.setDouble(_locationLngKey, longitude);
    await prefs.setString(_locationAddressKey, address);
  }

  double? getLocationLat() {
    return prefs.getDouble(_locationLatKey);
  }

  double? getLocationLng() {
    return prefs.getDouble(_locationLngKey);
  }

  String? getLocationAddress() {
    return prefs.getString(_locationAddressKey);
  }

  bool hasLocation() {
    return prefs.containsKey(_locationLatKey) &&
        prefs.containsKey(_locationLngKey);
  }
}
