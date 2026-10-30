import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// عميل HTTP موحد يرفق Firebase ID token تلقائيًا بكل طلب API.
/// يستخدم التوكن الحالي، ويترك Firebase يجدده عند الحاجة بدل فرض التجديد مع كل طلب.
class AuthHttp {
  static Future<Map<String, String>> _headers(Map<String, String>? headers) async {
    final result = <String, String>{...?headers};
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final token = await user.getIdToken();
      if (token != null && token.isNotEmpty) result['Authorization'] = 'Bearer $token';
    }
    return result;
  }

  static Future<http.Response> get(Uri url, {Map<String, String>? headers}) async =>
      http.get(url, headers: await _headers(headers));

  static Future<http.Response> post(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async =>
      http.post(url, headers: await _headers(headers), body: body, encoding: encoding);

  static Future<http.Response> put(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async =>
      http.put(url, headers: await _headers(headers), body: body, encoding: encoding);

  static Future<http.Response> delete(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async =>
      http.delete(url, headers: await _headers(headers), body: body, encoding: encoding);
}
