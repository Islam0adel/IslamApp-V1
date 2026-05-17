import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';

class DailyService {
  final String baseUrl = ApiConstants.baseUrl;

  // 1. جلب الأرصدة (نقدي وفيزا) مضافاً إليها الفرع النشط
  Future<Map<String, dynamic>> getDailySummary(String companyCode, String? treasury, String branch) async {
    try {
      String url = '$baseUrl/transactions/summary/$companyCode?branch=${Uri.encodeComponent(branch)}';
      if (treasury != null && treasury.isNotEmpty) {
        url += '&treasury=${Uri.encodeComponent(treasury)}';
      }
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) return jsonDecode(response.body);
      throw 'فشل جلب ملخص الأرصدة';
    } catch (e) {
      throw 'خطأ في الاتصال بالسيرفر: $e';
    }
  }

  // 2. حفظ حركة جديدة شاملة الفرع واسم الموظف المستخدم الفعلي
  Future<void> saveTransaction({
    required String companyCode,
    required int serial,
    required String treasury,
    required double amount,
    required String statement,
    required String category,
    required String date,
    required String type,
    String? employee,
    required String branch, // حقل الفرع الجديد
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
          'branch': branch, // إرسال الفرع للباك إند
        }),
      );

      if (response.statusCode != 200) {
        throw 'حدث خطأ أثناء الحفظ: ${response.body}';
      }
    } catch (e) {
      throw 'فشل عملية الحفظ: $e';
    }
  }

  // 3. جلب آخر سيريال
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

  // 4. جلب سجل الحركات
  Future<List<dynamic>> getTransactionsHistory(String companyCode, String startDate, String endDate) async {
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

  // 5. حذف حركة مالية نهائياً
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