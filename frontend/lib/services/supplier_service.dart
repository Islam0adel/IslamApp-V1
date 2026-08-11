// lib/services/supplier_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/supplier_transaction_model.dart';
import '../core/constants.dart';

class SupplierService {
  final String baseUrl = ApiConstants.baseUrl;
  final Box _supplierBox = Hive.box('supplier_box');

  // حساب الرصيد التراكمي لمورد معين (يُرجع القيمة المطلقة)
  Future<double> getSupplierBalance(String companyCode, String branchCode, String supplierName) async {
    double balance = 0.0;
    for (var key in _supplierBox.keys) {
      final raw = _supplierBox.get(key);
      if (raw is List) {
        for (var item in raw) {
          if (item['company_code'] == companyCode &&
              item['branch_code'] == branchCode &&
              item['supplier_name'] == supplierName) {
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
    return balance.abs();
  }

  // حفظ حركة المورد (بدون إنشاء جرد تلقائي)
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

      // حفظ في السيرفر
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

      // حفظ في Hive (بدون أي إجراء إضافي)
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

      return {'success': true, 'doc_id': docId};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // جلب حركات الموردين (مع فلاتر اختيارية)
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
          // ✅ تحويل آمن إلى Map<String, dynamic>
          final Map<String, dynamic> map = _toMapString(item);
          if (map['company_code'] == companyCode) {
            if (branchCode != null && map['branch_code'] != branchCode) continue;
            if (supplierName != null && map['supplier_name'] != supplierName) continue;
            if (startDate != null && (map['date']?.toString() ?? '').compareTo(startDate) < 0) continue;
            if (endDate != null && (map['date']?.toString() ?? '').compareTo(endDate) > 0) continue;
            all.add(SupplierTransactionModel.fromMap(map));
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

  // جلب جميع حركات الموردين من السيرفر وتخزينها في Hive
  Future<void> fetchAllSupplier(String companyCode) async {
  try {
    final response = await http.get(
      Uri.parse('$baseUrl/supplier/list/$companyCode'),
    );
    if (response.statusCode == 200) {
      List<dynamic> data = jsonDecode(response.body);
      for (var item in data) {
        final Map<String, dynamic> map = _toMapString(item);
        String key = "${map['company_code']}_${map['branch_code']}_${map['date']}";
        List<Map<String, dynamic>> currentList = [];
        if (_supplierBox.containsKey(key)) {
          final raw = _supplierBox.get(key);
          if (raw is List) {
            currentList = raw.map((e) => _toMapString(e)).toList();
          }
        }
        currentList.removeWhere((e) => e['doc_id'] == map['doc_id']);
        currentList.add(map);
        await _supplierBox.put(key, currentList);
      }
      print("✅ تم جلب ${data.length} حركة مورد من السيرفر وتخزينها محلياً");
    } else {
      throw 'فشل جلب حركات الموردين من السيرفر';
    }
  } catch (e) {
    print("❌ فشل جلب الموردين: $e");
    rethrow;
  }
}

Map<String, dynamic> _toMapString(dynamic obj) {
  if (obj is Map<String, dynamic>) return obj;
  if (obj is Map) {
    return Map<String, dynamic>.from(obj.map((key, value) => MapEntry(key.toString(), value)));
  }
  return {};
}

  // ✅ المزامنة التزايدية للموردين (تجلب فقط التغييرات منذ آخر مزامنة)
  // ✅ المزامنة التزايدية للموردين
Future<void> syncChangesFromServer(String companyCode, [String? lastSync]) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncKey = '${ApiConstants.LAST_SYNC_SUPPLIER}$companyCode';
    
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    if (lastSyncValue == null) {
      await fetchAllSupplier(companyCode);
      await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
      return;
    }

    final response = await http.get(
      Uri.parse('$baseUrl/supplier/changes/$companyCode?since=$lastSyncValue'),
    );
    if (response.statusCode == 200) {
      List<dynamic> changes = jsonDecode(response.body);
      for (var item in changes) {
        final Map<String, dynamic> map = _toMapString(item);
        String key = "${map['company_code']}_${map['branch_code']}_${map['date']}";
        List<Map<String, dynamic>> list = [];
        if (_supplierBox.containsKey(key)) {
          final raw = _supplierBox.get(key);
          if (raw is List) {
            list = raw.map((e) => _toMapString(e)).toList();
          }
        }
        list.removeWhere((e) => e['doc_id'] == map['doc_id']);
        list.add(map);
        await _supplierBox.put(key, list);
      }
      await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
      print("✅ تم مزامنة ${changes.length} تحديث للموردين");
    } else {
      print("⚠️ فشل المزامنة التزايدية للموردين، كود: ${response.statusCode}");
    }
  } catch (e) {
    print("❌ خطأ في المزامنة التزايدية للموردين: $e");
  }
}
}