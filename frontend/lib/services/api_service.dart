import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';

class ApiService {
  final String baseUrl = ApiConstants.baseUrl;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // 1. تسجيل الدخول الاحترافي (Firebase Auth + FastAPI)
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      // أ- الدخول عبر فايربيز (التعامل مع الباسورد المشفر يتم هنا تلقائياً)
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );

      // ب- الحصول على الـ Token الخاص بالجلسة
      String? token = await userCredential.user?.getIdToken();

      // ج- إرسال التوكن للباك إند لجلب بيانات الصلاحيات والشركة
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
        throw errorData['detail'] ?? 'فشل جلب بيانات الصلاحيات';
      }
    } on FirebaseAuthException catch (e) {
      throw _handleAuthError(e.code);
    } catch (e) {
      throw e.toString();
    }
  }

  // 2. التسجيل الاحترافي (إنشاء مستخدم في Auth ثم حفظ بياناته في Firestore)
  Future<void> register({
    required String name,
    required String email,
    required String password,
    required String companyCode,
    required String jobCode,
  }) async {
    try {
      // أ- إنشاء الحساب في Firebase Auth
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );

      // ب- إرسال البيانات الشخصية للباك إند لحفظها في Firestore
      final response = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name.trim(),
          'email': email.trim().toLowerCase(),
          'uid': userCredential.user!.uid, // نرسل الـ UID لربط الحسابين
          'company_code': companyCode.trim(),
          'job_code': jobCode.trim(),
        }),
      );

      if (response.statusCode != 200) {
        // إذا فشل حفظ البيانات في Firestore، نمسح المستخدم من Auth لضمان النزاهة
        await userCredential.user!.delete();
        final errorData = jsonDecode(response.body);
        throw errorData['detail'] ?? 'فشل حفظ بيانات المستخدم';
      }
    } on FirebaseAuthException catch (e) {
      throw _handleAuthError(e.code);
    } catch (e) {
      throw e.toString();
    }
  }

  // 3. التحقق قبل إرسال رابط الاستعادة
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

  // دالة مساعدة لترجمة أخطاء فايربيز للعربية
  String _handleAuthError(String code) {
    switch (code) {
      case 'user-not-found': return 'هذا البريد غير مسجل لدينا';
      case 'wrong-password': return 'كلمة المرور غير صحيحة';
      case 'email-already-in-use': return 'البريد الإلكتروني مستخدم بالفعل';
      case 'weak-password': return 'كلمة المرور ضعيفة جداً';
      default: return 'حدث خطأ في نظام التوثيق: $code';
    }
  }
}