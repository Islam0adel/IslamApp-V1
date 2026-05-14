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

  // ================= 2. قسم التكويد الجديد (المنطق المحدث) =================

  // جلب قائمة الأكواد لأي قسم (خزائن، موردين، عملاء، إلخ)
  Future<List<dynamic>> getCodingData(String companyCode, String category) async {
    final response = await http.get(Uri.parse('$baseUrl/coding/list/$companyCode/$category'));
    if (response.statusCode == 200) return jsonDecode(response.body);
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
    double? price,
    double? quantity,
    double? totalValue,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/coding/save'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'company_code': companyCode,
        'category': category,
        'code': code,
        'name': name,
        'barcode': barcode ?? "", // نبعت نص فارغ بدل null عشان البايثون ميزعلش
        'price': price ?? 0.0,    // نبعت 0 بدل null
        'quantity': quantity ?? 0.0,
        'total_value': totalValue ?? 0.0,
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
  // ================= 3. قسم العمليات المالية (Daily Transactions) =================

  // جلب آخر معلومات (سيريال ورصيد) لبدء حركة جديدة
  Future<Map<String, dynamic>> getLastTransactionInfo(String companyCode) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/last_info/$companyCode'),
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      return {'serial': 0, 'balance': 0.0};
    } catch (e) {
      return {'serial': 0, 'balance': 0.0};
    }
  }

  // جلب حركة معينة عن طريق السيريال (مهم جداً للتعديل والمعاينة)
  Future<Map<String, dynamic>?> getTransactionBySerial(String companyCode, int serial) async {
    final response = await http.get(
      Uri.parse('$baseUrl/transactions/get/$companyCode/$serial'),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    return null;
  }

  // حفظ حركة يومية جديدة (إيراد أو مصروف)
  Future<void> saveDailyTransaction(Map<String, dynamic> data) async {
    final response = await http.post(
      Uri.parse('$baseUrl/transactions/save'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    );
    if (response.statusCode != 200) {
      final error = jsonDecode(response.body);
      throw error['detail'] ?? 'فشل حفظ الحركة المالية';
    }
  }

  // جلب قائمة الحركات المالية (لصفحة المعاينة والبحث بين تاريخين)
  Future<List<dynamic>> getTransactionsList({
    required String companyCode,
    required String startDate,
    required String endDate,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl/transactions/list/$companyCode?start_date=$startDate&end_date=$endDate'),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw 'فشل جلب سجل الحركات';
  }

  // حذف حركة مالية نهائياً (مع الحفاظ على السيريال)
  Future<void> deleteDailyTransaction(String companyCode, int serial) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/transactions/delete/$companyCode/$serial'),
    );
    if (response.statusCode != 200) throw 'فشل حذف الحركة من السيرفر';
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