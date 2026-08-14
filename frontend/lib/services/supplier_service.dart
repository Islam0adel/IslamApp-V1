// lib/services/supplier_service.dart

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/supplier_transaction_model.dart';
import '../core/constants.dart';


class SupplierService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;


  // ============================================================
  // Hive
  // ============================================================

  final Box _supplierBox =
      Hive.box('supplier_box');


  // ============================================================
  // 1. حساب الرصيد التراكمي لمورد
  //
  // المحذوف لا يدخل في الحساب
  // ============================================================

  Future<double> getSupplierBalance(
    String companyCode,
    String branchCode,
    String supplierName,
  ) async {
    double balance = 0.0;

    for (final key in _supplierBox.keys) {
      final dynamic raw =
          _supplierBox.get(key);

      if (raw is! List) {
        continue;
      }

      for (final item in raw) {
        final Map<String, dynamic> map =
            _toMapString(item);

        if (map.isEmpty) {
          continue;
        }

        // ------------------------------------------------------
        // تجاهل المحذوف
        // ------------------------------------------------------

        if (map['is_deleted'] == true) {
          continue;
        }

        if (map['company_code'] !=
                companyCode ||
            map['branch_code'] !=
                branchCode ||
            map['supplier_name'] !=
                supplierName) {
          continue;
        }

        final String type =
            map['type']?.toString() ?? '';

        final double amount =
            (map['total_amount'] is num)
                ? (map['total_amount'] as num)
                    .toDouble()
                : double.tryParse(
                      map['total_amount']
                              ?.toString() ??
                          '0',
                    ) ??
                    0.0;

        if (type ==
            'صادر (دفعة)') {
          balance += amount;
        } else {
          balance -= amount;
        }
      }
    }

    return balance.abs();
  }


  // ============================================================
  // 2. حفظ / تحديث حركة المورد
  // ============================================================

  Future<Map<String, dynamic>>
      saveSupplierTransaction(
    SupplierTransactionModel model,
  ) async {
    try {
      // --------------------------------------------------------
      // حساب الإجماليات
      // --------------------------------------------------------

      double total = 0.0;

      for (final item in model.items) {
        item.total =
            (item.quantity * item.price) -
                item.discountAmount;

        total += item.total;
      }

      model.totalAmount = total;


      // --------------------------------------------------------
      // Serial تلقائي
      // --------------------------------------------------------

      if (model.serial == 0) {
        int maxSerial = 0;

        for (final key
            in _supplierBox.keys) {
          final dynamic raw =
              _supplierBox.get(key);

          if (raw is! List) {
            continue;
          }

          for (final rawItem in raw) {
            final Map<String, dynamic> item =
                _toMapString(rawItem);

            if (item.isEmpty ||
                item['is_deleted'] == true) {
              continue;
            }

            if (item['company_code'] ==
                    model.companyCode &&
                item['branch_code'] ==
                    model.branchCode) {
              final int s =
                  int.tryParse(
                        item['serial']
                                ?.toString() ??
                            '0',
                      ) ??
                      0;

              if (s > maxSerial) {
                maxSerial = s;
              }
            }
          }
        }

        model.serial =
            maxSerial + 1;
      }


      // --------------------------------------------------------
      // حفظ في السيرفر
      // --------------------------------------------------------

      final response = await http.post(
        Uri.parse(
          '$baseUrl/supplier/save',
        ),
        headers: {
          'Content-Type':
              'application/json',
        },
        body: json.encode(
          model.toMap(),
        ),
      );


      if (response.statusCode != 200) {
        return {
          'success': false,
          'error':
              'فشل حفظ حركة المورد في السيرفر '
              'HTTP ${response.statusCode}',
        };
      }


      final Map<String, dynamic> result =
          json.decode(response.body);


      final String docId =
          result['doc_id']
                  ?.toString() ??
              '';


      if (docId.isEmpty) {
        return {
          'success': false,
          'error':
              'السيرفر لم يرجع doc_id',
        };
      }


      model.docId =
          docId;


      // --------------------------------------------------------
      // تحديث Hive محليًا
      // --------------------------------------------------------

      final String localKey =
          '${model.companyCode}_'
          '${model.branchCode}_'
          '${model.date}';


      List<Map<String, dynamic>>
          currentList = [];


      if (_supplierBox.containsKey(
        localKey,
      )) {
        final raw =
            _supplierBox.get(
          localKey,
        );

        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map(
                (e) =>
                    _toMapString(e),
              )
              .where(
                (e) =>
                    e.isNotEmpty &&
                    e['is_deleted'] !=
                        true,
              )
              .toList();
        }
      }


      final Map<String, dynamic>
          localItem =
          _toMapString(
        model.toMap(),
      );


      localItem['doc_id'] =
          docId;

      localItem['is_deleted'] =
          false;


      currentList.removeWhere(
        (e) =>
            e['doc_id']?.toString() ==
            docId,
      );


      currentList.add(
        localItem,
      );


      await _supplierBox.put(
        localKey,
        currentList,
      );


      return {
        'success': true,
        'doc_id': docId,
        'action':
            result['action']
                ?.toString() ??
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
  // 3. جلب حركات الموردين محليًا
  //
  // لا نعمل API هنا إذا البيانات المحلية موجودة.
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
          all = [];


      for (final key
          in _supplierBox.keys) {
        final dynamic raw =
            _supplierBox.get(key);

        if (raw is! List) {
          continue;
        }


        for (final item in raw) {
          final Map<String, dynamic> map =
              _toMapString(item);

          if (map.isEmpty) {
            continue;
          }


          // ----------------------------------------------------
          // المحذوف لا يظهر
          // ----------------------------------------------------

          if (map['is_deleted'] == true) {
            continue;
          }


          if (map['company_code'] !=
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


          final String date =
              map['date']?.toString() ?? '';


          if (startDate != null &&
              date.compareTo(
                    startDate,
                  ) <
                  0) {
            continue;
          }


          if (endDate != null &&
              date.compareTo(
                    endDate,
                  ) >
                  0) {
            continue;
          }


          try {
            all.add(
              SupplierTransactionModel
                  .fromMap(map),
            );
          } catch (e) {
            print(
              '⚠️ خطأ في تحويل حركة مورد: $e',
            );
          }
        }
      }


      all.sort(
        (a, b) =>
            b.date.compareTo(
              a.date,
            ),
      );


      return all;
    } catch (e) {
      print(
        '❌ خطأ في جلب حركات الموردين: $e',
      );

      return [];
    }
  }


  // ============================================================
  // 4. حذف حركة مورد
  //
  // السيرفر يعمل Soft Delete
  // والجهاز الحالي يحذفها من Hive فورًا.
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
          '❌ فشل حذف حركة المورد من السيرفر: '
          '${response.statusCode}',
        );

        return false;
      }


      // --------------------------------------------------------
      // حذف محلي فوري
      // --------------------------------------------------------

      final keys =
          _supplierBox.keys.toList();


      for (final key in keys) {
        final dynamic raw =
            _supplierBox.get(key);

        if (raw is! List) {
          continue;
        }


        final List<Map<String, dynamic>>
            updated = [];

        bool found = false;


        for (final item in raw) {
          final Map<String, dynamic> map =
              _toMapString(item);

          if (map.isEmpty) {
            continue;
          }


          if (map['doc_id']?.toString() ==
              docId.toString()) {
            found = true;
            continue;
          }


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
        '❌ خطأ في حذف حركة المورد: $e',
      );

      return false;
    }
  }


  // ============================================================
  // 5. Full Sync للموردين
  //
  // يستخدم فقط عندما لا يوجد lastSync.
  // ============================================================

  Future<void> fetchAllSupplier(
    String companyCode,
  ) async {
    print(
      "📥 الموردين: بدء FULL SYNC "
      "للشركة $companyCode",
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
          'فشل جلب حركات الموردين من السيرفر '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      final List<dynamic> data =
          jsonDecode(
        response.body,
      );


      for (final item in data) {
        final Map<String, dynamic> map =
            _toMapString(item);

        if (map.isEmpty) {
          continue;
        }


        if (map['is_deleted'] == true) {
          continue;
        }


        map['is_deleted'] =
            false;


        final String key =
            "${map['company_code']}_"
            "${map['branch_code']}_"
            "${map['date']}";


        List<Map<String, dynamic>>
            currentList = [];


        if (_supplierBox.containsKey(
          key,
        )) {
          final raw =
              _supplierBox.get(key);

          if (raw is List) {
            currentList = raw
                .whereType<Map>()
                .map(
                  (e) =>
                      _toMapString(e),
                )
                .where(
                  (e) =>
                      e.isNotEmpty &&
                      e['is_deleted'] !=
                          true,
                )
                .toList();
          }
        }


        currentList.removeWhere(
          (e) =>
              e['doc_id']?.toString() ==
              map['doc_id']?.toString(),
        );


        currentList.add(
          map,
        );


        await _supplierBox.put(
          key,
          currentList,
        );
      }


      print(
        "✅ تم FULL SYNC للموردين "
        "(${data.length} حركة)",
      );

    } catch (e) {
      print(
        "❌ فشل FULL SYNC للموردين: $e",
      );

      rethrow;
    }
  }


  // ============================================================
  // 6. تحويل آمن إلى Map<String, dynamic>
  // ============================================================

  Map<String, dynamic> _toMapString(
    dynamic obj,
  ) {
    if (obj is Map<String, dynamic>) {
      return obj;
    }


    if (obj is Map) {
      return Map<String, dynamic>.from(
        obj.map(
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


  // ============================================================
  // 7. Incremental Sync للموردين
  //
  // جهاز قديم:
  // /supplier/changes فقط
  // ============================================================

  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs =
        await SharedPreferences.getInstance();


    final String lastSyncKey =
        '${ApiConstants.LAST_SYNC_SUPPLIER}$companyCode';


    final String? lastSyncValue =
        lastSync ??
        prefs.getString(
          lastSyncKey,
        );


    // ==========================================================
    // جهاز جديد
    // ==========================================================

    if (lastSyncValue == null ||
        lastSyncValue.isEmpty) {
      print(
        "📥 الموردين: لا يوجد lastSync "
        "→ FULL SYNC",
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


    // ==========================================================
    // جهاز قديم
    // ==========================================================

    print(
      "📡 الموردين: INCREMENTAL SYNC "
      "منذ $lastSyncValue",
    );


    try {
      final DateTime syncStartedAt =
          DateTime.now().toUtc();


      final DateTime sinceDt =
          DateTime.parse(
        lastSyncValue,
      ).toUtc();


      final String effectiveSince =
          sinceDt.toIso8601String();


      final response =
          await http.get(
        Uri.parse(
          '$baseUrl/supplier/changes/'
          '$companyCode'
          '?since=$effectiveSince',
        ),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'فشل مزامنة الموردين. '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      final List<dynamic>
          changes =
          jsonDecode(
        response.body,
      );


      // --------------------------------------------------------
      // تطبيق التغييرات
      // --------------------------------------------------------

      for (final item in changes) {
        if (item is! Map) {
          continue;
        }


        final Map<String, dynamic> map =
            _toMapString(item);


        final String action =
            map['action']
                    ?.toString() ??
                (
                  map['is_deleted'] ==
                          true
                      ? 'delete'
                      : 'update'
                );


        final String? docId =
            map['doc_id']?.toString();


        if (docId == null ||
            docId.isEmpty) {
          throw Exception(
            'تحديث مورد بدون doc_id',
          );
        }


        final String key =
            '${map['company_code']}_'
            '${map['branch_code']}_'
            '${map['date']}';


        List<Map<String, dynamic>>
            list = [];


        if (_supplierBox.containsKey(
          key,
        )) {
          final raw =
              _supplierBox.get(key);


          if (raw is List) {
            list = raw
                .whereType<Map>()
                .map(
                  (e) =>
                      _toMapString(e),
                )
                .where(
                  (e) =>
                      e.isNotEmpty &&
                      e['is_deleted'] !=
                          true,
                )
                .toList();
          }
        }


        // ------------------------------------------------------
        // إزالة النسخة القديمة
        // ------------------------------------------------------

        list.removeWhere(
          (e) =>
              e['doc_id']?.toString() ==
              docId,
        );


        // ------------------------------------------------------
        // DELETE
        // ------------------------------------------------------

        if (action == 'delete' ||
            map['is_deleted'] == true) {
          print(
            "🗑️ حذف حركة مورد [$docId] من Hive",
          );


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


          continue;
        }


        // ------------------------------------------------------
        // INSERT / UPDATE
        // ------------------------------------------------------

        map.remove(
          'action',
        );


        map['is_deleted'] =
            false;


        list.add(
          map,
        );


        await _supplierBox.put(
          key,
          list,
        );


        print(
          "✅ تم تحديث حركة المورد [$docId]",
        );
      }


      // --------------------------------------------------------
      // حفظ lastSync بعد نجاح كل التغييرات
      // --------------------------------------------------------

      await prefs.setString(
        lastSyncKey,
        syncStartedAt
            .toIso8601String(),
      );


      print(
        "✅ تمت مزامنة "
        "${changes.length} تحديث للموردين",
      );

    } catch (e) {
      print(
        "❌ فشل مزامنة الموردين: $e",
      );

      // مهم:
      // لا نغير lastSync عند الفشل.
      rethrow;
    }
  }
}