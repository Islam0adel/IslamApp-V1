import 'work_pool.dart';
import 'cache_partitions.dart';
import 'read_authorization_snapshot.dart';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// عميل HTTP موحد يرفق Firebase ID token تلقائيًا بكل طلب API.
/// يستخدم التوكن الحالي، ويترك Firebase يجدده عند الحاجة بدل فرض التجديد مع كل طلب.
class AuthHttp {
  static final _requests = WorkPool(5);
  static Future<T> _scheduled<T>(Future<T> Function() work) async {
    final user = FirebaseAuth.instance.currentUser;
    final epoch = ReadAuthorizationEpoch.value;
    final generation = CachePartitions.generation;
    return _requests.run(() async {
      final current = FirebaseAuth.instance.currentUser;
      if (current?.uid != user?.uid ||
          current?.email != user?.email ||
          epoch != ReadAuthorizationEpoch.value ||
          generation != CachePartitions.generation) {
        throw const ReadAuthorizationChanged();
      }
      CachePartitions.checkBoundWork();
      return work();
    });
  }

  static Future<Map<String, String>> _headers(
      Map<String, String>? headers) async {
    CachePartitions.checkBoundWork();
    final result = <String, String>{...?headers};
    final epoch = ReadAuthorizationEpoch.value;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final token = await user.getIdToken();
      if (token != null && token.isNotEmpty)
        result['Authorization'] = 'Bearer $token';
    }
    CachePartitions.checkBoundWork();
    final current = FirebaseAuth.instance.currentUser;
    if (current?.uid != user?.uid || current?.email != user?.email) {
      throw StateError('Account changed before the request was sent');
    }
    if (epoch != ReadAuthorizationEpoch.value)
      throw const ReadAuthorizationChanged();
    return result;
  }

  static Future<http.Response> _request(String method, Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    return _scheduled(() async {
      CachePartitions.checkBoundWork();
      final authorized = await _headers(headers);
      final http.Response response;
      switch (method) {
        case 'GET':
          response = await http.get(url, headers: authorized);
          break;
        case 'POST':
          response = await http.post(url,
              headers: authorized, body: body, encoding: encoding);
          break;
        case 'PUT':
          response = await http.put(url,
              headers: authorized, body: body, encoding: encoding);
          break;
        default:
          response = await http.delete(url,
              headers: authorized, body: body, encoding: encoding);
      }
      if (method == 'GET') CachePartitions.checkBoundWork();
      return response;
    });
  }

  static Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      _request('GET', url, headers: headers);
  static Future<http.Response> post(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      _request('POST', url, headers: headers, body: body, encoding: encoding);
  static Future<http.Response> put(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      _request('PUT', url, headers: headers, body: body, encoding: encoding);
  static Future<http.Response> delete(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      _request('DELETE', url, headers: headers, body: body, encoding: encoding);
}
