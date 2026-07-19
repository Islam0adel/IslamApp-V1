// lib/services/supplier_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import '../models/supplier_transaction_model.dart';
import '../core/constants.dart';
import 'daily_service.dart';

class SupplierService {
  final String baseUrl = ApiConstants.baseUrl;
  final Box _supplierBox = Hive.box('supplier_box');
  final DailyService _dailyService = DailyService();

  // حساب الرصيد التراكمي لمورد معين
  Future<double> getSupplierBalance(String companyCode, String branchCode, String supplierName) async {
    double balance = 0.0;
    for (var key in _supplierBox.keys) {
      final raw = _supplierBox.get(key);
      if (raw is List) {
        for (var item in raw) {
          if (item['company_code'] == companyCode &&
              item['branch_code'] == branchCode &&
              item['supplier_name'] == supplierName) {
            // صادر (دفعة) يزيد الرصيد، وارد (دخول بضاعة) يقلل الرصيد (حسب منطقك)
            // هنا نفترض أن الدفعات تزيد الرصيد (مطلوب من المورد)
            final type = item['type'] ?? '';
            final amount = (item['total_amount'] as num?)?.toDouble() ?? 0.0;
            if (type == 'صادر (دفعة)') {
              balance += amount;
            } else {
              balance -= amount;
            }
          }
        }
      }
    }
    return balance;
  }

  // حفظ حركة المورد
  Future<Map<String, dynamic>> saveSupplierTransaction(SupplierTransactionModel model) async {
    try {
      // حساب الإجماليات
      double total = 0.0;
      for (var item in model.items) {
        item.total = (item.quantity * item.price) - item.discountAmount;
        total += item.total;
      }
      model.totalAmount = total;

      // إضافة serial تلقائي
      if (model.serial == 0) {
        int maxSerial = 0;
        for (var key in _supplierBox.keys) {
          final raw = _supplierBox.get(key);
          if (raw is List) {
            for (var item in raw) {
              if (item['company_code'] == model.companyCode &&
                  item['branch_code'] == model.branchCode) {
                int s = int.tryParse(item['serial']?.toString() ?? '0') ?? 0;
                if (s > maxSerial) maxSerial = s;
              }
            }
          }
        }
        model.serial = maxSerial + 1;
      }

      // حفظ في Firestore
      final response = await http.post(
        Uri.parse('$baseUrl/supplier/save'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(model.toMap()),
      );
      if (response.statusCode != 200) {
        return {'success': false, 'error': 'فشل حفظ حركة المورد في السيرفر'};
      }
      final result = json.decode(response.body);
      final docId = result['doc_id'] ?? '';
      model.docId = docId;

      // حفظ في Hive (مع المفتاح المناسب)
      final String localKey = '${model.companyCode}_${model.branchCode}_${model.date}';
      List<Map<String, dynamic>> currentList = [];
      if (_supplierBox.containsKey(localKey)) {
        final raw = _supplierBox.get(localKey);
        if (raw is List) {
          currentList = raw.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      }
      currentList.removeWhere((e) => e['doc_id'] == docId);
      currentList.add(model.toMap());
      await _supplierBox.put(localKey, currentList);

      // ✅ منطق التحويل لليوميات (إذا كان الزر ON)
      if (model.isAddToStore) {
        await _createDailyTransaction(model);
      }

      return {'success': true, 'doc_id': docId};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // إنشاء إذن يومية تلقائي
  Future<void> _createDailyTransaction(SupplierTransactionModel model) async {
    try {
      // تحديد المبلغ: إذا كانت طريقة الدفع "أجل" أو "متنوع" → المدفوع فقط، وإلا → الإجمالي
      double amount;
      if (model.paymentMethod == 'أجل' || model.paymentMethod == 'متنوع') {
        amount = model.paidAmount;
      } else {
        amount = model.totalAmount;
      }
      if (amount <= 0) return;

      // تحديد النوع: نستخدم تصنيف "بضاعة"
      final type = model.paymentMethod == 'أجل' ? 'وارد' : 'صادر'; // حسب المنطق المطلوب
      final statement = 'دفع للمورد ${model.supplierName} (${model.date})';

      await _dailyService.saveTransaction(
        companyCode: model.companyCode,
        serial: 0,
        treasury: model.treasury,
        amount: amount,
        statement: statement,
        category: 'بضاعة',
        date: model.date,
        type: type,
        branchCode: model.branchCode,
        employee: model.employee,
      );
    } catch (e) {
      print('❌ فشل إنشاء اليومية التلقائية: $e');
    }
  }

  // جلب حركات الموردين
  Future<List<SupplierTransactionModel>> getSupplierTransactions({
    required String companyCode,
    String? branchCode,
    String? supplierName,
    String? startDate,
    String? endDate,
  }) async {
    try {
      final box = Hive.box('supplier_box');
      List<SupplierTransactionModel> all = [];
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is List) {
          for (var item in raw) {
            if (item['company_code'] == companyCode) {
              if (branchCode != null && item['branch_code'] != branchCode) continue;
              if (supplierName != null && item['supplier_name'] != supplierName) continue;
              if (startDate != null && item['date']?.compareTo(startDate) < 0) continue;
              if (endDate != null && item['date']?.compareTo(endDate) > 0) continue;
              all.add(SupplierTransactionModel.fromMap(item));
            }
          }
        }
      }
      all.sort((a, b) => b.date.compareTo(a.date));
      return all;
    } catch (e) {
      print('❌ خطأ في جلب حركات الموردين: $e');
      return [];
    }
  }

  // حذف حركة المورد
  Future<bool> deleteSupplierTransaction(String companyCode, String docId) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/supplier/delete/$companyCode/$docId'),
      );
      if (response.statusCode != 200) return false;

      // حذف من Hive
      final keys = _supplierBox.keys.toList();
      for (var key in keys) {
        final raw = _supplierBox.get(key);
        if (raw is List) {
          final updated = raw.where((e) => e['doc_id'] != docId).toList();
          if (updated.length != raw.length) {
            await _supplierBox.put(key, updated);
            break;
          }
        }
      }
      return true;
    } catch (e) {
      print('❌ خطأ في حذف حركة المورد: $e');
      return false;
    }
  }
}