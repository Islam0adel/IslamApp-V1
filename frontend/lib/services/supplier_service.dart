// lib/services/supplier_service.dart

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
// import 'supplier_settlement_service.dart';
import '../models/supplier_transaction_model.dart';
import '../core/constants.dart';

class SupplierService {
  final String baseUrl = ApiConstants.baseUrl;

  final Box _supplierBox =
      Hive.box('supplier_box');

  final Box _codingBox =
      Hive.box('coding_box');

  final Box _settlementBox =
    Hive.box('supplier_settlement_box');

  // ============================================================
  // 1. رصيد المورد
  //
  // المشتريات تزيد المديونية.
  // التسويات سيتم خصمها لاحقاً من settlement_box.
  // ============================================================

  Future<double> getSupplierBalance(
  String companyCode,
  String branchCode,
  String supplierName,
) async {
  double balance = 0.0;

  // ============================================================
  // 1) المشتريات = تزيد رصيد المورد
  // ============================================================

  for (final key in _supplierBox.keys) {
    final raw = _supplierBox.get(key);

    if (raw is! List) continue;

    for (final item in raw) {
      final map = _toMapString(item);

      if (map.isEmpty || map['is_deleted'] == true) {
        continue;
      }

      if (map['company_code']?.toString() != companyCode ||
          map['branch_code']?.toString() != branchCode ||
          map['supplier_name']?.toString() != supplierName) {
        continue;
      }

      balance += _toDouble(map['total_amount']);
    }
  }

  // ============================================================
  // 2) الدفعات = تخصم من رصيد المورد
  // ============================================================

  for (final key in _settlementBox.keys) {
    final raw = _settlementBox.get(key);

    if (raw is! List) continue;

    for (final item in raw) {
      final map = _toMapString(item);

      if (map.isEmpty || map['is_deleted'] == true) {
        continue;
      }

      if (map['company_code']?.toString() != companyCode ||
          map['branch_code']?.toString() != branchCode ||
          map['supplier_name']?.toString() != supplierName) {
        continue;
      }

      balance -= _toDouble(map['amount']);
    }
  }

  // منع ظهور رصيد سالب
  if (balance < 0) {
    return 0.0;
  }

  return balance;
}

  // ============================================================
  // 2. حفظ فاتورة مشتريات
  // ============================================================

  Future<Map<String, dynamic>>
      saveSupplierTransaction(
    SupplierTransactionModel model,
  ) async {
    try {
      // --------------------------------------------------------
      // تنظيف وحساب إجمالي الأصناف
      // --------------------------------------------------------

      double itemsTotal = 0.0;

      for (final item in model.items) {
        item.discountRate = 0.0;
        item.discountAmount = 0.0;

        item.total =
            item.quantity * item.price;

        itemsTotal += item.total;
      }

      // مهم:
      // لا نعيد تعيين totalAmount هنا.
      //
      // الصفحة تكون قد حسبت:
      // إجمالي الأصناف - خصم الفاتورة
      //
      // لأن الموديل حالياً لا يحتوي على
      // invoiceDiscount مستقل.
      if (model.totalAmount <= 0) {
        model.totalAmount = itemsTotal;
      }

      // --------------------------------------------------------
      // Serial تلقائي
      // --------------------------------------------------------

      if (model.serial == 0) {
        model.serial =
            _getNextSerial(
          model.companyCode,
          model.branchCode,
        );
      }

      // --------------------------------------------------------
      // فاتورة المشتريات ليست دفعة
      // --------------------------------------------------------

      model.paidAmount = 0.0;

      // --------------------------------------------------------
      // حفظ على السيرفر
      // --------------------------------------------------------

      final response = await http.post(
        Uri.parse(
          '$baseUrl/supplier/save',
        ),
        headers: {
          'Content-Type':
              'application/json',
        },
        body: jsonEncode(
          model.toMap(),
        ),
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error':
              'فشل حفظ الفاتورة في السيرفر '
              'HTTP ${response.statusCode}: '
              '${response.body}',
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
          'error':
              'السيرفر لم يرجع doc_id',
        };
      }

      model.docId = docId;

      // --------------------------------------------------------
      // حفظ الفاتورة محلياً
      // --------------------------------------------------------

      await _saveLocalTransaction(model);

      // --------------------------------------------------------
      // تحديث التكويد إذا كان الزر ON
      // --------------------------------------------------------

      if (model.isAddToCoding) {
        await _updateCodingFromPurchase(
          companyCode:
              model.companyCode,
          items:
              model.items,
        );
      }

      return {
        'success': true,
        'doc_id': docId,
        'serial': model.serial,
        'action':
            result['action']?.toString() ??
            'update',
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  // ============================================================
  // 3. حفظ الفاتورة محلياً
  // ============================================================

  Future<void> _saveLocalTransaction(
    SupplierTransactionModel model,
  ) async {
    final key =
        '${model.companyCode}_'
        '${model.branchCode}_'
        '${model.date}';

    List<Map<String, dynamic>> list = [];

    final raw =
        _supplierBox.get(key);

    if (raw is List) {
      list = raw
          .whereType<Map>()
          .map(_toMapString)
          .where(
            (e) =>
                e.isNotEmpty &&
                e['is_deleted'] != true,
          )
          .toList();
    }

    final localItem =
        _toMapString(
      model.toMap(),
    );

    localItem['doc_id'] =
        model.docId;

    localItem['is_deleted'] =
        false;

    list.removeWhere(
      (item) =>
          item['doc_id']?.toString() ==
          model.docId?.toString(),
    );

    list.add(localItem);

    await _supplierBox.put(
      key,
      list,
    );
  }

  // ============================================================
  // 4. السيريال التالي
  // ============================================================

  int _getNextSerial(
    String companyCode,
    String branchCode,
  ) {
    int maxSerial = 0;

    for (final key in _supplierBox.keys) {
      final raw =
          _supplierBox.get(key);

      if (raw is! List) continue;

      for (final item in raw) {
        final map =
            _toMapString(item);

        if (map.isEmpty ||
            map['is_deleted'] == true) {
          continue;
        }

        if (map['company_code']
                    ?.toString() !=
                companyCode ||
            map['branch_code']
                    ?.toString() !=
                branchCode) {
          continue;
        }

        final serial =
            _toInt(map['serial']);

        if (serial > maxSerial) {
          maxSerial = serial;
        }
      }
    }

    return maxSerial + 1;
  }

  // ============================================================
  // 5. تحديث التكويد من فاتورة المورد
  //
  // الموجود:
  //   يحدث الاسم والسعر.
  //
  // غير الموجود:
  //   ينشئ صنف جديد.
  // ============================================================

  Future<void> _updateCodingFromPurchase({
    required String companyCode,
    required List<SupplierItem> items,
  }) async {
    final Map<String, SupplierItem> uniqueItems = {};

    for (final item in items) {
      final code = item.code.trim();

      if (code.isEmpty) continue;
      if (item.name.trim().isEmpty) continue;

      uniqueItems[code] = item;
    }

    for (final item
        in uniqueItems.values) {
      try {
        await _saveOrUpdateCodingItem(
          companyCode: companyCode,
          item: item,
        );
      } catch (e) {
        // لا نفشل حفظ الفاتورة بالكامل
        // بسبب خطأ في التكويد.
        print(
          '⚠️ فشل تحديث التكويد للصنف ${item.code}: $e',
        );
      }
    }
  }

  // ============================================================
  // 6. حفظ / تعديل صنف في التكويد
  // ============================================================

  Future<void> _saveOrUpdateCodingItem({
    required String companyCode,
    required SupplierItem item,
  }) async {
    final key =
        '${companyCode}_items';

    Map<String, dynamic>? oldItem;

    final raw =
        _codingBox.get(key);

    if (raw is List) {
      for (final value in raw) {
        if (value is! Map) continue;

        final map =
            Map<String, dynamic>.from(
          value.map(
            (k, v) => MapEntry(
              k.toString(),
              v,
            ),
          ),
        );

        if (map['code']?.toString() ==
            item.code.trim()) {
          oldItem = map;
          break;
        }
      }
    }

    // --------------------------------------------------------
    // الاحتفاظ بالبيانات القديمة
    // --------------------------------------------------------

    final Map<String, dynamic> body =
        oldItem != null
            ? Map<String, dynamic>.from(
                oldItem,
              )
            : {
                'company_code':
                    companyCode,
                'category':
                    'items',
                'code':
                    item.code.trim(),
                'name':
                    item.name.trim(),
                'type':
                    'صنف',
                'barcode':
                    '',
                'wholesale_price':
                    0.0,
                'selling_price':
                    0.0,
                'profit_margin':
                    0.0,
                'profit_percent':
                    0.0,
              };

    // --------------------------------------------------------
    // التعديلات القادمة من فاتورة المورد
    // --------------------------------------------------------

    body['company_code'] =
        companyCode;

    body['category'] =
        'items';

    body['code'] =
        item.code.trim();

    body['name'] =
        item.name.trim();

    body['wholesale_price'] =
        item.price;

    body['is_deleted'] =
        false;

    // --------------------------------------------------------
    // إرسال التحديث للسيرفر
    // --------------------------------------------------------

    final response =
        await http.post(
      Uri.parse(
        '$baseUrl/coding/save',
      ),
      headers: {
        'Content-Type':
            'application/json',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'HTTP ${response.statusCode}: '
        '${response.body}',
      );
    }

    final result =
        jsonDecode(response.body)
            as Map<String, dynamic>;

    final savedCode =
        result['code']?.toString() ??
        item.code.trim();

    final action =
        result['action']?.toString() ??
        'update';

    // --------------------------------------------------------
    // تحديث Hive
    // --------------------------------------------------------

    final Map<String, dynamic> savedItem =
        Map<String, dynamic>.from(
      body,
    );

    savedItem['code'] =
        savedCode;

    savedItem['is_deleted'] =
        false;

    await _updateLocalCodingList(
      key,
      savedItem,
    );

    print(
      '✅ تم ${action == 'insert' ? 'إضافة' : 'تحديث'} '
      'الصنف في التكويد: ${item.code}',
    );
  }

  // ============================================================
  // 7. تحديث قائمة التكويد محلياً
  // ============================================================

  Future<void> _updateLocalCodingList(
    String key,
    Map<String, dynamic> item,
  ) async {
    List<Map<String, dynamic>> list =
        [];

    final raw =
        _codingBox.get(key);

    if (raw is List) {
      list = raw
          .whereType<Map>()
          .map(_toMapString)
          .where(
            (e) =>
                e['is_deleted'] != true,
          )
          .toList();
    }

    list.removeWhere(
      (e) =>
          e['code']?.toString() ==
          item['code']?.toString(),
    );

    list.add(item);

    list.sort(
      (a, b) {
        final aCode =
            int.tryParse(
                  a['code']?.toString() ??
                      '0',
                ) ??
                0;

        final bCode =
            int.tryParse(
                  b['code']?.toString() ??
                      '0',
                ) ??
                0;

        return aCode.compareTo(
          bCode,
        );
      },
    );

    await _codingBox.put(
      key,
      list,
    );
  }

  // ============================================================
  // 8. جلب حركات الموردين محلياً
  // ============================================================

  Future<List<SupplierTransactionModel>>
      getSupplierTransactions({
    required String companyCode,
    String? branchCode,
    String? supplierName,
    String? startDate,
    String? endDate,
  }) async {
    try {
      final List<SupplierTransactionModel>
          result = [];

      for (final key in _supplierBox.keys) {
        final raw =
            _supplierBox.get(key);

        if (raw is! List) continue;

        for (final item in raw) {
          final map =
              _toMapString(item);

          if (map.isEmpty ||
              map['is_deleted'] == true) {
            continue;
          }

          if (map['company_code']
                  ?.toString() !=
              companyCode) {
            continue;
          }

          if (branchCode != null &&
              map['branch_code']
                      ?.toString() !=
                  branchCode) {
            continue;
          }

          if (supplierName != null &&
              map['supplier_name']
                      ?.toString() !=
                  supplierName) {
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

          try {
            result.add(
              SupplierTransactionModel
                  .fromMap(map),
            );
          } catch (e) {
            print(
              '⚠️ خطأ في تحويل حركة المورد: $e',
            );
          }
        }
      }

      result.sort(
        (a, b) =>
            b.date.compareTo(a.date),
      );

      return result;
    } catch (e) {
      print(
        '❌ خطأ في جلب حركات الموردين: $e',
      );

      return [];
    }
  }

  // ============================================================
  // 9. حذف حركة مورد
  // ============================================================

  Future<bool>
      deleteSupplierTransaction(
    String companyCode,
    String docId,
  ) async {
    try {
      final response =
          await http.delete(
        Uri.parse(
          '$baseUrl/supplier/delete/'
          '$companyCode/$docId',
        ),
      );

      if (response.statusCode != 200) {
        print(
          '❌ فشل حذف حركة المورد: '
          '${response.statusCode}',
        );

        return false;
      }

      final keys =
          _supplierBox.keys.toList();

      for (final key in keys) {
        final raw =
            _supplierBox.get(key);

        if (raw is! List) continue;

        final List<Map<String, dynamic>>
            updated = [];

        bool found = false;

        for (final item in raw) {
          final map =
              _toMapString(item);

          if (map.isEmpty) continue;

          if (map['doc_id']
                  ?.toString() ==
              docId.toString()) {
            found = true;
            continue;
          }

          if (map['is_deleted'] ==
              true) {
            continue;
          }

          updated.add(map);
        }

        if (!found) continue;

        if (updated.isEmpty) {
          await _supplierBox.delete(
            key,
          );
        } else {
          await _supplierBox.put(
            key,
            updated,
          );
        }

        break;
      }

      return true;
    } catch (e) {
      print(
        '❌ خطأ أثناء حذف حركة المورد: $e',
      );

      return false;
    }
  }

  // ============================================================
  // 10. Full Sync
  // ============================================================

  Future<void> fetchAllSupplier(
    String companyCode,
  ) async {
    print(
      '📥 الموردين: بدء FULL SYNC '
      'للشركة $companyCode',
    );

    try {
      final response =
          await http.get(
        Uri.parse(
          '$baseUrl/supplier/list/'
          '$companyCode',
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }

      final List<dynamic> data =
          jsonDecode(response.body);

      for (final item in data) {
        final map =
            _toMapString(item);

        if (map.isEmpty ||
            map['is_deleted'] == true) {
          continue;
        }

        map['is_deleted'] =
            false;

        final key =
            '${map['company_code']}_'
            '${map['branch_code']}_'
            '${map['date']}';

        List<Map<String, dynamic>>
            currentList = [];

        final raw =
            _supplierBox.get(key);

        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map(_toMapString)
              .where(
                (e) =>
                    e.isNotEmpty &&
                    e['is_deleted'] != true,
              )
              .toList();
        }

        currentList.removeWhere(
          (e) =>
              e['doc_id']?.toString() ==
              map['doc_id']?.toString(),
        );

        currentList.add(map);

        await _supplierBox.put(
          key,
          currentList,
        );
      }

      print(
        '✅ تم FULL SYNC للموردين '
        '(${data.length} حركة)',
      );
    } catch (e) {
      print(
        '❌ فشل FULL SYNC للموردين: $e',
      );

      rethrow;
    }
  }

  // ============================================================
  // 11. Incremental Sync
  // ============================================================

  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs =
        await SharedPreferences
            .getInstance();

    final String lastSyncKey =
        '${ApiConstants.LAST_SYNC_SUPPLIER}'
        '$companyCode';

    final String? lastSyncValue =
        lastSync ??
        prefs.getString(
          lastSyncKey,
        );

    // ----------------------------------------------------------
    // لا يوجد lastSync
    // ----------------------------------------------------------

    if (lastSyncValue == null ||
        lastSyncValue.isEmpty) {
      print(
        '📥 الموردين: لا يوجد lastSync → FULL SYNC',
      );

      await fetchAllSupplier(
        companyCode,
      );

      await prefs.setString(
        lastSyncKey,
        DateTime.now()
            .toUtc()
            .toIso8601String(),
      );

      return;
    }

    try {
      final DateTime syncStartedAt =
          DateTime.now().toUtc();

      final DateTime since =
          DateTime.parse(
        lastSyncValue,
      ).toUtc();

      final response =
          await http.get(
        Uri.parse(
          '$baseUrl/supplier/changes/'
          '$companyCode'
          '?since=${since.toIso8601String()}',
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }

      final List<dynamic> changes =
          jsonDecode(response.body);

      for (final item in changes) {
        if (item is! Map) continue;

        final map =
            _toMapString(item);

        final docId =
            map['doc_id']?.toString();

        if (docId == null ||
            docId.isEmpty) {
          continue;
        }

        final action =
            map['action']
                    ?.toString() ??
                (
                  map['is_deleted'] ==
                          true
                      ? 'delete'
                      : 'update'
                );

        final key =
            '${map['company_code']}_'
            '${map['branch_code']}_'
            '${map['date']}';

        List<Map<String, dynamic>>
            list = [];

        final raw =
            _supplierBox.get(key);

        if (raw is List) {
          list = raw
              .whereType<Map>()
              .map(_toMapString)
              .where(
                (e) =>
                    e.isNotEmpty &&
                    e['is_deleted'] != true,
              )
              .toList();
        }

        list.removeWhere(
          (e) =>
              e['doc_id']?.toString() ==
              docId,
        );

        // ------------------------------------------------------
        // حذف
        // ------------------------------------------------------

        if (action == 'delete' ||
            map['is_deleted'] == true) {
          if (list.isEmpty) {
            await _supplierBox.delete(
              key,
            );
          } else {
            await _supplierBox.put(
              key,
              list,
            );
          }

          print(
            '🗑️ حذف حركة المورد [$docId]',
          );

          continue;
        }

        // ------------------------------------------------------
        // إضافة / تعديل
        // ------------------------------------------------------

        map.remove('action');
        map['is_deleted'] = false;

        list.add(map);

        await _supplierBox.put(
          key,
          list,
        );

        print(
          '✅ تم تحديث حركة المورد [$docId]',
        );
      }

      await prefs.setString(
        lastSyncKey,
        syncStartedAt
            .toIso8601String(),
      );

      print(
        '✅ تمت مزامنة '
        '${changes.length} تحديث للموردين',
      );
    } catch (e) {
      print(
        '❌ فشل مزامنة الموردين: $e',
      );

      rethrow;
    }
  }

  // ============================================================
  // Helpers
  // ============================================================

  Map<String, dynamic> _toMapString(
    dynamic obj,
  ) {
    if (obj is Map<String, dynamic>) {
      return Map<String, dynamic>.from(obj);
    }

    if (obj is Map) {
      return Map<String, dynamic>.from(
        obj.map(
          (key, value) => MapEntry(
            key.toString(),
            value,
          ),
        ),
      );
    }

    return {};
  }

  double _toDouble(
    dynamic value,
  ) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(
          value?.toString() ?? '',
        ) ??
        0.0;
  }

  int _toInt(
    dynamic value,
  ) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
  }
}