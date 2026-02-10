import 'dart:convert';

import 'package:bestseeds/driver/models/user_model.dart';
import 'package:bestseeds/main.dart';

class StorageService {
  static const _key = 'user';
  static const _tokenKey = 'token';
  static const _locationLatKey = 'employee_location_lat';
  static const _locationLngKey = 'employee_location_lng';
  static const _locationAddressKey = 'employee_location_address';

  Future<void> saveUser(User user) async {
    await prefs.setString(_key, jsonEncode(user.toJson()));
    await prefs.setString(_tokenKey, user.token);
  }

  Future<User?> getUser() async {
    final data = prefs.getString(_key);
    if (data == null) return null;

    final json = jsonDecode(data);
    return User.fromApi(json, json['token']);
  }

  String? getToken() {
    return prefs.getString(_tokenKey);
  }

  Future<void> logout() async {
    await prefs.clear();
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

