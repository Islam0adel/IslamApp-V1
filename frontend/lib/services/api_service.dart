import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../models/transaction_model.dart';

class ApiService {
  // استخدام الرابط الأساسي من ملف Constants
  // تأكد إنك في ملف constants.dart حاطط رابط الـ Hugging Face
  final String baseUrl = ApiConstants.baseUrl;

  // 1. دالة تسجيل الدخول (Login)
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/login'), // تم توحيد المتغير هنا
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
        }),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'فشل تسجيل الدخول');
      }
    } catch (e) {
      throw Exception('تعذر الاتصال بالسيرفر: $e');
    }
  }

  // 2. دالة جلب كل المعاملات (Daily Entries)
  Future<List<TransactionModel>> getTransactions() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        List data = jsonDecode(response.body);
        return data.map((item) => TransactionModel.fromJson(item)).toList();
      } else {
        throw Exception('فشل في جلب بيانات الدفتر');
      }
    } catch (e) {
      throw Exception('خطأ في جلب البيانات: $e');
    }
  }

  // 3. دالة إضافة معاملة جديدة
  Future<bool> addTransaction(TransactionModel transaction) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/transactions/add'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(transaction.toJson()),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'فشل حفظ المعاملة');
      }
    } catch (e) {
      throw Exception('خطأ أثناء الحفظ: $e');
    }
  }

  // 4. دالة إنشاء حساب جديد (Register)
  Future<Map<String, dynamic>> register(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/register'), // تم توحيد المتغير هنا
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
        }),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'فشل إنشاء الحساب');
      }
    } catch (e) {
      throw Exception('خطأ في التسجيل: $e');
    }
  }
}