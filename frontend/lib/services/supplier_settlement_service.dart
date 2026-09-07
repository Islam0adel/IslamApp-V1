// lib/services/supplier_settlement_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/supplier_settlement_model.dart';

class SupplierSettlementService {
  final String baseUrl = ApiConstants.baseUrl;
  final Box _box = Hive.box('supplier_settlement_box');

  // ============================================================
  // هل الفرع = كل الفروع؟
  // ============================================================

  bool _isAllBranches(String? branchCode) =>
      branchCode == null ||
      branchCode.isEmpty ||
      branchCode == 'all' ||
      branchCode == 'الكل' ||
      branchCode == 'كل الفروع';

  // ============================================================
  // رصيد التسويات لمورد
  //
  // لو الفرع = all يتم حساب كل الفروع.
  // ============================================================

  Future<double> getSupplierSettlementTotal(
    String companyCode,
    String branchCode,
    String supplierName,
  ) async {
    double total = 0.0;

    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw is! List) continue;

      for (final item in raw) {
        final map = _toMap(item);

        if (map.isEmpty || map['is_deleted'] == true) continue;
        if (map['company_code']?.toString() != companyCode) continue;

        if (!_isAllBranches(branchCode) &&
            map['branch_code']?.toString() != branchCode) {
          continue;
        }

        if (map['supplier_name']?.toString() != supplierName) {
          continue;
        }

        total += _toDouble(map['amount']);
      }
    }

    return total;
  }

  // ============================================================
  // السيريال التالي
  //
  // يتم الترقيم لكل شركة + فرع.
  // ============================================================

  // lib/services/supplier_settlement_service.dart

int _getNextSerial(String companyCode, String branchCode) {
  int maxSerial = 0;

  for (final key in _box.keys) {
    final raw = _box.get(key);
    if (raw is! List) continue;

    for (final item in raw) {
      final map = _toMap(item);
      if (map.isEmpty) continue; // تشمل السجلات المحذوفة

      if (map['company_code']?.toString() != companyCode ||
          map['branch_code']?.toString() != branchCode) {
        continue;
      }

      final serial = _toInt(map['serial']);
      if (serial > maxSerial) maxSerial = serial;
    }
  }

  return maxSerial + 1;
}

  // ============================================================
  // حفظ تسوية
  // ============================================================

  Future<Map<String, dynamic>> saveSettlement(
    SupplierSettlementModel model,
  ) async {
    try {
      // --------------------------------------------------------
      // التأكد من رقم الإذن
      // --------------------------------------------------------

      if (model.serial <= 0) {
        model.serial = _getNextSerial(
          model.companyCode,
          model.branchCode,
        );
      }

      // --------------------------------------------------------
      // تحديث وقت التعديل
      // --------------------------------------------------------

      model.updatedAt = DateTime.now();

      // --------------------------------------------------------
      // إرسال للسيرفر
      // --------------------------------------------------------

      final response = await http.post(
        Uri.parse('$baseUrl/supplier-settlement/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(model.toMap()),
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error':
              'HTTP ${response.statusCode}: ${response.body}',
        };
      }

      final result = jsonDecode(response.body)
          as Map<String, dynamic>;

      final docId = result['doc_id']?.toString() ?? '';

      if (docId.isEmpty) {
        return {
          'success': false,
          'error': 'السيرفر لم يرجع doc_id',
        };
      }

      // --------------------------------------------------------
      // حفظ doc_id
      // --------------------------------------------------------

      model.docId = docId;

      // لو السيرفر رجع serial نستخدمه
      if (result['serial'] is num) {
        model.serial = (result['serial'] as num).toInt();
      }

      // --------------------------------------------------------
      // حفظ محلي
      // --------------------------------------------------------

      await _saveLocal(model);

      return {
        'success': true,
        'doc_id': model.docId,
        'serial': model.serial,
        'action':
            result['action']?.toString() ?? 'insert',
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  // ============================================================
  // حفظ محلي
  // ============================================================

  Future<void> _saveLocal(
    SupplierSettlementModel model,
  ) async {
    final key =
        '${model.companyCode}_${model.branchCode}_${model.date}';

    List<Map<String, dynamic>> list = [];

    final raw = _box.get(key);

    if (raw is List) {
      list = raw
          .whereType<Map>()
          .map(_toMap)
          .where((e) => e.isNotEmpty && e['is_deleted'] != true)
          .toList();
    }

    final item = _toMap(model.toMap());

    item['doc_id'] = model.docId;
    item['serial'] = model.serial;
    item['employee'] = model.employee;
    item['is_deleted'] = false;

    list.removeWhere(
      (e) =>
          e['doc_id']?.toString() ==
          model.docId?.toString(),
    );

    list.add(item);

    await _box.put(key, list);
  }

  // ============================================================
  // جلب التسويات
  //
  // all = كل الفروع
  // ============================================================

  Future<List<SupplierSettlementModel>> getSettlements({
    required String companyCode,
    String? branchCode,
    String? supplierName,
    String? startDate,
    String? endDate,
  }) async {
    final List<SupplierSettlementModel> result = [];

    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw is! List) continue;

      for (final item in raw) {
        final map = _toMap(item);

        if (map.isEmpty || map['is_deleted'] == true) continue;
        if (map['company_code']?.toString() != companyCode) continue;

        if (!_isAllBranches(branchCode) &&
            map['branch_code']?.toString() != branchCode) {
          continue;
        }

        if (supplierName != null &&
            supplierName.isNotEmpty &&
            map['supplier_name']?.toString() != supplierName) {
          continue;
        }

        final date = map['date']?.toString() ?? '';

        if (startDate != null &&
            date.compareTo(startDate) < 0) {
          continue;
        }

        if (endDate != null &&
            date.compareTo(endDate) > 0) {
          continue;
        }

        try {
          result.add(
            SupplierSettlementModel.fromMap(map),
          );
        } catch (e) {
          print(
            '⚠️ خطأ في تحويل التسوية: $e',
          );
        }
      }
    }

    result.sort((a, b) {
      final dateCompare = b.date.compareTo(a.date);

      if (dateCompare != 0) return dateCompare;

      return b.serial.compareTo(a.serial);
    });

    return result;
  }

  // ============================================================
  // حذف تسوية
  // ============================================================

  Future<bool> deleteSettlement(
    String companyCode,
    String docId,
  ) async {
    try {
      final response = await http.delete(
        Uri.parse(
          '$baseUrl/supplier-settlement/delete/'
          '$companyCode/$docId',
        ),
      );

      if (response.statusCode != 200) {
        print(
          '❌ فشل حذف التسوية: ${response.statusCode}',
        );
        return false;
      }

      final keys = _box.keys.toList();

      for (final key in keys) {
        final raw = _box.get(key);
        if (raw is! List) continue;

        final List<Map<String, dynamic>> updated = [];
        bool found = false;

        for (final item in raw) {
          final map = _toMap(item);

          if (map.isEmpty) continue;

          if (map['doc_id']?.toString() == docId.toString()) {
            found = true;
            continue;
          }

          if (map['is_deleted'] == true) {
            continue;
          }

          updated.add(map);
        }

        if (!found) continue;

        if (updated.isEmpty) {
          await _box.delete(key);
        } else {
          await _box.put(key, updated);
        }

        break;
      }

      return true;
    } catch (e) {
      print(
        '❌ خطأ حذف التسوية: $e',
      );
      return false;
    }
  }

  // ============================================================
  // Full Sync
  // ============================================================

  Future<void> fetchAllSettlements(
    String companyCode,
  ) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/supplier-settlement/list/$companyCode',
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'فشل تحميل التسويات: '
          '${response.statusCode}: '
          '${response.body}',
        );
      }

      final List<dynamic> data =
          jsonDecode(response.body);

      // --------------------------------------------------------
      // نضع فقط السجلات النشطة.
      // --------------------------------------------------------

      for (final raw in data) {
        final map = _toMap(raw);

        if (map.isEmpty || map['is_deleted'] == true) {
          continue;
        }

        map['is_deleted'] = false;

        final model =
            SupplierSettlementModel.fromMap(map);

        await _saveLocal(model);
      }

      print(
        '✅ تم FULL SYNC للتسويات '
        '(${data.length} سجل)',
      );
    } catch (e) {
      print(
        '❌ فشل FULL SYNC للتسويات: $e',
      );
      rethrow;
    }
  }

  // ============================================================
  // Incremental Sync
  // ============================================================

  // lib/services/supplier_settlement_service.dart

Future<void> syncChangesFromServer(
  String companyCode, [
  String? lastSync,
]) async {
  final prefs = await SharedPreferences.getInstance();
  final String lastSyncKey =
      '${ApiConstants.LAST_SYNC_SETTLEMENT}$companyCode';
  final String? savedLastSync = lastSync ?? prefs.getString(lastSyncKey);

  // ==========================================================
  // جهاز جديد → Full Sync
  // ==========================================================

  if (savedLastSync == null || savedLastSync.isEmpty) {
    print('📥 التسويات: لا يوجد lastSync → FULL SYNC');
    await fetchAllSettlements(companyCode);
    await prefs.setString(
      lastSyncKey,
      DateTime.now().toUtc().toIso8601String(),
    );
    return;
  }

  try {
    final DateTime syncStartedAt = DateTime.now().toUtc();
    DateTime since = DateTime.parse(savedLastSync).toUtc();
    since = since.subtract(const Duration(minutes: 1));

    final response = await http.get(
      Uri.parse(
        '$baseUrl/supplier-settlement/changes/$companyCode'
        '?since=${since.toIso8601String()}',
      ),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'فشل مزامنة التسويات: ${response.statusCode}: ${response.body}',
      );
    }

    final List<dynamic> changes = jsonDecode(response.body);

    for (final raw in changes) {
      final map = _toMap(raw);
      if (map.isEmpty) continue;

      final docId = map['doc_id']?.toString();
      if (docId == null || docId.isEmpty) {
        print('⚠️ تحديث تسوية بدون doc_id');
        continue;
      }

      final action = map['action']?.toString() ??
          (map['is_deleted'] == true ? 'delete' : 'update');

      // ========================================================
      // 1. حذف doc_id من جميع المفاتيح
      // ========================================================

      final keys = _box.keys.toList();

      for (final oldKey in keys) {
        final rawList = _box.get(oldKey);
        if (rawList is! List) continue;

        final List<Map<String, dynamic>> updatedList = [];
        bool found = false;

        for (final item in rawList) {
          final itemMap = _toMap(item);
          if (itemMap.isEmpty) continue;

          if (itemMap['doc_id']?.toString() == docId) {
            found = true;
            continue;
          }

          if (itemMap['is_deleted'] == true) continue;

          updatedList.add(itemMap);
        }

        if (!found) continue;

        if (updatedList.isEmpty) {
          await _box.delete(oldKey);
        } else {
          await _box.put(oldKey, updatedList);
        }
      }

      // ========================================================
      // 2. لو حذف → خلاص
      // ========================================================

      if (action == 'delete' || map['is_deleted'] == true) {
        print('🗑️ تم حذف التسوية [$docId] من Hive (Incremental Sync)');
        continue;
      }

      // ========================================================
      // 3. إضافة أو تحديث في المفتاح الجديد
      // ========================================================

      final company = map['company_code']?.toString() ?? companyCode;
      final branch = map['branch_code']?.toString() ?? 'all';
      final date = map['date']?.toString() ?? '';

      if (company.isEmpty || branch.isEmpty || date.isEmpty) {
        print('⚠️ بيانات المفتاح ناقصة للتسوية [$docId]');
        continue;
      }

      final newKey = '${company}_${branch}_$date';

      List<Map<String, dynamic>> list = [];

      final rawList = _box.get(newKey);
      if (rawList is List) {
        list = rawList
            .whereType<Map>()
            .map(_toMap)
            .where(
              (e) => e.isNotEmpty && e['is_deleted'] != true,
            )
            .toList();
      }

      // منع التكرار
      list.removeWhere(
        (item) => item['doc_id']?.toString() == docId,
      );

      map.remove('action');
      map['is_deleted'] = false;

      list.add(map);

      await _box.put(newKey, list);

      print('✅ تم تحديث التسوية [$docId] في المفتاح [$newKey]');
    }

    // ========================================================
    // تحديث lastSync فقط بعد نجاح الكل
    // ========================================================

    await prefs.setString(
      lastSyncKey,
      syncStartedAt.toIso8601String(),
    );

    print(
      '✅ تمت مزامنة ${changes.length} تحديث للتسويات (Incremental Sync)',
    );
  } catch (e) {
    print('❌ فشل مزامنة التسويات: $e');
    rethrow;
  }
}

  // ============================================================
  // Helpers
  // ============================================================

  Map<String, dynamic> _toMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }

    if (value is Map) {
      return Map<String, dynamic>.from(
        value.map(
          (key, value) =>
              MapEntry(
                key.toString(),
                value,
              ),
        ),
      );
    }

    return {};
  }

  double _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(
          value?.toString() ?? '',
        ) ??
        0.0;
  }

  int _toInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
  }
}