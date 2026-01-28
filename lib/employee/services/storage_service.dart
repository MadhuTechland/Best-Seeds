import 'dart:convert';

import 'package:bestseeds/driver/models/user_model.dart';
import 'package:bestseeds/main.dart';

class StorageService {
  static const _key = 'user';
  static const _tokenKey = 'token';

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
}

