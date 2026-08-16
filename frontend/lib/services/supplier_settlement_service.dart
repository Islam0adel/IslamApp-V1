import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/supplier_settlement_model.dart';

class SupplierSettlementService {
  final String baseUrl = ApiConstants.baseUrl;

  final Box _box =
      Hive.box('supplier_settlement_box');

  // ============================================================
  // رصيد التسويات لمورد
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

        if (map.isEmpty ||
            map['is_deleted'] == true) {
          continue;
        }

        if (map['company_code']?.toString() != companyCode ||
            map['branch_code']?.toString() != branchCode ||
            map['supplier_name']?.toString() != supplierName) {
          continue;
        }

        total += _toDouble(map['amount']);
      }
    }

    return total;
  }

  // ============================================================
  // السيريال التالي
  // ============================================================

  int _getNextSerial(
    String companyCode,
    String branchCode,
  ) {
    int maxSerial = 0;

    for (final key in _box.keys) {
      final raw = _box.get(key);

      if (raw is! List) continue;

      for (final item in raw) {
        final map = _toMap(item);

        if (map.isEmpty ||
            map['is_deleted'] == true) {
          continue;
        }

        if (map['company_code']?.toString() != companyCode ||
            map['branch_code']?.toString() != branchCode) {
          continue;
        }

        final serial = _toInt(map['serial']);

        if (serial > maxSerial) {
          maxSerial = serial;
        }
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
      if (model.serial == 0) {
        model.serial = _getNextSerial(
          model.companyCode,
          model.branchCode,
        );
      }

      final response = await http.post(
        Uri.parse('$baseUrl/supplier-settlement/save'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(model.toMap()),
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error':
              'HTTP ${response.statusCode}: ${response.body}',
        };
      }

      final result =
          jsonDecode(response.body)
              as Map<String, dynamic>;

      final docId =
          result['doc_id']?.toString() ?? '';

      if (docId.isEmpty) {
        return {
          'success': false,
          'error': 'السيرفر لم يرجع doc_id',
        };
      }

      model.docId = docId;

      await _saveLocal(model);

      return {
        'success': true,
        'doc_id': docId,
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
          .where(
            (e) =>
                e.isNotEmpty &&
                e['is_deleted'] != true,
          )
          .toList();
    }

    final item = model.toMap();

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
  // ============================================================

  Future<List<SupplierSettlementModel>>
      getSettlements({
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

        if (map.isEmpty ||
            map['is_deleted'] == true) {
          continue;
        }

        if (map['company_code']?.toString() != companyCode) {
          continue;
        }

        if (branchCode != null &&
            map['branch_code']?.toString() != branchCode) {
          continue;
        }

        if (supplierName != null &&
            map['supplier_name']?.toString() != supplierName) {
          continue;
        }

        final date =
            map['date']?.toString() ?? '';

        if (startDate != null &&
            date.compareTo(startDate) < 0) {
          continue;
        }

        if (endDate != null &&
            date.compareTo(endDate) > 0) {
          continue;
        }

        result.add(
          SupplierSettlementModel.fromMap(map),
        );
      }
    }

    result.sort(
      (a, b) => b.date.compareTo(a.date),
    );

    return result;
  }

  // ============================================================
  // حذف
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
        return false;
      }

      for (final key in _box.keys.toList()) {
        final raw = _box.get(key);

        if (raw is! List) continue;

        final updated = raw
            .whereType<Map>()
            .map(_toMap)
            .where(
              (e) =>
                  e['doc_id']?.toString() != docId &&
                  e['is_deleted'] != true,
            )
            .toList();

        final hadRecord =
            raw.any(
          (e) =>
              e is Map &&
              e['doc_id']?.toString() == docId,
        );

        if (!hadRecord) continue;

        if (updated.isEmpty) {
          await _box.delete(key);
        } else {
          await _box.put(key, updated);
        }

        break;
      }

      return true;
    } catch (e) {
      print('❌ خطأ حذف التسوية: $e');
      return false;
    }
  }

  // ============================================================
  // Full Sync
  // ============================================================

  Future<void> fetchAllSettlements(
    String companyCode,
  ) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/supplier-settlement/list/$companyCode',
      ),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'فشل تحميل التسويات: ${response.statusCode}',
      );
    }

    final List<dynamic> data =
        jsonDecode(response.body);

    for (final raw in data) {
      final map = _toMap(raw);

      if (map.isEmpty ||
          map['is_deleted'] == true) {
        continue;
      }

      final model =
          SupplierSettlementModel.fromMap(map);

      await _saveLocal(model);
    }

    print(
      '✅ تم FULL SYNC للتسويات (${data.length})',
    );
  }

  // ============================================================
  // Incremental Sync
  // ============================================================

  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs =
        await SharedPreferences.getInstance();

    final key =
        '${ApiConstants.LAST_SYNC_SETTLEMENT}$companyCode';

    final since =
        lastSync ??
        prefs.getString(key);

    if (since == null || since.isEmpty) {
      await fetchAllSettlements(companyCode);

      await prefs.setString(
        key,
        DateTime.now()
            .toUtc()
            .toIso8601String(),
      );

      return;
    }

    final started =
        DateTime.now().toUtc();

    final response = await http.get(
      Uri.parse(
        '$baseUrl/supplier-settlement/changes/'
        '$companyCode?since=$since',
      ),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'فشل مزامنة التسويات: ${response.statusCode}',
      );
    }

    final List<dynamic> changes =
        jsonDecode(response.body);

    for (final raw in changes) {
      final map = _toMap(raw);

      final docId =
          map['doc_id']?.toString();

      if (docId == null || docId.isEmpty) {
        continue;
      }

      final action =
          map['action']?.toString() ??
          (map['is_deleted'] == true
              ? 'delete'
              : 'update');

      final localKey =
          '${map['company_code']}_'
          '${map['branch_code']}_'
          '${map['date']}';

      List<Map<String, dynamic>> list = [];

      final localRaw = _box.get(localKey);

      if (localRaw is List) {
        list = localRaw
            .whereType<Map>()
            .map(_toMap)
            .where(
              (e) =>
                  e['is_deleted'] != true,
            )
            .toList();
      }

      list.removeWhere(
        (e) =>
            e['doc_id']?.toString() ==
            docId,
      );

      if (action == 'delete' ||
          map['is_deleted'] == true) {
        if (list.isEmpty) {
          await _box.delete(localKey);
        } else {
          await _box.put(localKey, list);
        }

        continue;
      }

      map.remove('action');
      map['is_deleted'] = false;

      list.add(map);

      await _box.put(
        localKey,
        list,
      );
    }

    await prefs.setString(
      key,
      started.toIso8601String(),
    );

    print(
      '✅ تمت مزامنة ${changes.length} تسوية',
    );
  }

  // ============================================================
  // Helpers
  // ============================================================

  Map<String, dynamic> _toMap(
    dynamic value,
  ) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }

    if (value is Map) {
      return Map<String, dynamic>.from(
        value.map(
          (key, value) =>
              MapEntry(key.toString(), value),
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