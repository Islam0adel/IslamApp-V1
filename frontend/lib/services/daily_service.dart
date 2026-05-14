import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';

class DailyService {
  final String baseUrl = ApiConstants.baseUrl;

  // 1. جلب الأرصدة (نقدي وفيزا) من السيرفر
  Future<Map<String, dynamic>> getDailySummary(String companyCode) async {
    final response = await http.get(
      Uri.parse('$baseUrl/transactions/summary/$companyCode'),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw 'فشل جلب ملخص الأرصدة';
  }

  // 2. حفظ حركة جديدة
  // 2. حفظ حركة جديدة
  Future<void> saveTransaction({
    required String companyCode,
    required int serial,
    required String treasury,
    required double amount,
    required String statement,
    required String category,
    required String date,
    required String type, // cash or visa
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/transactions/save'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'company_code': companyCode,
        'serial': serial,
        'treasury': treasury,  // شيلنا _code عشان تطابق البايثون
        'amount': amount,
        'statement': statement,
        'category': category,  // شيلنا _name وخليناها category بس
        'date': date,
        'type': type,
      }),
    );

    if (response.statusCode != 200) {
      throw 'حدث خطأ أثناء الحفظ: ${response.body}';
    }
  }

  // 3. جلب آخر سيريال عشان الترقيم التلقائي
  Future<int> getLastSerial(String companyCode) async {
    final response = await http.get(
      Uri.parse('$baseUrl/transactions/last_serial/$companyCode'),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body)['last_serial'];
    }
    return 1000; // قيمة افتراضية لو مفيش بيانات
  }
}