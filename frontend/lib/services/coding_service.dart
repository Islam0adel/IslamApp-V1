import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import '../models/coding_model.dart';
import '../core/constants.dart';

class CodingService {
  final String baseUrl = ApiConstants.baseUrl;
  final Box _codingBox = Hive.box('coding_box');

  // 1. جلب قائمة التكويد (بدون version_control)
  Future<List<CodingModel>> getCodingList({
    required String companyCode,
    required String category,
  }) async {
    final String localKey = "${companyCode}_$category";

    // نقرأ من Hive أولاً
    if (_codingBox.containsKey(localKey)) {
      final dynamic rawData = _codingBox.get(localKey);
      if (rawData is List) {
        return rawData.map((item) => CodingModel.fromMap(Map<String, dynamic>.from(item as Map))).toList();
      }
    }

    // إذا لم توجد محلياً، نجلب من السيرفر
    try {
      final response = await http.get(Uri.parse("$baseUrl/coding/list/$companyCode/$category"));
      if (response.statusCode == 200) {
        final List<dynamic> decodedData = json.decode(response.body);
        List<CodingModel> newList = decodedData.map((item) => CodingModel.fromMap(item)).toList();

        // حفظ في Hive
        await _codingBox.put(localKey, newList.map((item) => item.toMap()).toList());
        return newList;
      }
      return [];
    } catch (e) {
      // في حالة فشل الاتصال، نعيد قائمة فارغة
      return [];
    }
  }

  // 2. حفظ أو تحديث تكويد (مع دعم الكود الفارغ للإضافة)
  Future<Map<String, dynamic>> saveCode({
    required String companyCode,
    required String category,
    required CodingModel model,
  }) async {
    try {
      final Map<String, dynamic> bodyData = model.toMap();
      bodyData['company_code'] = companyCode;
      bodyData['category'] = category;

      // إذا كان الكود فارغاً، نعتبره إضافة جديدة
      // (سيرسل الباك إند كوداً جديداً)
      final response = await http.post(
        Uri.parse("$baseUrl/coding/save"),
        headers: {"Content-Type": "application/json"},
        body: json.encode(bodyData),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> result = json.decode(response.body);
        final String newCode = result['code'] ?? model.code;
        final String action = result['action'] ?? 'update';

        // تحديث Hive
        final String localKey = "${companyCode}_$category";
        List<Map<String, dynamic>> currentList = [];
        if (_codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);
          if (rawData is List) {
            currentList = rawData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
          }
        }

        // إذا كانت إضافة (action == 'insert')، نضيف العنصر الجديد
        // وإلا نعدل العنصر الموجود
        if (action == 'insert') {
          // نضيف الكود الجديد للبيانات
          bodyData['code'] = newCode;
          currentList.add(bodyData);
        } else {
          // تعديل: نبحث عن العنصر بالكود القديم ونستبدله
          final int index = currentList.indexWhere((item) => item['code'] == model.code);
          if (index != -1) {
            currentList[index] = bodyData;
          }
        }

        // ترتيب تصاعدي
        currentList.sort((a, b) {
          int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
          int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
          return aCode.compareTo(bCode);
        });

        await _codingBox.put(localKey, currentList);

        return {
          'success': true,
          'code': newCode,
          'action': action,
        };
      }
      return {'success': false, 'error': 'فشل الحفظ من السيرفر'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // 3. حذف التكويد
  Future<bool> deleteCode({
    required String companyCode,
    required String category,
    required String code,
  }) async {
    try {
      final response = await http.delete(
        Uri.parse("$baseUrl/coding/delete/$companyCode/$category/$code"),
      );

      if (response.statusCode == 200) {
        final String localKey = "${companyCode}_$category";
        if (_codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);
          if (rawData is List) {
            List<Map<String, dynamic>> currentList = rawData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
            currentList.removeWhere((element) => element['code'].toString() == code);
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