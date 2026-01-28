import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class ApiClient {
  Future<Map<String, dynamic>> request({
    required String url,
    required Map<String, dynamic> body,
    String method = 'POST',
    String? token,
  }) async {
    print('API CLIENT: URL -> $url');
    print('API CLIENT: METHOD -> $method');
    print('API CLIENT: BODY -> $body');
    print("API CLIENT Token: $token");

    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };

    http.Response response;

    switch (method.toUpperCase()) {
      case 'GET':
        response = await http.get(
          Uri.parse(url),
          headers: headers,
        );
        break;
      case 'PUT':
        response = await http.put(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode(body),
        );
        break;
      case 'DELETE':
        response = await http.delete(
          Uri.parse(url),
          headers: headers,
        );
        break;
      case 'POST':
      default:
        response = await http.post(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode(body),
        );
        break;
    }

    print('API CLIENT: Status Code -> ${response.statusCode}');
    print('API CLIENT: Raw Response -> ${response.body}');

    final data = jsonDecode(response.body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      print('API CLIENT: Parsed Response -> $data');
      return data;
    } else {
      print('API CLIENT ERROR: $data');
      throw Exception(data['message'] ?? 'Something went wrong');
    }
  }

  Future<Map<String, dynamic>> multipartRequest({
    required String url,
    required Map<String, String> fields,
    File? imageFile,
    String imageFieldName = 'profile_image',
    String? token,
  }) async {
    print('API CLIENT MULTIPART: URL -> $url');
    print('API CLIENT MULTIPART: FIELDS -> $fields');

    final request = http.MultipartRequest('POST', Uri.parse(url));

    request.headers.addAll({
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    });

    request.fields.addAll(fields);

    if (imageFile != null) {
      print('API CLIENT MULTIPART: Adding image file');
      request.files.add(
        await http.MultipartFile.fromPath(imageFieldName, imageFile.path),
      );
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    print('API CLIENT MULTIPART: Status Code -> ${response.statusCode}');
    print('API CLIENT MULTIPART: Raw Response -> ${response.body}');

    final data = jsonDecode(response.body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      print('API CLIENT MULTIPART: Parsed Response -> $data');
      return data;
    } else {
      print('API CLIENT MULTIPART ERROR: $data');
      throw Exception(data['message'] ?? 'Something went wrong');
    }
  }
}
