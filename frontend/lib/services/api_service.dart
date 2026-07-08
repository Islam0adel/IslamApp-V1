import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
      // إضافة (true) تجبر Firebase على جلب توكن جديد وتحديث التوكن الحالي
      String? token = await userCredential.user?.getIdToken(true);
      print("🔑 التوكن الذي يتم إرساله: $token");
      final response = await http.post(
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
    required String jobCode
  }) async {
    try {
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email.trim().toLowerCase(), password: password,
      );
      final response = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name, 
          'email': email, 
          'uid': userCredential.user!.uid, 
          'company_code': companyCode, 
          'job_code': jobCode
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
    final response = await http.post(
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
      final response = await http.get(
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
Future<void> updatePermissions(String email, Map<String, dynamic> permissions) async {
  try {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/update-permissions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'permissions': permissions,
      }),
    );
    if (response.statusCode != 200) {
      throw jsonDecode(response.body)['detail'] ?? 'فشل تحديث الصلاحيات';
    }
  } catch (e) {
    throw 'خطأ في تحديث الصلاحيات: $e';
  }
}

  // ================= 2. قسم التكويد الجديد (المنطق المحدث) =================

// متغيرات ثابتة لحفظ الخزائن والتصنيفات مؤقتاً في الذاكرة لتوفير باقة الفايربيز
  static List<dynamic>? _cachedSafes;
  static List<dynamic>? _cachedTypes;

  // جلب قائمة الأكواد لأي قسم (خزائن، موردين، عملاء، إلخ)
  Future<List<dynamic>> getCodingData(String companyCode, String category) async {
    // 1. لو المطلوب خزائن وهي محفوظة مسبقاً في الكاش، رجعها فوراً
    if (category == "safes" && _cachedSafes != null) {
      return _cachedSafes!;
    }
    // 2. لو المطلوب تصنيفات وهي محفوظة مسبقاً في الكاش، رجعها فوراً
    if (category == "types" && _cachedTypes != null) {
      return _cachedTypes!;
    }

    final response = await http.get(Uri.parse('$baseUrl/coding/list/$companyCode/$category'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as List<dynamic>;
      
      // حفظ البيانات المستلمة في الكاش لاستدعائها مجاناً في المرات القادمة
      if (category == "safes") _cachedSafes = data;
      if (category == "types") _cachedTypes = data;
      
      return data;
    }
    throw 'فشل جلب بيانات $category';
  }

  // ميزة السيريال التلقائي: جلب الرقم القادم لكل قسم
  Future<int> getNextCode(String companyCode, String category) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/coding/next_code/$companyCode/$category'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body)['next_code'];
      }
      return 1; // لو مفيش بيانات ابدأ بواحد
    } catch (e) {
      return 1;
    }
  }

  // حفظ التكويد (يدعم السيريال التلقائي وتكويد الأصناف المتقدم)
  // تعديل دالة الحفظ في api_service.dart لضمان إرسال كافة بيانات الأصناف
  Future<void> saveNewCode({
    required String companyCode,
    required String category,
    required String code,
    required String name,
    String? barcode,
    double? wholesalePrice, // باراميتر سعر الجملة الجديد
    double? sellingPrice,   // باراميتر سعر البيع الجديد
    double? profitMargin,   // باراميتر هامش الربح الجديد
    double? profitPercent,  // باراميتر نسبة الربح الجديدة
    String? type,           // باراميتر نوع التصنيف المالي (وارد / صادر)
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/coding/save'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'company_code': companyCode,
        'category': category,
        'code': code,
        'name': name,
        'barcode': barcode ?? "", 
        'wholesale_price': wholesalePrice ?? 0.0, // إرسال سعر الجملة للباك إند
        'selling_price': sellingPrice ?? 0.0,     // إرسال سعر البيع للباك إند
        'profit_margin': profitMargin ?? 0.0,     // إرسال هامش الربح للباك إند
        'profit_percent': profitPercent ?? 0.0,   // إرسال نسبة الربح للباك إند
        'type': type ?? "وارد",                   // إرسال نوع التصنيف (وارد/صادر)
      }),
    );

    if (response.statusCode != 200) {
      throw 'فشل حفظ الكود: ${response.body}';
    }
  }

  // حذف التكويد مع رسالة تأكيد (كما طلبت في الورد)
  Future<void> deleteCode(String companyCode, String category, String code) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/coding/delete/$companyCode/$category/$code'),
    );
    if (response.statusCode != 200) throw 'فشل حذف الكود من السيرفر';
  }
 
  // ================= 3. إدارة الشركات (لصاحب البرنامج فقط) =================

Future<List<dynamic>> getAllCompanies(String adminJobCode) async {
  final response = await http.get(
    Uri.parse('$baseUrl/auth/companies/all?admin_job_code=$adminJobCode'),
  );
  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  }
  throw 'فشل جلب الشركات: ${response.body}';
}

Future<void> addCompany(String code, String name, String adminJobCode) async {
  final response = await http.post(
    Uri.parse('$baseUrl/auth/companies/add?admin_job_code=$adminJobCode'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'code': code, 'name': name}),
  );
  if (response.statusCode != 200) {
    throw jsonDecode(response.body)['detail'] ?? 'فشل إضافة الشركة';
  }
}

Future<void> toggleCompanyStatus(String code, bool isActive, String adminJobCode) async {
  final response = await http.post(
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
    final response = await http.put(
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
  final response = await http.delete(
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