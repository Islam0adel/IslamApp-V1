import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';

class ApiService {
  final String baseUrl = ApiConstants.baseUrl;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // 1. تسجيل الدخول
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );

      String? token = await userCredential.user?.getIdToken();

      final response = await http.post(
        Uri.parse('$baseUrl/auth/verify-user'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final errorData = jsonDecode(response.body);
        throw errorData['detail'] ?? 'فشل جلب بيانات المستخدم';
      }
    } on FirebaseAuthException catch (e) {
      throw _handleAuthError(e.code);
    } catch (e) {
      throw e.toString();
    }
  }

  // 2. التسجيل الجديد
  Future<void> register({
    required String name,
    required String email,
    required String password,
    required String companyCode,
    required String jobCode,
  }) async {
    try {
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );

      final response = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name,
          'email': email,
          'uid': userCredential.user!.uid,
          'company_code': companyCode,
          'job_code': jobCode,
        }),
      );

      if (response.statusCode != 200) {
        await userCredential.user!.delete();
        final errorData = jsonDecode(response.body);
        throw errorData['detail'] ?? 'فشل حفظ البيانات';
      }
    } on FirebaseAuthException catch (e) {
      throw _handleAuthError(e.code);
    } catch (e) {
      throw e.toString();
    }
  }

  // 3. التحقق قبل استعادة كلمة المرور
  Future<Map<String, dynamic>> verifyAndGetResetLink({
    required String email,
    required String companyCode,
    required String jobCode,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/verify-reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim().toLowerCase(),
        'company_code': companyCode.trim(),
        'job_code': jobCode.trim(),
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      final error = jsonDecode(response.body);
      throw error['detail'] ?? 'فشل التحقق من البيانات';
    }
  }

  // ================= الدوال الجديدة الخاصة بالتكويد والربط =================

  // جلب بيانات التكويد (للقوائم المنسدلة وشاشة الإدارة)
  Future<List<dynamic>> getCodingData(String companyCode, String category) async {
    final response = await http.get(
      Uri.parse('$baseUrl/coding/list/$companyCode/$category'),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw 'فشل جلب بيانات $category';
    }
  }

  // حفظ أو تعديل تكويد (خزينة، مورد، إلخ)
  Future<void> saveNewCode(String companyCode, String category, String code, String name) async {
    final response = await http.post(
      Uri.parse('$baseUrl/coding/save'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'company_code': companyCode,
        'category': category,
        'code': code,
        'name': name,
      }),
    );
    if (response.statusCode != 200) throw 'فشل حفظ الكود في السيرفر';
  }

  // حذف تكويد نهائياً
  Future<void> deleteCode(String companyCode, String category, String code) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/coding/delete/$companyCode/$category/$code'),
    );
    if (response.statusCode != 200) throw 'فشل حذف الكود من السيرفر';
  }

  // دالة ترجمة أخطاء فايربيز
  String _handleAuthError(String code) {
    switch (code) {
      case 'user-not-found': return 'المستخدم غير موجود';
      case 'wrong-password': return 'كلمة المرور غير صحيحة';
      case 'email-already-in-use': return 'البريد مسجل مسبقاً';
      case 'weak-password': return 'كلمة المرور ضعيفة جداً';
      default: return 'حدث خطأ غير متوقع: $code';
    }
  }
}