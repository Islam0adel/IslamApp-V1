import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';

class ApiService {
  final String baseUrl = ApiConstants.baseUrl;

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

  // دالة طلب إعادة تعيين كلمة السر
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

  Future<void> register({
    required String name,
    required String email,
    required String password,
    required String companyCode,
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
        }),
      );

      if (response.statusCode != 200) {
        final errorData = jsonDecode(response.body);
        throw errorData['detail'] ?? 'خطأ في بيانات التسجيل';
      }
    } catch (e) {
      throw e.toString().replaceAll('Exception: ', '');
    }
  }
}