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
  final Box _codingBox = Hive.box('coding_box');
  final Box _settlementBox =
      Hive.box('supplier_settlement_box');

  // ============================================================
  // التحقق هل الاختيار = كل الفروع
  // ============================================================

  bool _isAllBranches(String? branchCode) {
    return branchCode == null ||
        branchCode.isEmpty ||
        branchCode == 'all' ||
        branchCode == 'الكل' ||
        branchCode == 'كل الفروع';
  }

  // ============================================================
  // 1. رصيد المورد
  //
  // المشتريات تزيد المديونية.
  // التسويات تخصم من المديونية.
  //
  // لو branchCode = فرع محدد:
  // نحسب هذا الفرع فقط.
  //
  // لو branchCode = all:
  // نحسب كل الفروع.
  // ============================================================

  Future<double> getSupplierBalance(
    String companyCode,
    String branchCode,
    String supplierName,
  ) async {
    double balance = 0.0;

    final bool allBranches =
        _isAllBranches(branchCode);

    // ----------------------------------------------------------
    // المشتريات
    // ----------------------------------------------------------

    for (final key in _supplierBox.keys) {
      final raw = _supplierBox.get(key);

      if (raw is! List) {
        continue;
      }

      for (final item in raw) {
        final map = _toMapString(item);

        if (map.isEmpty ||
            map['is_deleted'] == true) {
          continue;
        }

        if (map['company_code']?.toString() !=
            companyCode) {
          continue;
        }

        if (!allBranches &&
            map['branch_code']?.toString() !=
                branchCode) {
          continue;
        }

        if (map['supplier_name']?.toString() !=
            supplierName) {
          continue;
        }

        balance +=
            _toDouble(map['total_amount']);
      }
    }

    // ----------------------------------------------------------
    // تسويات المورد
    // ----------------------------------------------------------

    for (final key in _settlementBox.keys) {
      final raw = _settlementBox.get(key);

      if (raw is! List) {
        continue;
      }

      for (final item in raw) {
        final map = _toMapString(item);

        if (map.isEmpty ||
            map['is_deleted'] == true) {
          continue;
        }

        if (map['company_code']?.toString() !=
            companyCode) {
          continue;
        }

        if (!allBranches &&
            map['branch_code']?.toString() !=
                branchCode) {
          continue;
        }

        if (map['supplier_name']?.toString() !=
            supplierName) {
          continue;
        }

        balance -=
            _toDouble(map['amount']);
      }
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
      // إعادة حساب إجمالي الأصناف
      // --------------------------------------------------------

      double itemsTotal = 0.0;

      for (final item in model.items) {
        item.discountRate = 0.0;
        item.discountAmount = 0.0;

        item.total =
            item.quantity * item.price;

        itemsTotal += item.total;
      }

      // --------------------------------------------------------
      // لو لم ترسل الصفحة إجمالي صحيح
      // نستخدم إجمالي الأصناف
      // --------------------------------------------------------

      if (model.totalAmount <= 0) {
        model.totalAmount = itemsTotal;
      }

      // --------------------------------------------------------
      // رقم الإذن
      // --------------------------------------------------------

      if (model.serial == 0) {
        model.serial = _getNextSerial(
          model.companyCode,
          model.branchCode,
        );
      }

      // --------------------------------------------------------
      // فاتورة المشتريات ليست دفعة
      // --------------------------------------------------------

      model.paidAmount = 0.0;

      // --------------------------------------------------------
      // الحفظ في السيرفر
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
      // حفظ محلي
      // --------------------------------------------------------

      await _saveLocalTransaction(
        model,
      );

      // --------------------------------------------------------
      // تحديث التكويد
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
  try {
    final String newKey =
        '${model.companyCode}_'
        '${model.branchCode}_'
        '${model.date}';

    final String? docId =
        model.docId?.toString();

    if (docId == null || docId.isEmpty) {
      throw Exception('doc_id غير موجود أثناء الحفظ المحلي');
    }

    // ============================================================
    // 1. حذف النسخة القديمة من أي مفتاح في Hive
    //
    // مهم جدًا لو تم تعديل:
    // - التاريخ
    // - الفرع
    // - المخزن
    //
    // لأن المفتاح نفسه ممكن يتغير.
    // ============================================================

    final keys =
        _supplierBox.keys.toList();

    for (final key in keys) {
      final raw =
          _supplierBox.get(key);

      if (raw is! List) {
        continue;
      }

      final List<Map<String, dynamic>> updatedList = [];

      bool found = false;

      for (final value in raw) {
        if (value is! Map) {
          continue;
        }

        final map =
            _toMapString(value);

        if (map.isEmpty) {
          continue;
        }

        final itemDocId =
            map['doc_id']?.toString();

        // حذف النسخة القديمة لنفس الإذن
        if (itemDocId == docId) {
          found = true;
          continue;
        }

        // تنظيف أي سجل محذوف
        if (map['is_deleted'] == true) {
          continue;
        }

        updatedList.add(map);
      }

      if (!found) {
        continue;
      }

      if (updatedList.isEmpty) {
        await _supplierBox.delete(key);
      } else {
        await _supplierBox.put(
          key,
          updatedList,
        );
      }
    }

    // ============================================================
    // 2. تجهيز النسخة الجديدة
    // ============================================================

    final Map<String, dynamic> localItem =
        _toMapString(
      model.toMap(),
    );

    localItem['doc_id'] = docId;
    localItem['is_deleted'] = false;

    // ============================================================
    // 3. قراءة مفتاح التاريخ/الفرع/الشركة الجديد
    // ============================================================

    List<Map<String, dynamic>> list = [];

    final raw =
        _supplierBox.get(newKey);

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

    // ============================================================
    // 4. تأكيد عدم وجود نسخة قديمة في المفتاح الجديد
    // ============================================================

    list.removeWhere(
      (item) =>
          item['doc_id']?.toString() == docId,
    );

    // ============================================================
    // 5. إضافة النسخة الجديدة
    // ============================================================

    list.add(localItem);

    await _supplierBox.put(
      newKey,
      list,
    );

    print(
      '✅ تم تحديث فاتورة المورد محليًا [$docId]',
    );
  } catch (e) {
    print(
      '❌ خطأ أثناء الحفظ المحلي لفاتورة المورد: $e',
    );

    rethrow;
  }
}

  // ============================================================
  // 4. رقم الإذن التالي
  //
  // مستقل لكل شركة + فرع
  // ============================================================

  // lib/services/supplier_service.dart

int _getNextSerial(String companyCode, String branchCode) {
  int maxSerial = 0;

  for (final key in _supplierBox.keys) {
    final raw = _supplierBox.get(key);
    if (raw is! List) continue;

    for (final item in raw) {
      final map = _toMapString(item);
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
  // 5. تحديث التكويد من فاتورة المورد
  // ============================================================

  Future<void> _updateCodingFromPurchase({
    required String companyCode,
    required List<SupplierItem> items,
  }) async {
    final Map<String, SupplierItem>
        uniqueItems = {};

    for (final item in items) {
      final code =
          item.code.trim();

      if (code.isEmpty ||
          item.name.trim().isEmpty) {
        continue;
      }

      uniqueItems[code] = item;
    }

    for (final item
        in uniqueItems.values) {
      try {
        await _saveOrUpdateCodingItem(
          companyCode:
              companyCode,
          item:
              item,
        );
      } catch (e) {
        print(
          '⚠️ فشل تحديث التكويد للصنف '
          '${item.code}: $e',
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
        if (value is! Map) {
          continue;
        }

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

    // ----------------------------------------------------------
    // الاحتفاظ بالبيانات القديمة
    // ----------------------------------------------------------

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

    // ----------------------------------------------------------
    // التعديلات
    // ----------------------------------------------------------

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

    // ----------------------------------------------------------
    // حفظ على السيرفر
    // ----------------------------------------------------------

    final response =
        await http.post(
      Uri.parse(
        '$baseUrl/coding/save',
      ),
      headers: {
        'Content-Type':
            'application/json',
      },
      body:
          jsonEncode(body),
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

    // ----------------------------------------------------------
    // تحديث Hive
    // ----------------------------------------------------------

    final Map<String, dynamic>
        savedItem =
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
    List<Map<String, dynamic>>
        list = [];

    final raw =
        _codingBox.get(key);

    if (raw is List) {
      list = raw
          .whereType<Map>()
          .map(_toMapString)
          .where(
            (e) =>
                e['is_deleted'] !=
                true,
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
                  a['code']
                          ?.toString() ??
                      '0',
                ) ??
                0;

        final bCode =
            int.tryParse(
                  b['code']
                          ?.toString() ??
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
  // 8. جلب حركات الموردين
  //
  // null / all = كل الفروع
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
      final List<
              SupplierTransactionModel>
          result = [];

      final bool allBranches =
          _isAllBranches(
        branchCode,
      );

      for (final key
          in _supplierBox.keys) {
        final raw =
            _supplierBox.get(key);

        if (raw is! List) {
          continue;
        }

        for (final item in raw) {
          final map =
              _toMapString(item);

          if (map.isEmpty ||
              map['is_deleted'] ==
                  true) {
            continue;
          }

          // ----------------------------------------------------
          // الشركة
          // ----------------------------------------------------

          if (map['company_code']
                  ?.toString() !=
              companyCode) {
            continue;
          }

          // ----------------------------------------------------
          // الفرع
          // ----------------------------------------------------

          if (!allBranches &&
              map['branch_code']
                      ?.toString() !=
                  branchCode) {
            continue;
          }

          // ----------------------------------------------------
          // المورد
          // ----------------------------------------------------

          if (supplierName !=
                  null &&
              map['supplier_name']
                      ?.toString() !=
                  supplierName) {
            continue;
          }

          // ----------------------------------------------------
          // التاريخ
          // ----------------------------------------------------

          final date =
              map['date']
                      ?.toString() ??
                  '';

          if (startDate !=
                  null &&
              date.compareTo(
                    startDate,
                  ) <
                  0) {
            continue;
          }

          if (endDate !=
                  null &&
              date.compareTo(
                    endDate,
                  ) >
                  0) {
            continue;
          }

          // ----------------------------------------------------
          // تحويل الموديل
          // ----------------------------------------------------

          try {
            result.add(
              SupplierTransactionModel
                  .fromMap(
                map,
              ),
            );
          } catch (e) {
            print(
              '⚠️ خطأ في تحويل حركة المورد: $e',
            );
          }
        }
      }

      // --------------------------------------------------------
      // ترتيب التاريخ ثم رقم الإذن
      // --------------------------------------------------------

      result.sort(
        (a, b) {
          final dateCompare =
              b.date.compareTo(
            a.date,
          );

          if (dateCompare != 0) {
            return dateCompare;
          }

          return b.serial.compareTo(
            a.serial,
          );
        },
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

  Future<bool> deleteSupplierTransaction(
  String companyCode,
  String docId,
) async {
  try {
    final response = await http.delete(
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

    // ============================================================
    // Soft Delete محلياً
    //
    // نحتفظ بالسجل في Hive مع is_deleted = true
    // حتى لا يُعاد استخدام رقم الإذن
    // ============================================================

    final keys = _supplierBox.keys.toList();

    for (final key in keys) {
      final raw = _supplierBox.get(key);

      if (raw is! List) {
        continue;
      }

      final List<Map<String, dynamic>> updated = [];
      bool found = false;

      for (final item in raw) {
        final map = _toMapString(item);

        if (map.isEmpty) {
          continue;
        }

        if (map['doc_id']?.toString() == docId.toString()) {
          found = true;

          // ✅ نحتفظ به لكن مع علامة محذوف
          map['is_deleted'] = true;
          map['updated_at'] = DateTime.now().toUtc().toIso8601String();

          updated.add(map);
          continue;
        }

        // تنظيف أي سجل محذوف سابق
        if (map['is_deleted'] == true) {
          continue;
        }

        updated.add(map);
      }

      if (!found) {
        continue;
      }

      if (updated.isEmpty) {
        await _supplierBox.delete(key);
      } else {
        await _supplierBox.put(key, updated);
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

      if (response.statusCode !=
          200) {
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
            map['is_deleted'] ==
                true) {
          continue;
        }

        map['is_deleted'] =
            false;

        final key =
            '${map['company_code']}_'
            '${map['branch_code']}_'
            '${map['date']}';

        List<
                Map<String, dynamic>>
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
                    e['is_deleted'] !=
                        true,
              )
              .toList();
        }

        currentList.removeWhere(
          (e) =>
              e['doc_id']
                  ?.toString() ==
              map['doc_id']
                  ?.toString(),
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

  // lib/services/supplier_service.dart

Future<void> syncChangesFromServer(
  String companyCode, [
  String? lastSync,
]) async {
  final prefs = await SharedPreferences.getInstance();
  final String lastSyncKey =
      '${ApiConstants.LAST_SYNC_SUPPLIER}$companyCode';
  final String? lastSyncValue =
      lastSync ?? prefs.getString(lastSyncKey);

  // ==========================================================
  // لا يوجد lastSync → Full Sync
  // ==========================================================

  if (lastSyncValue == null || lastSyncValue.isEmpty) {
    print('📥 الموردين: لا يوجد lastSync → FULL SYNC');
    await fetchAllSupplier(companyCode);
    await prefs.setString(
      lastSyncKey,
      DateTime.now().toUtc().toIso8601String(),
    );
    return;
  }

  try {
    final DateTime syncStartedAt = DateTime.now().toUtc();
    DateTime since = DateTime.parse(lastSyncValue).toUtc();
    since = since.subtract(const Duration(minutes: 1));

    final response = await http.get(
      Uri.parse(
        '$baseUrl/supplier/changes/$companyCode'
        '?since=${since.toIso8601String()}',
      ),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final List<dynamic> changes = jsonDecode(response.body);

    for (final item in changes) {
      if (item is! Map) continue;

      final map = _toMapString(item);
      final docId = map['doc_id']?.toString();

      if (docId == null || docId.isEmpty) continue;

      final action = map['action']?.toString() ??
          (map['is_deleted'] == true ? 'delete' : 'update');

      // ========================================================
      // الخطوة 1: حذف doc_id من جميع المفاتيح (لأي فرع/تاريخ قديم)
      // ========================================================

      final keys = _supplierBox.keys.toList();

      for (final oldKey in keys) {
        final raw = _supplierBox.get(oldKey);

        if (raw is! List) continue;

        final List<Map<String, dynamic>> updatedList = [];

        bool found = false;

        for (final value in raw) {
          if (value is! Map) continue;

          final mapItem = _toMapString(value);

          if (mapItem.isEmpty) continue;

          if (mapItem['doc_id']?.toString() == docId) {
            found = true;
            continue;
          }

          if (mapItem['is_deleted'] == true) continue;

          updatedList.add(mapItem);
        }

        if (!found) continue;

        if (updatedList.isEmpty) {
          await _supplierBox.delete(oldKey);
        } else {
          await _supplierBox.put(oldKey, updatedList);
        }
      }

      // ========================================================
      // الخطوة 2: لو الحذف، نوقف هنا
      // ========================================================

      if (action == 'delete' || map['is_deleted'] == true) {
        print('🗑️ تم حذف حركة المورد [$docId] من Hive (Incremental Sync)');
        continue;
      }

      // ========================================================
      // الخطوة 3: إضافة أو تحديث في المفتاح الجديد
      // ========================================================

      final company = map['company_code']?.toString() ?? companyCode;
      final branch = map['branch_code']?.toString() ?? 'all';
      final date = map['date']?.toString() ?? '';

      if (company.isEmpty || branch.isEmpty || date.isEmpty) {
        print('⚠️ بيانات المفتاح ناقصة للمورد [$docId]');
        continue;
      }

      final newKey = '${company}_${branch}_$date';

      List<Map<String, dynamic>> list = [];

      final raw = _supplierBox.get(newKey);

      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map(_toMapString)
            .where(
              (e) => e.isNotEmpty && e['is_deleted'] != true,
            )
            .toList();
      }

      // منع التكرار (مرة أخرى للتأكيد)
      list.removeWhere(
        (item) => item['doc_id']?.toString() == docId,
      );

      map.remove('action');
      map['is_deleted'] = false;

      list.add(map);

      await _supplierBox.put(newKey, list);

      print('✅ تم تحديث حركة المورد [$docId] في المفتاح [$newKey]');
    }

    // ========================================================
    // تحديث lastSync فقط بعد نجاح الكل
    // ========================================================

    await prefs.setString(
      lastSyncKey,
      syncStartedAt.toIso8601String(),
    );

    print(
      '✅ تمت مزامنة ${changes.length} تحديث للموردين (Incremental Sync)',
    );
  } catch (e) {
    print('❌ فشل مزامنة الموردين: $e');
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
      return Map<String, dynamic>.from(
        obj,
      );
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

  // ============================================================
  // تحويل إلى Double
  // ============================================================

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

  // ============================================================
  // تحويل إلى Int
  // ============================================================

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