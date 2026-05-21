import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

// ================= 2. قسم التكويد الجديد (المنطق المحدث والمتزامن لحظياً) =================

  // متغيرات ثابتة لحفظ الخزائن والتصنيفات مؤقتاً في الذاكرة لتوفير باقة الفايربيز
  static List<dynamic>? _cachedSafes;
  static List<dynamic>? _cachedTypes;

  // جلب قائمة الأكواد لأي قسم (مطور بدعم الكاش والنبضة اللحظية لضمان التحديث اللحظي لجميع المستخدمين)
  Future<List<dynamic>> getCodingData(String companyCode, String category) async {
    final prefs = await SharedPreferences.getInstance();
    final String cacheDataKey = 'cached_coding_${companyCode}_$category';
    final String cacheVersionKey = 'cached_coding_version_${companyCode}_$category';

    // 1. جلب رقم النسخة الحالي المنشور على السيرفر لهذا القسم (طلب خفيف جداً لمنع القراءات المكررة)
    int serverVersion = 0;
    try {
      final versionResponse = await http.get(Uri.parse('$baseUrl/coding/sync_version/$companyCode/$category'));
      if (versionResponse.statusCode == 200) {
        serverVersion = jsonDecode(versionResponse.body)['version'] ?? 0;
      }
    } catch (e) {
      print('فشل فحص نبضة التحديث، سيتم الاعتماد على الكاش المحلي كأمان: $e');
    }

    // قراءة رقم النسخة المحفوظ محلياً في الجهاز سابقاً
    int localVersion = prefs.getInt(cacheVersionKey) ?? -1;

    // 2. الفحص الذكي: لو النسخة مطابقة تماماً، نعتمد على الكاش السريع في الذاكرة أو القرص فوراً (وفرنا باقة الإنترنت)
    if (localVersion == serverVersion) {
      // أ. لو المطلوب خزائن وهي محفوظة مسبقاً في الذاكرة السريعة، رجعها فوراً
      if (category == "safes" && _cachedSafes != null) {
        return _cachedSafes!;
      }
      // ب. لو المطلوب تصنيفات وهي محفوظة مسبقاً في الذاكرة السريعة، رجعها فوراً
      if (category == "types" && _cachedTypes != null) {
        return _cachedTypes!;
      }

      // ج. لو البيانات مخزنة في قرص الجهاز/المتصفح من المرات السابقة
      if (prefs.containsKey(cacheDataKey)) {
        final cachedDataString = prefs.getString(cacheDataKey);
        if (cachedDataString != null && cachedDataString.isNotEmpty) {
          final localData = jsonDecode(cachedDataString) as List<dynamic>;
          
          // إعادة ملء الذاكرة المؤقتة السريعة لاستدعائها مجاناً
          if (category == "safes") _cachedSafes = localData;
          if (category == "types") _cachedTypes = localData;
          
          print('🎯 ذكاء التطبيق: البيانات مطابقة للسيرفر. تم العرض من الكاش المحلي بنجاح (صفر إنترنت).');
          return localData;
        }
      }
    } else {
      // 3. لو النسخة مختلفة (لأن مستخدم آخر قام بإضافة أو تعديل أو حذف)، نقوم بتصفير الكاش القديم فوراً لإجبار السيستم على التحديث
      print('🌐 نظام التزامن: تم كشف إضافة/تعديل/حذف من مستخدم آخر! جاري تصفير الكاش القديم وسحب البيانات الجديدة...');
      if (category == "safes") _cachedSafes = null;
      if (category == "types") _cachedTypes = null;
    }

    // 4. الذهاب للسيرفر لجلب القائمة النظيفة والحديثة (المسار المحدث مطابق للباك إند بالملي /coding/list)
    final response = await http.get(Uri.parse('$baseUrl/coding/list/$companyCode/$category'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as List<dynamic>;
      
      // حفظ البيانات المستلمة في الكاش السريع للرام (RAM)
      if (category == "safes") _cachedSafes = data;
      if (category == "types") _cachedTypes = data;
      
      try {
        // حفظ البيانات في التخزين الدائم للجهاز مع تثبيت رقم النسخة الجديد المزامر
        await prefs.setString(cacheDataKey, jsonEncode(data));
        await prefs.setInt(cacheVersionKey, serverVersion);
      } catch (_) {}
      
      return data;
    }
    
    // حماية ضد انقطاع الإنترنت: لو السيرفر لم يستجب والإنترنت مقطوع، نعرض الكاش المتوفر بدلاً من الكراش
    if (prefs.containsKey(cacheDataKey)) {
      final cachedDataString = prefs.getString(cacheDataKey);
      if (cachedDataString != null && cachedDataString.isNotEmpty) {
        return jsonDecode(cachedDataString) as List<dynamic>;
      }
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
  Future<void> saveNewCode({
    required String companyCode,
    required String category,
    required String code,
    required String name,
    String? barcode,
    double? wholesalePrice, 
    double? sellingPrice,   
    double? profitMargin,   
    double? profitPercent,  
    String? type,           
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
        'wholesale_price': wholesalePrice ?? 0.0, 
        'selling_price': sellingPrice ?? 0.0,     
        'profit_margin': profitMargin ?? 0.0,     
        'profit_percent': profitPercent ?? 0.0,   
        'type': type ?? "وارد",                   
      }),
    );

    if (response.statusCode != 200) {
      throw 'فشل حفظ الكود: ${response.body}';
    }
  }

  // حذف التكويد المزامر مع السيرفر
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