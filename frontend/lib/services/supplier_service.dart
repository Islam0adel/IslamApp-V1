import 'cache_partitions.dart';
// lib/services/supplier_service.dart

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/supplier_transaction_model.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';
import 'staged_changes.dart';
import 'sync_read_access.dart';

class SupplierService {
  final String baseUrl = ApiConstants.baseUrl;

  Box get _supplierBox => CachePartitions.box('supplier_box');
  Box get _codingBox => CachePartitions.box('coding_box');
  Box get _settlementBox => CachePartitions.box('supplier_settlement_box');

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

  /// الرصيد مشتق من إجماليات الفواتير (أسعار جملة): لا يُحسب
  /// ولا يُعرض لمن لا يملك حق التكلفة. الإرجاع null = "مخفي"،
  /// والواجهة تعرض '—' ولا تجري أي حساب على القيمة. لا NaN
  /// يتسلل إلى الحسابات أو يُحفظ في الحقول الرقمية.
  Future<double?> getSupplierBalance(
    String companyCode,
    String branchCode,
    String supplierName,
  ) async {
return CachePartitions.run(() async {

    if (!PermissionsService().canViewCostPrices) {
      return null;
    }

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

if (map['supplier_name']?.toString().trim() !=
            supplierName.trim()) {
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

        if (map['supplier_name']?.toString().trim() !=
            supplierName.trim()) {
          continue;
        }

        balance -=
            _toDouble(map['amount']);
      }
    }

    if (balance.abs() < 0.0001) {
      balance = 0.0;
    }

    return balance;
});
}

  // ============================================================
  // 2. حفظ فاتورة مشتريات
  // ============================================================

  Future<Map<String, dynamic>>
      saveSupplierTransaction(
    SupplierTransactionModel model,
  ) async {
return CachePartitions.run(() async {

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

      final response = await AuthHttp.post(
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

      // تحديث التكويد من فاتورة الشراء: فقط لمن يملك حق إضافة
      // التكويد مع حق عرض التكلفة معاً. بلا حق التكلفة تكون
      // أسعار البنود مخفية محلياً (صفر)، وإرسالها إلى التكويد
      // كان سيمسح سعر الجملة المخزن بصفر — فلا نداء جانبي أصلاً.
      // الأصناف المعروفة محفوظة بالفعل بأسعار الكتالوج من الخادم.
      if (model.isAddToCoding &&
          PermissionsService().canAddCodingItem &&
          PermissionsService().canViewCostPrices) {
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
});
}

  // ============================================================
  // 3. حفظ الفاتورة محلياً
  // ============================================================

  Future<void> _saveLocalTransaction(
  SupplierTransactionModel model,
) async {
return CachePartitions.run(() async {

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

    // من لا يملك حق التكلفة: لا تُخزَّن أسعار ولا إجماليات على
    // الجهاز (الخادم يحفظ القيم الصحيحة ويزوّد بها أصحاب الحق
    // فقط). تخزينها هنا محلياً كان سيسرّبها للكاش.
    if (!PermissionsService().canViewCostPrices) {
      localItem.remove('total_amount');
      localItem.remove('totalAmount');
      final rawItems = localItem['items'];
      if (rawItems is List) {
        localItem['items'] = rawItems.map((e) {
          if (e is Map) {
            final m = Map<String, dynamic>.from(e);
            m.remove('price');
            m.remove('total');
            m.remove('discountAmount');
            m.remove('discountRate');
            return m;
          }
          return e;
        }).toList();
      }
    }

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

});
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
return CachePartitions.run(() async {

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
});
}

  // ============================================================
  // 6. حفظ / تعديل صنف في التكويد
  // ============================================================

  Future<void> _saveOrUpdateCodingItem({
    required String companyCode,
    required SupplierItem item,
  }) async {
return CachePartitions.run(() async {

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
        await AuthHttp.post(
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
});
}

  // ============================================================
  // 7. تحديث قائمة التكويد محلياً
  // ============================================================

  Future<void> _updateLocalCodingList(
    String key,
    Map<String, dynamic> item,
  ) async {
return CachePartitions.run(() async {

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
});
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
return CachePartitions.run(() async {

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
});
}

  // ============================================================
  // 9. حذف حركة مورد
  // ============================================================

  Future<bool> deleteSupplierTransaction(
  String companyCode,
  String docId,
) async {
return CachePartitions.run(() async {

  try {
    final response = await AuthHttp.delete(
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

});
}

  // ============================================================
  // 10. Full Sync
  // ============================================================

  Future<void> fetchAllSupplier(
    String companyCode, {
    bool replace = false,
  }) async {
return CachePartitions.run(() async {

    final v2Candidate = await _captureV2(companyCode);

    print(
      '📥 الموردين: بدء FULL SYNC '
      'للشركة $companyCode',
    );

    try {
      final response =
          await AuthHttp.get(
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

      final Set<String> replacedKeys = {};
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

        if (replace && replacedKeys.add(key)) {
          // epoch reconcile: start this list from the server copy only
        } else if (raw is List) {
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

      if (replace) {
        final prefix = '${companyCode}_';
        for (final k in _supplierBox.keys.toList()) {
          if (k.toString().startsWith(prefix) && !replacedKeys.contains(k.toString())) {
            await _supplierBox.delete(k);
          }
        }
      }

      print(
        '✅ تم FULL SYNC للموردين '
        '(${data.length} حركة)',
      );
      await _commitV2(companyCode, v2Candidate);
    } catch (e) {
      print(
        '❌ فشل FULL SYNC للموردين: $e',
      );

      rethrow;
    }
});
}

  // ============================================================
  // Staged feed (/supplier/changes-v2) checkpoint + merge
  // ============================================================

  static void Function(String company)? onCheckpointChanged;
  static String v2CursorKey(String c) => '${ApiConstants.LAST_SYNC_SUPPLIER}${c}_v2';
  static String v2ScopeKey(String c) => '${ApiConstants.LAST_SYNC_SUPPLIER}${c}_v2scope';
  static String v2EpochKey(String c) => '${ApiConstants.LAST_SYNC_SUPPLIER}${c}_v2epoch';

  Future<({String cursor, String scope, String epoch})?> _captureV2(String company) async {
    try {
      final r = await AuthHttp.get(Uri.parse('$baseUrl/supplier/changes-v2/$company?cursor=latest'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body);
      if (m is! Map ||
          m['invalid'] == true ||
          m['next_cursor'] is! String ||
          m['scope'] is! String ||
          (m['next_cursor'] as String).isEmpty ||
          (m['scope'] as String).isEmpty) return null;
      return (cursor: m['next_cursor'] as String, scope: m['scope'] as String, epoch: (m['epoch'] ?? '').toString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _commitV2(String company, ({String cursor, String scope, String epoch})? cand) async {
    if (cand == null) return;
    try {
      final prefs = await CachePartitions.preferences();
      await prefs.setString(v2CursorKey(company), cand.cursor);
      await prefs.setString(v2ScopeKey(company), cand.scope);
      await prefs.setString(v2EpochKey(company), cand.epoch);
      try {
        onCheckpointChanged?.call(company);
      } catch (_) {}
    } catch (_) {}
  }

  Future<({String cursor, String scope})?> stagedCheckpoint(String company) async {
    try {
      final allowed = SyncReadAccess.allows('supplier');
      final prefs = await CachePartitions.preferences();
      final c = prefs.getString(v2CursorKey(company));
      final s = prefs.getString(v2ScopeKey(company));
      if (!allowed) return null;
      if (c == null || c.isEmpty || s == null || s.isEmpty) return null;
      return (cursor: c, scope: s);
    } catch (_) {
      return null;
    }
  }

  bool _mayCosts() {
    final p = PermissionsService();
    return p.canBypassPermissions ||
        p.hasPermission('التكويد', 'سعر الشراء') ||
        p.hasPermission('المبيعات', 'عرض سعر الجملة') ||
        p.hasPermission('رصيد المخزون', 'عرض سعر الجملة');
  }

  static const _costKeys = ['total_amount', 'totalAmount', 'discountAmount', 'discountRate'];
  static const _itemCostKeys = ['price', 'total', 'discountAmount', 'discountRate'];

  /// Removes the pricing the viewer may not hold: invoice total and every item price/total.
  void _stripCosts(Map<String, dynamic> m) {
    for (final k in _costKeys) {
      m.remove(k);
    }
    final items = m['items'];
    if (items is List) {
      m['items'] = [
        for (final it in items)
          if (it is Map)
            {for (final e in it.entries) if (!_itemCostKeys.contains(e.key.toString())) e.key.toString(): e.value}
          else
            it
      ];
    }
  }

  /// Applies one /supplier/changes-v2 response fetched by the service worker while the app was
  /// closed. Applied only when it continues exactly from the stored cursor and scope, under the
  /// supplier read right held NOW. Pricing is removed again at merge time when the cost right is
  /// gone. Returns true when applied.
  Future<bool> applyStagedBatch(String company, dynamic decoded,
      {required String fromCursor, required String fromScope}) async {
    try {
      return await CachePartitions.run(() async {
        final epoch = ReadAuthorizationEpoch.value;
        if (!SyncReadAccess.allows('supplier')) return false;
        final prefs = await CachePartitions.preferences();
        if (prefs.getString(v2CursorKey(company)) != fromCursor ||
            prefs.getString(v2ScopeKey(company)) != fromScope) return false;
        if (decoded is! Map ||
            decoded['invalid'] == true ||
            decoded['scope'] != fromScope ||
            decoded['next_cursor'] is! String ||
            (decoded['next_cursor'] as String).isEmpty ||
            decoded['items'] is! List) return false;
        final localStamp = <String, DateTime?>{};
        for (final key in _supplierBox.keys) {
          final raw = _supplierBox.get(key);
          if (raw is! List) continue;
          for (final v in raw) {
            if (v is Map) localStamp[v['doc_id']?.toString() ?? ''] = StagedChanges.stamp(v['updated_at']);
          }
        }
        final scopeBefore = PermissionsService().effectiveScopeSignature();
        final mayCosts = _mayCosts();
        final fresh = <Map<String, dynamic>>[];
        for (final raw in decoded['items'] as List) {
          if (raw is! Map) return false;
          final m = _toMapString(raw);
          if (m['company_code']?.toString() != company) return false;
          final id = m['doc_id']?.toString() ?? '';
          if (id.isEmpty) return false;
          final l = localStamp[id];
          final i = StagedChanges.stamp(m['updated_at']);
          if (l != null && i != null && l.isAfter(i)) continue;
          if (m['tombstone'] != true && !mayCosts) _stripCosts(m);
          m.remove('tombstone');
          fresh.add(m);
        }
        if (fresh.isNotEmpty) {
          if (!SyncReadAccess.allows('supplier') || epoch != ReadAuthorizationEpoch.value) return false;
          await _applyChanges(company, fresh);
        }
        if (!SyncReadAccess.allows('supplier') ||
            PermissionsService().effectiveScopeSignature() != scopeBefore) {
          // Scope (rights, branches, role, policy) moved while writing: take back this batch's rows.
          final written = {for (final m in fresh) if (m['action'] != 'delete') m['doc_id']?.toString()};
          if (written.isNotEmpty) {
            for (final key in _supplierBox.keys.toList()) {
              final raw = _supplierBox.get(key);
              if (raw is! List) continue;
              final keep = raw.where((e) => !(e is Map && written.contains(e['doc_id']?.toString()))).toList();
              if (keep.length == raw.length) continue;
              if (keep.isEmpty) {
                await _supplierBox.delete(key);
              } else {
                await _supplierBox.put(key, keep);
              }
            }
          }
          return false;
        }
        await prefs.setString(v2CursorKey(company), decoded['next_cursor'] as String);
        try {
          onCheckpointChanged?.call(company);
        } catch (_) {}
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  // ============================================================
  // 11. Incremental Sync
  // ============================================================

  // lib/services/supplier_service.dart

  /// Applies a list of supplier changes (update/delete/tombstone) to the cached lists. Shared by the
  /// live incremental sync and by staged batches.
  Future<void> _applyChanges(String companyCode, List<dynamic> changes) async {
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

  }

Future<void> syncChangesFromServer(
  String companyCode, [
  String? lastSync,
]) async {
return CachePartitions.run(() async {

  final prefs = await CachePartitions.preferences();
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
    final v2Candidate = await _captureV2(companyCode);
    final String? storedEpoch = prefs.getString(v2EpochKey(companyCode));
    if (v2Candidate != null && storedEpoch != null && storedEpoch != v2Candidate.epoch) {
      print('📥 الموردين: feed epoch changed → FULL SYNC');
      final startedAt = DateTime.now().toUtc();
      await fetchAllSupplier(companyCode, replace: true);
      await prefs.setString(lastSyncKey, startedAt.toIso8601String());
      return;
    }
    final DateTime syncStartedAt = DateTime.now().toUtc();
    DateTime since = DateTime.parse(lastSyncValue).toUtc();
    since = since.subtract(const Duration(minutes: 1));

    final response = await AuthHttp.get(
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

    await _applyChanges(companyCode, changes);

    // ========================================================
    // تحديث lastSync فقط بعد نجاح الكل
    // ========================================================

    await prefs.setString(
      lastSyncKey,
      syncStartedAt.toIso8601String(),
    );
    await _commitV2(companyCode, v2Candidate);

    print(
      '✅ تمت مزامنة ${changes.length} تحديث للموردين (Incremental Sync)',
    );
  } catch (e) {
    print('❌ فشل مزامنة الموردين: $e');
    rethrow;
  }

});
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
