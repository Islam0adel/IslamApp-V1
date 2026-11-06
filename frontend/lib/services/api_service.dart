import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';   // ← NEW
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'auth_http.dart';

class ApiService {
  final String baseUrl = ApiConstants.baseUrl;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ================= 1. قسم الحسابات والأمان (بدون أي حذف) =================

  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );

      // ============================================================
      // ✅ NEW: فحص is_active قبل ما نكمل تسجيل الدخول
      //
      // - لو is_active = false → نرفض الدخول + signOut
      // - لو Firestore offline → نكمل عادي (Firebase Auth كافي)
      // - لو المستند مش موجود → نعتبره active (احتياطي)
      // ============================================================
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(email.trim().toLowerCase())
            .get()
            .timeout(const Duration(seconds: 5));

        if (userDoc.exists) {
          final isActive = userDoc.data()?['is_active'] ?? true;
          if (isActive == false) {
            await _auth.signOut();
            throw 'تم إيقاف حسابك. يرجى التواصل مع الإدارة.';
          }
        }
      } catch (e) {
        // لو الرفض بسبب is_active → ارمي الخطأ
        if (e.toString().contains('تم إيقاف حسابك')) {
          rethrow;
        }
        // غير كده → Firestore offline أو مشكلة شبكة، نكمل
        print('⚠️ Firestore offline - skipping is_active check: $e');
      }
      // ============================================================

      // استخدام التوكن الحالي الصالح؛ Firebase يجدده عند الحاجة لتجنب refresh إجباري عند كل تسجيل دخول
      String? token = await userCredential.user?.getIdToken();
      // print("🔑 التوكن الذي يتم إرساله: $token");
      final response = await AuthHttp.post(
        Uri.parse('$baseUrl/auth/verify-user'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      throw jsonDecode(response.body)['detail'] ?? 'فشل جلب بيانات المستخدم';
    } on FirebaseAuthException catch (e) { throw _handleAuthError(e.code); }
    catch (e) { throw e.toString(); }
  }

    Future<void> register({
    required String name, 
    required String email, 
    required String password, 
    required String companyCode, 
    required String jobCode,
    String? employeeCode,   // ⭐ جديد
  }) async {
    try {
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email.trim().toLowerCase(), password: password,
      );
      final response = await AuthHttp.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name, 
          'email': email, 
          'uid': userCredential.user!.uid, 
          'company_code': companyCode, 
          'job_code': jobCode,
          if (employeeCode != null && employeeCode.trim().isNotEmpty)
            'employee_code': employeeCode.trim(),   // ⭐
        }),
      );
      if (response.statusCode != 200) {
        await userCredential.user!.delete();
        throw jsonDecode(response.body)['detail'] ?? 'فشل حفظ البيانات';
      }
    } on FirebaseAuthException catch (e) { throw _handleAuthError(e.code); }
    catch (e) { throw e.toString(); }
  }

  Future<Map<String, dynamic>> verifyAndGetResetLink({
    required String email, 
    required String companyCode, 
    required String jobCode
  }) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/verify-reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim().toLowerCase(), 
        'company_code': companyCode.trim(), 
        'job_code': jobCode.trim()
      }),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل التحقق من البيانات';
  }

  // جلب قائمة الفروع دايناميك بدون تأخير بناءً على الـ baseUrl المركزي
  // جلب قائمة الفروع (من Hive أولاً لتوفير الإنترنت والقراءات)
  Future<List<String>> getBranchesList(String companyCode) async {
    try {
      final Box codingBox = Hive.box('coding_box');
      final String localKey = "${companyCode}_branches";

      // 🌟 البحث في الذاكرة المحلية أولاً
      if (codingBox.containsKey(localKey)) {
        final dynamic rawData = codingBox.get(localKey);
        if (rawData is List) {
          List<String> fetchedBranches = ["كل الفروع"];
          for (var item in rawData) {
            if (item is Map && item['name'] != null) {
              fetchedBranches.add(item['name'].toString());
            }
          }
          return fetchedBranches; // إرجاع فوري بدون تحميل
        }
      }

      // لو الـ Hive فاضي (أول تشغيل مثلاً)، يجيب من السيرفر
      final response = await AuthHttp.get(
        Uri.parse('$baseUrl/coding/list/$companyCode/branches'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        List<dynamic> data = jsonDecode(response.body);
        List<String> fetchedBranches = ["كل الفروع"];
        for (var item in data) {
          if (item['name'] != null) {
            fetchedBranches.add(item['name'].toString());
          }
        }
        return fetchedBranches;
      }
      return ["كل الفروع"];
    } catch (e) {
      return ["كل الفروع"]; 
    }
  }

// في ApiService class
// أضف المعامل الاختياري allowedBranches
Future<void> updatePermissions(
  String email,
  Map<String, dynamic> permissions, {
  List<String>? allowedBranches,
  List<String>? hrViewableEmployees,       // ⭐ جديد
  bool clearHrViewableEmployees = false,   // ⭐ جديد
}) async {
  try {
    final body = <String, dynamic>{
      'email': email,
      'permissions': permissions,
    };

    if (allowedBranches != null) {
      body['allowed_branches'] = allowedBranches;
    }

    // ⭐ جديد: فلترة الموظفين في HR
    if (clearHrViewableEmployees) {
      body['hr_viewable_employees'] = null;
    } else if (hrViewableEmployees != null) {
      body['hr_viewable_employees'] = hrViewableEmployees;
    }

    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/update-permissions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw jsonDecode(response.body)['detail'] ?? 'فشل تحديث الصلاحيات';
    }
  } catch (e) {
    throw 'خطأ في تحديث الصلاحيات: $e';
  }
}

  // ================= 3. إدارة الشركات (لصاحب البرنامج فقط) =================

Future<List<dynamic>> getAllCompanies(String adminJobCode) async {
  final response = await AuthHttp.get(
    Uri.parse('$baseUrl/auth/companies/all?admin_job_code=$adminJobCode'),
  );
  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  }
  throw 'فشل جلب الشركات: ${response.body}';
}

Future<void> addCompany(String code, String name, String adminJobCode) async {
  final response = await AuthHttp.post(
    Uri.parse('$baseUrl/auth/companies/add?admin_job_code=$adminJobCode'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'code': code, 'name': name}),
  );
  if (response.statusCode != 200) {
    throw jsonDecode(response.body)['detail'] ?? 'فشل إضافة الشركة';
  }
}

Future<void> toggleCompanyStatus(String code, bool isActive, String adminJobCode) async {
  final response = await AuthHttp.post(
    Uri.parse('$baseUrl/auth/companies/toggle'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'code': code,
      'is_active': isActive,
      'admin_job_code': adminJobCode,
    }),
  );
  if (response.statusCode != 200) {
    throw jsonDecode(response.body)['detail'] ?? 'فشل تغيير حالة الشركة';
  }
}

// ================= إدارة الشركات (تعديل وحذف) =================

Future<void> updateCompany({
  required String oldCode,
  required String newCode,
  required String newName,
  required String adminJobCode,
}) async {
  try {
    final response = await AuthHttp.put(
      Uri.parse('$baseUrl/auth/companies/update'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'old_code': oldCode,
        'new_code': newCode,
        'new_name': newName,
        'admin_job_code': adminJobCode,
      }),
    ).timeout(const Duration(seconds: 10));  // ✅ مهلة 10 ثواني
    
    if (response.statusCode != 200) {
      final errorMsg = jsonDecode(response.body)['detail'] ?? 'فشل تحديث الشركة';
      throw Exception(errorMsg);
    }
  } catch (e) {
    print("❌ خطأ في updateCompany: $e");
    throw e.toString();
  }
}

Future<void> deleteCompany(String code, String adminJobCode) async {
  final response = await AuthHttp.delete(
    Uri.parse('$baseUrl/auth/companies/delete/$code?admin_job_code=$adminJobCode'),
  );
  if (response.statusCode != 200) {
    throw jsonDecode(response.body)['detail'] ?? 'فشل حذف الشركة';
  }
}



  // ================= 4. أدوات مساعدة (Helpers) =================

  // دالة التعامل مع أخطاء Firebase (بدون حذف)
  String _handleAuthError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'عذراً، هذا البريد الإلكتروني غير مسجل لدينا.';
      case 'wrong-password':
        return 'كلمة المرور التي أدخلتها غير صحيحة.';
      case 'email-already-in-use':
        return 'هذا البريد الإلكتروني مسجل بالفعل.';
      case 'invalid-email':
        return 'صيغة البريد الإلكتروني غير صحيحة.';
      case 'weak-password':
        return 'كلمة المرور ضعيفة جداً، يرجى اختيار كلمة أقوى.';
      case 'network-request-failed':
        return 'خطأ في الاتصال بالشبكة، تأكد من إنترنت جهازك.';
      default:
        return 'حدث خطأ غير متوقع: $code';
    }
  }
} // نهاية الكلاس