import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';

class ApiService {
  final String baseUrl = ApiConstants.baseUrl;

  // 1. دالة تسجيل الدخول - تم تعديلها لاستقبال بيانات الوظيفة
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'email': email.trim().toLowerCase(),
          'password': password,
        }),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final errorData = jsonDecode(response.body);
        throw errorData['detail'] ?? 'فشل تسجيل الدخول';
      }
    } catch (e) {
      throw e.toString().replaceAll('Exception: ', '');
    }
  }

  // 2. دالة التسجيل - تم إضافة الـ jobCode لتتوافق مع صفحة الـ Register
  Future<void> register({
    required String name,
    required String email,
    required String password,
    required String companyCode,
    required String jobCode, // الحقل الجديد اللي كان مسبب الخطأ
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name.trim(),
          'email': email.trim().toLowerCase(),
          'password': password,
          'company_code': companyCode.trim(),
          'job_code': jobCode.trim(), // إرسال كود الوظيفة للباك إند
        }),
      );

      if (response.statusCode != 200) {
        final errorData = jsonDecode(response.body);
        throw errorData['detail'] ?? 'فشل إنشاء الحساب';
      }
    } catch (e) {
      throw e.toString().replaceAll('Exception: ', '');
    }
  }

  // 3. دالة طلب إعادة تعيين كلمة السر
  Future<void> resetPassword(String email) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email.trim().toLowerCase()}),
      );

      if (response.statusCode != 200) {
        final errorData = jsonDecode(response.body);
        throw errorData['detail'] ?? 'فشل إرسال رابط الاستعادة';
      }
    } catch (e) {
      throw e.toString().replaceAll('Exception: ', '');
    }
  }
  Future<Map<String, dynamic>> verifyAndGetResetLink({
  required String email,
  required String companyCode,
  required String jobCode,
}) async {
  final response = await http.post(
    Uri.parse('$baseUrl/auth/verify-reset'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'email': email,
      'company_code': companyCode,
      'job_code': jobCode,
    }),
  );

  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    final error = jsonDecode(response.body);
    throw error['detail'] ?? 'فشل التحقق';
  }
}
}