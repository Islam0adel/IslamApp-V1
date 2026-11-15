// lib/services/api_service.dart

import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants.dart';
import 'auth_http.dart';

class ApiService {
  final String baseUrl = ApiConstants.baseUrl;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ============================================================
  // 1. تسجيل الدخول (إيميل / موبايل / يوزرنيم)
  // ============================================================

  Future<Map<String, dynamic>> login(String identifier, String password) async {
    try {
      // 1) Resolve identifier → email
      final resolved = await resolveIdentifier(identifier);
      if (resolved['found'] != true) {
        throw 'بيانات الدخول غير صحيحة. إذا لم تكمل التسجيل، اضغط "إنشاء حساب".';
      }

      final email = (resolved['email'] as String? ?? '').trim().toLowerCase();
      if (email.isEmpty) {
        throw 'هذا الحساب لم يكمل التسجيل. اضغط "إنشاء حساب" لإكماله.';
      }

      // 2) Sign in with Firebase Auth
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // 3) Verify with backend
      String? token = await userCredential.user?.getIdToken();
      if (token == null || token.isEmpty) {
        throw 'تعذر الحصول على التوكن';
      }

      final response = await AuthHttp.post(
        Uri.parse('$baseUrl/auth/verify-user'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }

      throw jsonDecode(response.body)['detail'] ?? 'فشل جلب بيانات المستخدم';
    } on FirebaseAuthException catch (e) {
      throw _handleAuthError(e.code);
    } catch (e) {
      throw e.toString();
    }
  }

  // ============================================================
  // 2. استعادة كلمة المرور (Legacy — verify-reset)
  // ============================================================

  Future<Map<String, dynamic>> verifyAndGetResetLink({
    required String email,
    required String companyCode,
    required String jobCode,
  }) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/verify-reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim().toLowerCase(),
        'company_code': companyCode.trim(),
        'job_code': jobCode.trim(),
      }),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل التحقق من البيانات';
  }

  // ============================================================
  // 3. التسجيل الجديد (Phone → Email → Verification)
  // ============================================================

  /// يترجم (إيميل / موبايل / يوزرنيم) إلى إيميل
  Future<Map<String, dynamic>> resolveIdentifier(String identifier) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/resolve-identifier'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'identifier': identifier.trim()}),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    if (response.statusCode == 429) {
      throw 'محاولات كثيرة، حاول بعد دقيقة';
    }
    throw jsonDecode(response.body)['detail'] ?? 'فشل التحقق';
  }

  /// يتحقق إن الرقم مسجل من الأدمن
  Future<Map<String, dynamic>> checkPhone(String phone) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/check-phone'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phone.trim()}),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل التحقق من الرقم';
  }

  /// إكمال التسجيل (إنشاء Firebase Auth + ربط + إرسال verification)
  ///
  /// - [phoneNumber] اختياري (للسوبر أدمن مش مطلوب)
  /// - [employeeCode] اختياري (لربط الموظف في HR)
  /// - [name] اختياري (للسوبر أدمن)
  Future<Map<String, dynamic>> completeRegistration({
    String? phoneNumber,
    required String email,
    required String password,
    String? username,
    String? name,
    String? employeeCode,
  }) async {
    try {
      // 1) Create Firebase Auth account
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );

      // 2) Send verification email (best-effort)
      try {
        await userCredential.user?.sendEmailVerification();
      } catch (e) {
        print('⚠️ sendEmailVerification failed: $e');
      }

      // 3) Call backend (with Firebase ID token)
      final idToken = await userCredential.user!.getIdToken();
      final response = await AuthHttp.post(
        Uri.parse('$baseUrl/auth/complete-registration'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
        body: jsonEncode({
          if (phoneNumber != null && phoneNumber.trim().isNotEmpty)
            'phone_number': phoneNumber.trim(),
          'email': email.trim().toLowerCase(),
          'uid': userCredential.user!.uid,
          if (username != null && username.trim().isNotEmpty)
            'username': username.trim(),
          if (name != null && name.trim().isNotEmpty)
            'name': name.trim(),
          if (employeeCode != null && employeeCode.trim().isNotEmpty)
            'employee_code': employeeCode.trim(),
        }),
      );

      // 4) Rollback on failure
      if (response.statusCode != 200) {
        try {
          await userCredential.user?.delete();
        } catch (_) {}
        throw jsonDecode(response.body)['detail'] ?? 'فشل إكمال التسجيل';
      }

      return jsonDecode(response.body);
    } on FirebaseAuthException catch (e) {
      throw _handleAuthError(e.code);
    }
  }

  /// جلب بيانات المستخدم بعد التحقق (يستخدم Firebase ID token)
  Future<Map<String, dynamic>> verifyUser() async {
    final user = _auth.currentUser;
    if (user == null) throw 'لا يوجد مستخدم مسجل';

    final token = await user.getIdToken(true);
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/verify-user'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل التحقق';
  }

  /// فحص إن الإيميل اتحقق (مع reload)
  Future<bool> checkEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
    } catch (_) {}
    return _auth.currentUser?.emailVerified ?? false;
  }

  /// إعادة إرسال رابط التحقق
  Future<void> resendEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null) throw 'لا يوجد مستخدم';
    await user.sendEmailVerification();
  }

  // ============================================================
  // 3.5. إدارة مستخدمي الشركة (Admin)
  // ============================================================

  /// جلب مستخدمي الشركة (حسب صلاحية الأدمن)
  Future<List<dynamic>> getCompanyUsers({String? companyCode}) async {
    final uri = Uri.parse('$baseUrl/auth/company-users').replace(
      queryParameters: {
        if (companyCode != null && companyCode.isNotEmpty)
          'company_code': companyCode,
      },
    );
    final response = await AuthHttp.get(uri);
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is List) return decoded;
      return [];
    }
    throw jsonDecode(response.body)['detail'] ?? 'فشل جلب المستخدمين';
  }

  /// إضافة مستخدم جديد (من الأدمن)
  Future<Map<String, dynamic>> adminAddUser({
    required String name,
    required String phoneNumber,
    required String branchCode,
    required String role, // "admin" | "employee"
    String? companyCode, // للسوبر أدمن فقط
    String? email,
    String? username,
  }) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/admin/add-user'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name.trim(),
        'phone_number': phoneNumber.trim(),
        'branch_code': branchCode.trim(),
        'role': role.trim(),
        if (companyCode != null && companyCode.trim().isNotEmpty)
          'company_code': companyCode.trim(),
        if (email != null && email.trim().isNotEmpty)
          'email': email.trim().toLowerCase(),
        if (username != null && username.trim().isNotEmpty)
          'username': username.trim().toLowerCase(),
      }),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل إضافة المستخدم';
  }

  /// تعديل مستخدم
  Future<Map<String, dynamic>> adminEditUser({
    required String email,
    String? name,
    String? phoneNumber,
    String? branchCode,
    String? role,
    String? username,
    String? status,
  }) async {
    final response = await AuthHttp.put(
      Uri.parse('$baseUrl/auth/admin/edit-user'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim().toLowerCase(),
        if (name != null) 'name': name.trim(),
        if (phoneNumber != null) 'phone_number': phoneNumber.trim(),
        if (branchCode != null) 'branch_code': branchCode.trim(),
        if (role != null) 'role': role,
        if (username != null) 'username': username.trim(),
        if (status != null) 'status': status,
      }),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل تعديل المستخدم';
  }

  /// حذف مستخدم
  Future<Map<String, dynamic>> adminDeleteUser({
    required String email,
  }) async {
    final uri = Uri.parse('$baseUrl/auth/admin/delete-user')
        .replace(queryParameters: {'email': email.trim().toLowerCase()});
    final response = await AuthHttp.delete(uri);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل حذف المستخدم';
  }

  /// إعادة تعيين مستخدم معلق
  Future<Map<String, dynamic>> adminResetPendingUser({
    required String email,
  }) async {
    final uri = Uri.parse('$baseUrl/auth/admin/reset-pending-user')
        .replace(queryParameters: {'email': email.trim().toLowerCase()});
    final response = await AuthHttp.post(uri);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل إعادة التعيين';
  }

    /// ⭐ إلغاء التسجيل (من شاشة تحقق الإيميل)
  Future<Map<String, dynamic>> cancelRegistration() async {
    final user = _auth.currentUser;
    if (user == null) throw 'لا يوجد مستخدم';

    final token = await user.getIdToken(true);
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/cancel-registration'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل إلغاء التسجيل';
  }

    // ============================================================
  // طلبات الانضمام
  // ============================================================

  /// المستخدم يطلب الانضمام لشركة (بدون تحديد الشركة — الأدمن يحددها)
  Future<Map<String, dynamic>> requestRegistration({
    required String name,
    String? phoneNumber,
    String? email,
    String? companyCode,  // ⭐ اختياري
    String? branchCode,
    String? note,
  }) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/request-registration'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name.trim(),
        if (phoneNumber != null && phoneNumber.trim().isNotEmpty)
          'phone_number': phoneNumber.trim(),
        if (email != null && email.trim().isNotEmpty)
          'email': email.trim().toLowerCase(),
        if (companyCode != null && companyCode.trim().isNotEmpty)
          'company_code': companyCode.trim(),
        if (branchCode != null && branchCode.trim().isNotEmpty)
          'branch_code': branchCode.trim(),
        if (note != null && note.trim().isNotEmpty)
          'note': note.trim(),
      }),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل إرسال الطلب';
  }

  /// جلب طلبات الانضمام (للأدمن)
  Future<List<dynamic>> getRegistrationRequests({
    String status = 'pending',
  }) async {
    final uri = Uri.parse('$baseUrl/auth/admin/registration-requests')
        .replace(queryParameters: {'status': status});
    final response = await AuthHttp.get(uri);
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is List) return decoded;
      return [];
    }
    throw jsonDecode(response.body)['detail'] ?? 'فشل جلب الطلبات';
  }

  /// الموافقة على طلب
  Future<Map<String, dynamic>> approveRegistrationRequest({
    required String requestId,
    required String role,
    String? branchCode,
    String? companyCode,  // ⭐ للسوبر أدمن (لو الطلب مش محدد شركة)
  }) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/admin/registration-requests/$requestId/approve'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'role': role,
        if (branchCode != null && branchCode.trim().isNotEmpty)
          'branch_code': branchCode.trim(),
        if (companyCode != null && companyCode.trim().isNotEmpty)
          'company_code': companyCode.trim(),
      }),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل الموافقة';
  }

  /// رفض طلب
  Future<Map<String, dynamic>> rejectRegistrationRequest({
    required String requestId,
  }) async {
    final response = await AuthHttp.post(
      Uri.parse('$baseUrl/auth/admin/registration-requests/$requestId/reject'),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw jsonDecode(response.body)['detail'] ?? 'فشل الرفض';
  }


  // ============================================================
  // 4. الفروع
  // ============================================================

  /// جلب قائمة الفروع (Hive أولاً، ثم السيرفر)
  Future<List<String>> getBranchesList(String companyCode) async {
    try {
      final Box codingBox = Hive.box('coding_box');
      final String localKey = "${companyCode}_branches";

      if (codingBox.containsKey(localKey)) {
        final dynamic rawData = codingBox.get(localKey);
        if (rawData is List) {
          List<String> fetchedBranches = ["كل الفروع"];
          for (var item in rawData) {
            if (item is Map && item['name'] != null) {
              fetchedBranches.add(item['name'].toString());
            }
          }
          return fetchedBranches;
        }
      }

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

  // ============================================================
  // 5. الصلاحيات
  // ============================================================

  Future<void> updatePermissions(
    String email,
    Map<String, dynamic> permissions, {
    List<String>? allowedBranches,
    List<String>? hrViewableEmployees,
    bool clearHrViewableEmployees = false,
  }) async {
    try {
      final body = <String, dynamic>{
        'email': email,
        'permissions': permissions,
      };

      if (allowedBranches != null) {
        body['allowed_branches'] = allowedBranches;
      }

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

  // ============================================================
  // 6. إدارة الشركات (لصاحب البرنامج فقط)
  // ============================================================

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

  Future<void> toggleCompanyStatus(
    String code,
    bool isActive,
    String adminJobCode,
  ) async {
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
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        final errorMsg =
            jsonDecode(response.body)['detail'] ?? 'فشل تحديث الشركة';
        throw Exception(errorMsg);
      }
    } catch (e) {
      print("❌ خطأ في updateCompany: $e");
      throw e.toString();
    }
  }

  Future<void> deleteCompany(String code, String adminJobCode) async {
    final response = await AuthHttp.delete(
      Uri.parse(
        '$baseUrl/auth/companies/delete/$code?admin_job_code=$adminJobCode',
      ),
    );
    if (response.statusCode != 200) {
      throw jsonDecode(response.body)['detail'] ?? 'فشل حذف الشركة';
    }
  }

  // ============================================================
  // 7. Helpers
  // ============================================================

  String _handleAuthError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'عذراً، هذا البريد الإلكتروني غير مسجل لدينا.';
      case 'wrong-password':
        return 'كلمة المرور التي أدخلتها غير صحيحة.';
      case 'invalid-credential':
        return 'بيانات الدخول غير صحيحة.';
      case 'email-already-in-use':
        return 'هذا البريد الإلكتروني مسجل بالفعل.';
      case 'invalid-email':
        return 'صيغة البريد الإلكتروني غير صحيحة.';
      case 'weak-password':
        return 'كلمة المرور ضعيفة جداً، يرجى اختيار كلمة أقوى.';
      case 'network-request-failed':
        return 'خطأ في الاتصال بالشبكة، تأكد من إنترنت جهازك.';
      case 'too-many-requests':
        return 'محاولات كثيرة جداً، حاول بعد قليل.';
      case 'user-disabled':
        return 'تم تعطيل هذا الحساب. يرجى التواصل مع الإدارة.';
      default:
        return 'حدث خطأ غير متوقع: $code';
    }
  }
}