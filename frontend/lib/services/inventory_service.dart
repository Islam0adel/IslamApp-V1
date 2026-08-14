// lib/services/inventory_service.dart

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory_model.dart';
import '../core/constants.dart';
import '../services/coding_service.dart';
import '../models/coding_model.dart';


class InventoryService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;


  // ============================================================
  // Hive
  // ============================================================

  final Box _inventoryBox =
      Hive.box('inventory_box');


  // ============================================================
  // 1. جلب قائمة الجرد
  //
  // Hive أولاً.
  // لو غير موجود محلياً نطلب من السيرفر.
  // ============================================================

  Future<List<InventoryModel>> getInventoryList({
    required String companyCode,
    required String branchCode,
    required String storeCode,
    required String date,
  }) async {
    final String localKey =
        '${companyCode}_${branchCode}_${storeCode}_$date';


    // ----------------------------------------------------------
    // Hive
    // ----------------------------------------------------------

    if (_inventoryBox.containsKey(localKey)) {
      final dynamic raw =
          _inventoryBox.get(localKey);

      if (raw is List) {
        final List<InventoryModel> result = [];

        for (final item in raw) {
          if (item is! Map) {
            continue;
          }

          final map =
              Map<String, dynamic>.from(item);

          // المحذوف لا يظهر
          if (map['is_deleted'] == true) {
            continue;
          }

          try {
            result.add(
              InventoryModel.fromMap(map),
            );
          } catch (e) {
            print(
              '⚠️ خطأ في تحويل سجل الجرد: $e',
            );
          }
        }

        return result;
      }
    }


    // ----------------------------------------------------------
    // Server
    // ----------------------------------------------------------

    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/inventory/list/'
          '$companyCode'
          '?branch_code=$branchCode'
          '&store_code=$storeCode'
          '&date=$date',
        ),
      );


      if (response.statusCode != 200) {
        print(
          '❌ خطأ من السيرفر في الجرد: '
          '${response.statusCode}',
        );

        return [];
      }


      final List<dynamic> decoded =
          jsonDecode(response.body);


      final List<Map<String, dynamic>>
          cleanList = [];


      for (final item in decoded) {
        if (item is! Map) {
          continue;
        }

        final map =
            Map<String, dynamic>.from(item);

        if (map['is_deleted'] == true) {
          continue;
        }

        map['is_deleted'] = false;

        cleanList.add(map);
      }


      await _inventoryBox.put(
        localKey,
        cleanList,
      );


      return cleanList
          .map(
            (e) =>
                InventoryModel.fromMap(e),
          )
          .toList();

    } catch (e) {
      print(
        '❌ فشل جلب الجرد من السيرفر: $e',
      );

      return [];
    }
  }


  // ============================================================
  // 2. حفظ / تحديث الجرد
  // ============================================================

  Future<Map<String, dynamic>> saveInventory(
    InventoryModel model,
  ) async {
    try {
      // --------------------------------------------------------
      // حساب الإجماليات
      // --------------------------------------------------------

      double totalWholesale = 0.0;
      double totalRetail = 0.0;


      for (final item in model.items) {
        item.wholesaleValue =
            item.wholesalePrice *
                item.quantity;

        item.retailValue =
            item.retailPrice *
                item.quantity;

        totalWholesale +=
            item.wholesaleValue;

        totalRetail +=
            item.retailValue;
      }


      model.totalWholesale =
          totalWholesale;

      model.totalRetail =
          totalRetail;


      // --------------------------------------------------------
      // حساب Serial محليًا لو غير موجود
      // --------------------------------------------------------

      if (model.serial == null) {
        int maxSerial = 0;


        for (final key in _inventoryBox.keys) {
          final dynamic raw =
              _inventoryBox.get(key);


          if (raw is List) {
            for (final rawItem in raw) {
              if (rawItem is! Map) {
                continue;
              }


              final item =
                  Map<String, dynamic>.from(
                rawItem,
              );


              if (item['company_code'] ==
                      model.companyCode &&
                  item['branch_code'] ==
                      model.branchCode &&
                  item['store_code'] ==
                      model.storeCode &&
                  item['date'] ==
                      model.date &&
                  item['is_deleted'] != true) {
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
        }


        model.serial =
            maxSerial + 1;
      }


      // --------------------------------------------------------
      // إرسال للسيرفر
      // --------------------------------------------------------

      final response = await http.post(
        Uri.parse(
          '$baseUrl/inventory/save',
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
              'فشل حفظ الجرد في السيرفر '
              'HTTP ${response.statusCode}',
        };
      }


      final Map<String, dynamic> result =
          jsonDecode(response.body);


      final String docId =
          result['doc_id']?.toString() ??
              '';


      if (docId.isEmpty) {
        return {
          'success': false,
          'error':
              'السيرفر لم يرجع doc_id',
        };
      }


      model.docId = docId;


      // --------------------------------------------------------
      // تحديث Hive
      // --------------------------------------------------------

      final String localKey =
          '${model.companyCode}_'
          '${model.branchCode}_'
          '${model.storeCode}_'
          '${model.date}';


      List<Map<String, dynamic>>
          currentList = [];


      if (_inventoryBox.containsKey(
        localKey,
      )) {
        final raw =
            _inventoryBox.get(localKey);


        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map(
                (e) =>
                    Map<String, dynamic>
                        .from(e),
              )
              .where(
                (e) =>
                    e['is_deleted'] !=
                    true,
              )
              .toList();
        }
      }


      final Map<String, dynamic>
          localItem =
          Map<String, dynamic>.from(
        model.toMap(),
      );


      localItem['doc_id'] =
          docId;

      localItem['is_deleted'] =
          false;


      // إزالة النسخة القديمة
      currentList.removeWhere(
        (e) =>
            e['doc_id']?.toString() ==
            docId,
      );


      // إضافة النسخة الجديدة
      currentList.add(
        localItem,
      );


      await _inventoryBox.put(
        localKey,
        currentList,
      );


      // ========================================================
      // إضافة الأصناف الجديدة للتكويد
      //
      // تصحيح خطأ كان موجود:
      // كان يتم البحث في inventoryBox
      // والصحيح codingBox يتم التعامل معه من CodingService.
      // ========================================================

      final CodingService codingService =
          CodingService();


      // نحتاج قراءة coding list عبر CodingService
      final List<CodingModel> existingItems =
          await codingService.getCodingList(
        companyCode:
            model.companyCode,
        category:
            'items',
      );


      final Set<String> existingCodes =
          existingItems
              .map(
                (e) => e.code.toString(),
              )
              .toSet();


      for (final item in model.items) {
        if (existingCodes.contains(
          item.code.toString(),
        )) {
          continue;
        }


        final result =
            await codingService.saveCode(
          companyCode:
              model.companyCode,

          category:
              'items',

          model: CodingModel(
            code: item.code,
            name: item.name,
            wholesalePrice:
                item.wholesalePrice,
            sellingPrice:
                item.retailPrice,
          ),
        );


        if (result['success'] == true) {
          existingCodes.add(
            item.code.toString(),
          );
        }
      }


      return {
        'success': true,
        'doc_id': docId,
        'action':
            result['action'] ??
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
  // 3. حذف الجرد
  // ============================================================

  Future<bool> deleteInventory(
    String companyCode,
    String docId,
  ) async {
    try {
      final response = await http.delete(
        Uri.parse(
          '$baseUrl/inventory/delete/'
          '$companyCode/$docId',
        ),
      );


      if (response.statusCode != 200) {
        print(
          '❌ فشل حذف الجرد من السيرفر: '
          '${response.statusCode}',
        );

        return false;
      }


      // --------------------------------------------------------
      // Soft Delete نجح في السيرفر
      // نحذفه محليًا فورًا
      // --------------------------------------------------------

      final List<dynamic> keys =
          _inventoryBox.keys.toList();


      for (final key in keys) {
        final dynamic raw =
            _inventoryBox.get(key);


        if (raw is! List) {
          continue;
        }


        final List<Map<String, dynamic>>
            updated = [];


        bool found = false;


        for (final item in raw) {
          if (item is! Map) {
            continue;
          }


          final map =
              Map<String, dynamic>.from(
            item,
          );


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
          await _inventoryBox.delete(
            key,
          );
        } else {
          await _inventoryBox.put(
            key,
            updated,
          );
        }


        break;
      }


      return true;

    } catch (e) {
      print(
        '❌ خطأ في حذف الجرد: $e',
      );

      return false;
    }
  }


  // ============================================================
  // 4. Full Sync للجرد
  //
  // يستخدم فقط عند عدم وجود lastSync.
  // ============================================================

  Future<void> fetchAllInventory(
    String companyCode,
  ) async {
    print(
      "📥 الجرد: بدء FULL SYNC "
      "للشركة $companyCode",
    );


    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/inventory/list/'
          '$companyCode',
        ),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'فشل جلب الجرد من السيرفر '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      final List<dynamic> data =
          jsonDecode(response.body);


      for (final rawItem in data) {
        if (rawItem is! Map) {
          continue;
        }


        final Map<String, dynamic>
            item =
            Map<String, dynamic>.from(
          rawItem,
        );


        // المحذوف لا يدخل Hive
        if (item['is_deleted'] == true) {
          continue;
        }


        final String key =
            "${item['company_code']}_"
            "${item['branch_code']}_"
            "${item['store_code']}_"
            "${item['date']}";


        List<Map<String, dynamic>>
            currentList = [];


        if (_inventoryBox.containsKey(
          key,
        )) {
          final raw =
              _inventoryBox.get(key);


          if (raw is List) {
            currentList = raw
                .whereType<Map>()
                .map(
                  (e) =>
                      Map<String, dynamic>
                          .from(e),
                )
                .where(
                  (e) =>
                      e['is_deleted'] !=
                      true,
                )
                .toList();
          }
        }


        currentList.removeWhere(
          (e) =>
              e['doc_id']?.toString() ==
              item['doc_id']
                  ?.toString(),
        );


        item['is_deleted'] =
            false;


        currentList.add(
          item,
        );


        await _inventoryBox.put(
          key,
          currentList,
        );
      }


      print(
        "✅ تم FULL SYNC للجرد "
        "(${data.length} سجل)",
      );

    } catch (e) {
      print(
        "❌ فشل FULL SYNC للجرد: $e",
      );

      rethrow;
    }
  }


  // ============================================================
  // 5. المزامنة التزايدية للجرد
  //
  // جهاز قديم:
  // /changes فقط
  // ============================================================

  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs =
        await SharedPreferences.getInstance();


    final String lastSyncKey =
        '${ApiConstants.LAST_SYNC_INVENTORY}$companyCode';


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
        "📥 الجرد: لا يوجد lastSync "
        "→ FULL SYNC",
      );


      await fetchAllInventory(
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
      "📡 الجرد: INCREMENTAL SYNC "
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


      final response = await http.get(
        Uri.parse(
          '$baseUrl/inventory/changes/'
          '$companyCode'
          '?since=$effectiveSince',
        ),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'فشل مزامنة الجرد. '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      final List<dynamic> changes =
          jsonDecode(response.body);


      // --------------------------------------------------------
      // تطبيق التغييرات
      // --------------------------------------------------------

      for (final rawItem in changes) {
        if (rawItem is! Map) {
          continue;
        }


        final Map<String, dynamic>
            map =
            Map<String, dynamic>.from(
          rawItem,
        );


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
            'تحديث جرد بدون doc_id',
          );
        }


        final String key =
            '${map['company_code']}_'
            '${map['branch_code']}_'
            '${map['store_code']}_'
            '${map['date']}';


        List<Map<String, dynamic>>
            list = [];


        if (_inventoryBox.containsKey(
          key,
        )) {
          final raw =
              _inventoryBox.get(key);


          if (raw is List) {
            list = raw
                .whereType<Map>()
                .map(
                  (e) =>
                      Map<String, dynamic>
                          .from(e),
                )
                .where(
                  (e) =>
                      e['is_deleted'] !=
                      true,
                )
                .toList();
          }
        }


        // ------------------------------------------------------
        // إزالة النسخة القديمة أولًا
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
            "🗑️ حذف جرد [$docId] من Hive",
          );

          if (list.isEmpty) {
            await _inventoryBox.delete(
              key,
            );
          } else {
            await _inventoryBox.put(
              key,
              list,
            );
          }


          continue;
        }


        // ------------------------------------------------------
        // INSERT / UPDATE
        // ------------------------------------------------------

        map.remove('action');

        map['is_deleted'] =
            false;


        list.add(
          map,
        );


        if (list.isEmpty) {
          await _inventoryBox.delete(
            key,
          );
        } else {
          await _inventoryBox.put(
            key,
            list,
          );
        }


        print(
          "✅ تم تحديث جرد [$docId] في Hive",
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
        '✅ تمت مزامنة '
        '${changes.length} تحديث للجرد',
      );

    } catch (e) {
      print(
        '❌ فشل مزامنة الجرد: $e',
      );

      // لا نغير lastSync عند الفشل
      rethrow;
    }
  }
}