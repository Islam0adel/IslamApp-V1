import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';

class DailyService {
  final String baseUrl = ApiConstants.baseUrl;

  // 1. جلب الأرصدة (نقدي وفيزا) من السيرفر
  Future<Map<String, dynamic>> getDailySummary(String companyCode) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/summary/$companyCode'),
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      throw 'فشل جلب ملخص الأرصدة';
    } catch (e) {
      throw 'خطأ في الاتصال بالسيرفر: $e';
    }
  }

  // 2. حفظ حركة جديدة (أو تحديث إذن موجود)
  Future<void> saveTransaction({
    required String companyCode,
    required int serial,
    required String treasury,
    required double amount,
    required String statement,
    required String category,
    required String date,
    required String type, // cash or visa
    String? employee, // حقل الموظف للتقارير
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/transactions/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'company_code': companyCode,
          'serial': serial,
          'treasury': treasury,
          'amount': amount,
          'statement': statement,
          'category': category,
          'date': date,
          'type': type,
          'employee': employee ?? "غير محدد",
        }),
      );

      if (response.statusCode != 200) {
        throw 'حدث خطأ أثناء الحفظ: ${response.body}';
      }
    } catch (e) {
      throw 'فشل عملية الحفظ: $e';
    }
  }

  // 3. جلب آخر سيريال عشان الترقيم التلقائي
  Future<int> getLastSerial(String companyCode) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/last_serial/$companyCode'),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body)['last_serial'] ?? 0;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  // 4. [جديد] جلب سجل الحركات للمعاينة بين تاريخين
  Future<List<dynamic>> getTransactionsHistory(
    String companyCode, 
    String startDate, 
    String endDate
  ) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/list/$companyCode?start_date=$startDate&end_date=$endDate'),
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as List<dynamic>;
      } else {
        throw 'خطأ من السيرفر: ${response.statusCode}';
      }
    } catch (e) {
      throw 'فشل جلب سجل الحركات: $e';
    }
  }

  // 5. [جديد] حذف حركة مالية نهائياً
  Future<void> deleteTransaction(String companyCode, int serial) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/transactions/delete/$companyCode/$serial'),
      );
      
      if (response.statusCode != 200) {
        throw 'فشل حذف الحركة من السيرفر';
      }
    } catch (e) {
      throw 'خطأ أثناء الحذف: $e';
    }
  }
}