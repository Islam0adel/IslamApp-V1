import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';

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
      String? token = await userCredential.user?.getIdToken();
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
  Future<List<String>> getBranchesList(String companyCode) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/coding/list/$companyCode/branches'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 3)); // لو السيرفر واقع ميعلقش البرنامج أكتر من 3 ثواني

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
      return ["كل الفروع"]; // في حالة حدوث أي خطأ أو طوارئ يرجع الخيار الافتراضي فوراً
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