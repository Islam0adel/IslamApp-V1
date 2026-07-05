import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import '../models/coding_model.dart';
import '../core/constants.dart';

class CodingService {
  // تعريف رابط السيرفر الأساسي من ملف الثوابت
  final String baseUrl = ApiConstants.baseUrl;
  // تعريف صندوق الذاكرة المحلية الخاص بالتكويد
  final Box _codingBox = Hive.box('coding_box');

  // ==========================================
  // 1. جلب قائمة التكويد (من Hive أو السيرفر)
  // ==========================================
  Future<List<CodingModel>> getCodingList({
    required String companyCode,
    required String category,
  }) async {
    // إنشاء مفتاح فريد لكل قسم داخل الشركة في الـ Hive
    final String localKey = "${companyCode}_$category";

    // الخطوة الأولى: محاولة القراءة من الذاكرة المحلية Hive لسرعة الأداء
    if (_codingBox.containsKey(localKey)) {
      final dynamic rawData = _codingBox.get(localKey);
      // التأكد من أن البيانات عبارة عن قائمة
      if (rawData is List) {
        print("⚡ تم جلب بيانات [$category] من الذاكرة المحلية (Hive).");
        // تحويل آمن لتجنب خطأ LinkedMap
        return rawData
            .map((item) => CodingModel.fromMap(Map<String, dynamic>.from(item as Map)))
            .toList();
      }
    }

    // الخطوة الثانية: إذا لم توجد بيانات محلياً، نطلبها من السيرفر (API)
    print("⚠️ الذاكرة المحلية فارغة! جاري جلب بيانات [$category] من السيرفر...");
    try {
      final response = await http.get(Uri.parse("$baseUrl/coding/list/$companyCode/$category"));
      
      if (response.statusCode == 200) {
        // فك تشفير البيانات القادمة من السيرفر
        final List<dynamic> decodedData = json.decode(response.body);
        
        // تحويل البيانات الخام إلى قائمة من الكائنات (Models)
        List<CodingModel> newList = decodedData.map((item) => CodingModel.fromMap(item)).toList();

        // حفظ البيانات الجديدة في الـ Hive لاستخدامها في المرات القادمة
        await _codingBox.put(localKey, newList.map((item) => item.toMap()).toList());
        
        print("✅ تم جلب البيانات من السيرفر وحفظها في Hive بنجاح.");
        return newList;
      }
      
      // في حالة رد السيرفر بخطأ غير 200
      print("❌ خطأ من السيرفر: ${response.statusCode}");
      return [];
    } catch (e) {
      // في حالة فشل الاتصال بالإنترنت تماماً
      print("❌ فشل الاتصال بالسيرفر: $e");
      return [];
    }
  }

  // ==========================================
  // 2. حفظ أو تحديث تكويد
  // ==========================================
  Future<Map<String, dynamic>> saveCode({
    required String companyCode,
    required String category,
    required CodingModel model,
  }) async {
    try {
      // تجهيز البيانات للإرسال للسيرفر
      final Map<String, dynamic> bodyData = model.toMap();
      bodyData['company_code'] = companyCode;
      bodyData['category'] = category;

      // إرسال طلب الحفظ للسيرفر
      final response = await http.post(
        Uri.parse("$baseUrl/coding/save"),
        headers: {"Content-Type": "application/json"},
        body: json.encode(bodyData),
      );

      if (response.statusCode == 200) {
        // فك تشفير رد السيرفر لمعرفة النتيجة والكود الجديد
        final Map<String, dynamic> result = json.decode(response.body);
        final String newCode = result['code'] ?? model.code;
        final String action = result['action'] ?? 'update';

        // 🌟 تحديث الذاكرة المحلية (Hive) لتتطابق مع السيرفر 🌟
        final String localKey = "${companyCode}_$category";
        List<Map<String, dynamic>> currentList = [];
        
        // قراءة البيانات الحالية من Hive بطريقة آمنة
        if (_codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);
          if (rawData is List) {
            currentList = rawData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
          }
        }

        // تحديث البيانات المستلمة بالكود الجديد (مهم جداً في حالة الإضافة)
        bodyData['code'] = newCode;

        if (action == 'insert') {
          // إضافة العنصر الجديد للقائمة المحلية
          currentList.add(bodyData);
        } else {
          // البحث عن العنصر القديم وتحديثه
          final int index = currentList.indexWhere((item) => item['code'] == model.code);
          if (index != -1) {
            currentList[index] = bodyData;
          } else {
             // احتياطي: إذا لم يجده رغم أنه "تحديث"، نقوم بإضافته
             currentList.add(bodyData);
          }
        }

        // ترتيب القائمة تصاعدياً حسب الكود لضمان عرضها بشكل منظم
        currentList.sort((a, b) {
          int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
          int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
          return aCode.compareTo(bCode);
        });

        // حفظ القائمة المُحدثة في Hive
        await _codingBox.put(localKey, currentList);

        return {
          'success': true,
          'code': newCode,
          'action': action,
        };
      }
      
      return {'success': false, 'error': 'فشل الحفظ من السيرفر. كود الخطأ: ${response.statusCode}'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ==========================================
  // 3. حذف تكويد
  // ==========================================
  Future<bool> deleteCode({
    required String companyCode,
    required String category,
    required String code,
  }) async {
    try {
      // إرسال طلب الحذف للسيرفر
      final response = await http.delete(
        Uri.parse("$baseUrl/coding/delete/$companyCode/$category/$code"),
      );

      if (response.statusCode == 200) {
        // إذا نجح الحذف في السيرفر، نحذفه فوراً من الذاكرة المحلية (Hive)
        final String localKey = "${companyCode}_$category";
        
        if (_codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);
          
          if (rawData is List) {
            // 🌟 الحل الجذري: إنشاء قائمة جديدة وتفريغ البيانات يدوياً (التحويل الآمن)
            final List<Map<String, dynamic>> safeList = [];
            
            for (int i = 0; i < rawData.length; i++) {
              final dynamic item = rawData[i];
              if (item is Map) {
                final Map<String, dynamic> safeMap = {};
                // تحويل المفاتيح لنصوص لضمان عدم حدوث أخطاء النوع
                item.forEach((k, v) {
                  safeMap[k.toString()] = v;
                });
                safeList.add(safeMap);
              }
            }
                
            // حذف العنصر المطلوب من القائمة الآمنة
            // استخدمنا toString() لضمان تطابق النصوص بنسبة 100%
            safeList.removeWhere((element) => element['code'].toString() == code.toString());
            
            // حفظ القائمة الجديدة (بعد الحذف) في Hive
            await _codingBox.put(localKey, safeList);
            print("✅ الخدمة: تم حذف العنصر [$code] من الذاكرة المحلية بنجاح.");
          }
        }
        return true; // تمت العملية بنجاح
      }
      return false; // السيرفر رفض الحذف
    } catch (e) {
      print("❌ خطأ أثناء الحذف: $e");
      return false;
    }
  }
}