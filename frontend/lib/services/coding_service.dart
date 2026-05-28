import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import '../models/coding_model.dart';
import '../core/constants.dart';

class CodingService {
  final String baseUrl = ApiConstants.baseUrl;
  
  // الوصول إلى صندوق Hive الأساسي للتكويدات
  final Box _codingBox = Hive.box('coding_box');

  // 1. جلب قائمة التكويد مع معالجة النوع بشكل صارم والتوافق التام مع الباك إند
  // جلب البيانات ذكياً فقط في حالة حدوث تغيير في السيرفر
  Future<List<CodingModel>> getCodingList({
    required String companyCode,
    required String category,
  }) async {
    final String localKey = "${companyCode}_$category";
    final String versionKey = "${localKey}_version";

    try {
      // 1. نسأل السيرفر عن رقم النسخة الحالية لهذا القسم
      final versionResponse = await http.get(Uri.parse("$baseUrl/coding/version/$companyCode/$category"));
      
      if (versionResponse.statusCode == 200) {
        final Map<String, dynamic> versionData = json.decode(versionResponse.body);
        int serverVersion = versionData['version'] ?? 0;

        // 2. نقرأ رقم النسخة المحفوظ محلياً في الـ Hive
        int localVersion = _codingBox.get(versionKey, defaultValue: -1);

        // 🟢 لو مفيش تغيير ورقم النسخة متطابق، افتح الكاش فوراً ووفر الإنترنت والقراءات!
        if (serverVersion == localVersion && _codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);
          if (rawData is List) {
            return rawData.map((item) => CodingModel.fromMap(Map<String, dynamic>.from(item as Map))).toList();
          }
        }

        // 🔵 لو حصل تغيير (النسخ غير متطابقة)، يسحب البيانات الجديدة من الفايربيز
        final dataResponse = await http.get(Uri.parse("$baseUrl/coding/list/$companyCode/$category"));
        if (dataResponse.statusCode == 200) {
          final List<dynamic> decodedData = json.decode(dataResponse.body);
          List<CodingModel> newList = decodedData.map((item) => CodingModel.fromMap(item)).toList();

          // حفظ البيانات الجديدة ورقم النسخة الجديد في الـ Hive
          await _codingBox.put(localKey, newList.map((item) => item.toMap()).toList());
          await _codingBox.put(versionKey, serverVersion); // تحديث النسخة المحلية

          return newList;
        }
      }
      throw Exception("فشل الاتصال");
    } catch (e) {
      // حائط الصد: لو الشبكة قطعت تماماً، يفتح الكاش الاحتياطي تلقائياً دون إيرور
      if (_codingBox.containsKey(localKey)) {
        final dynamic rawData = _codingBox.get(localKey);
        if (rawData is List) {
          return rawData.map((item) => CodingModel.fromMap(Map<String, dynamic>.from(item as Map))).toList();
        }
      }
      return [];
    }
  }

  // 2. حفظ أو تحديث تكويد جديد بالتزامن محلياً وعلى السيرفر
  Future<bool> saveCode({
    required String companyCode,
    required String category,
    required CodingModel model,
  }) async {
    try {
      final Map<String, dynamic> bodyData = model.toMap();
      bodyData['company_code'] = companyCode;
      bodyData['category'] = category;

      // 🔥 تم التعديل: إضافة البادئة /coding لتوجيه الطلب للـ Router الصحيح بـ FastAPI
      final response = await http.post(
        Uri.parse("$baseUrl/coding/save"),
        headers: {"Content-Type": "application/json"},
        body: json.encode(bodyData),
      );

      if (response.statusCode == 200) {
        final String localKey = "${companyCode}_$category";
        final dynamic rawData = _codingBox.get(localKey, defaultValue: []);
        
        List<Map<String, dynamic>> currentList = [];
        if (rawData is List) {
          currentList = rawData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
        }

        int index = currentList.indexWhere((element) => element['code'].toString() == model.code.toString());
        if (index != -1) {
          currentList[index] = model.toMap();
        } else {
          currentList.add(model.toMap());
        }

        // ترتيب الأكواد تصاعدياً لعدم لخبطة الأرقام السيريال في الواجهة
        currentList.sort((a, b) => int.parse(a['code'].toString()).compareTo(int.parse(b['code'].toString())));
        await _codingBox.put(localKey, currentList);

        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // 3. حذف التكويد محلياً ومن السيرفر
  Future<bool> deleteCode({
    required String companyCode,
    required String category,
    required String code,
  }) async {
    try {
      // 🔥 تم التعديل: إضافة البادئة /coding ليتطابق الـ URL بالكامل مع دالة الحذف بالباك إند
      final response = await http.delete(Uri.parse("$baseUrl/coding/delete/$companyCode/$category/$code"));

      if (response.statusCode == 200) {
        final String localKey = "${companyCode}_$category";
        if (_codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);
          if (rawData is List) {
            List<Map<String, dynamic>> currentList = rawData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
            currentList.removeWhere((element) => element['code'].toString() == code.toString());
            await _codingBox.put(localKey, currentList);
          }
        }
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }
}