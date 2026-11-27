// frontend/lib/services/inventory_service.dart
import 'cache_partitions.dart';

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/inventory_model.dart';
import '../core/constants.dart';
import '../services/coding_service.dart';
import '../models/coding_model.dart';
import 'auth_http.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';
import 'staged_changes.dart';
import 'sync_read_access.dart';

// خدمة المخزون: تجلب بيانات المخزون وتخزنها محليًا وتزامنها مع الخادم
class InventoryService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;

  // ============================================================
  // Hive
  // ============================================================

  // يعيد صندوق المخزون المحلي
  Box get _inventoryBox => CachePartitions.box('inventory_box');

  // ============================================================
  // 1. جلب قائمة الجرد
  //
  // Hive أولاً.
  // لو غير موجود محلياً نطلب من السيرفر.
  // ============================================================

  // يجلب قائمة المخزون من التخزين المحلي
  Future<List<InventoryModel>> getInventoryList({
    required String companyCode,
    required String branchCode,
    required String storeCode,
    required String date,
  }) async {
    return CachePartitions.run(() async {
      final String localKey = '${companyCode}_${branchCode}_${storeCode}_$date';

      // ----------------------------------------------------------
      // Hive
      // ----------------------------------------------------------

      if (_inventoryBox.containsKey(localKey)) {
        final dynamic raw = _inventoryBox.get(localKey);

        if (raw is List) {
          final List<InventoryModel> result = [];

          for (final item in raw) {
            if (item is! Map) {
              continue;
            }

            final map = Map<String, dynamic>.from(item);

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
        final response = await AuthHttp.get(
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

        final List<dynamic> decoded = jsonDecode(response.body);

        final List<Map<String, dynamic>> cleanList = [];

        for (final item in decoded) {
          if (item is! Map) {
            continue;
          }

          final map = Map<String, dynamic>.from(item);

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
              (e) => InventoryModel.fromMap(e),
            )
            .toList();
      } catch (e) {
        print(
          '❌ فشل جلب الجرد من السيرفر: $e',
        );

        return [];
      }
    });
  }

  // ============================================================
  // 2. حفظ / تحديث الجرد
  // ============================================================

  // يحفظ حركة مخزون جديدة أو معدّلة
  Future<Map<String, dynamic>> saveInventory(
    InventoryModel model,
  ) async {
    return CachePartitions.run(() async {
      try {
        // --------------------------------------------------------
        // حساب الإجماليات
        // --------------------------------------------------------

        double totalWholesale = 0.0;
        double totalRetail = 0.0;

        for (final item in model.items) {
          item.wholesaleValue = item.wholesalePrice * item.quantity;

          item.retailValue = item.retailPrice * item.quantity;

          totalWholesale += item.wholesaleValue;

          totalRetail += item.retailValue;
        }

        model.totalWholesale = totalWholesale;

        model.totalRetail = totalRetail;

        // --------------------------------------------------------
        // حساب Serial محليًا لو غير موجود
        // --------------------------------------------------------

        if (model.serial == null) {
          int maxSerial = 0;

          for (final key in _inventoryBox.keys) {
            final dynamic raw = _inventoryBox.get(key);

            if (raw is List) {
              for (final rawItem in raw) {
                if (rawItem is! Map) {
                  continue;
                }

                final item = Map<String, dynamic>.from(
                  rawItem,
                );

                if (item['company_code'] == model.companyCode &&
                    item['branch_code'] == model.branchCode &&
                    item['store_code'] == model.storeCode &&
                    item['date'] == model.date &&
                    item['is_deleted'] != true) {
                  final int s = int.tryParse(
                        item['serial']?.toString() ?? '0',
                      ) ??
                      0;

                  if (s > maxSerial) {
                    maxSerial = s;
                  }
                }
              }
            }
          }

          model.serial = maxSerial + 1;
        }

        // --------------------------------------------------------
        // تحقق ذرّي قبل أي كتابة: كل الأصناف لازم تكون موجودة
        // في كتالوج التكويد (سياسة الصلاحيات: الأسعار من التكويد،
        // ولا تسجيل أصناف من شاشة الجرد بدون حق تكويد).
        // --------------------------------------------------------
        final List<CodingModel> catalogItems =
            await CodingService().getCodingList(
          companyCode: model.companyCode,
          category: 'items',
        );
        final Set<String> catalogCodes =
            catalogItems.map((e) => e.code.toString()).toSet();
        final List<String> missingCodes = model.items
            .map((e) => e.code.toString())
            .where((c) => !catalogCodes.contains(c))
            .toSet()
            .toList();
        // صنف جديد كلياً يُقبل بسعر مدخل فقط ممن يملك حق التكلفة
        // مع حق التكويد معاً (مطابقة لقاعدة الخادم): من لا يرى سعر
        // الجملة حقله مخفي، فيسجّل الصنف أولاً من شاشة التكويد.
        if (missingCodes.isNotEmpty &&
            !(PermissionsService().canAddCodingItem &&
                PermissionsService().canViewCostPrices)) {
          return {
            'success': false,
            'error': 'الأصناف التالية غير موجودة في التكويد: '
                '${missingCodes.join("، ")}. سجّلها أولاً من شاشة '
                'التكويد، ثم أعد إدخال الإذن.',
          };
        }

        // --------------------------------------------------------
        // إرسال للسيرفر
        // --------------------------------------------------------

        final response = await AuthHttp.post(
          Uri.parse(
            '$baseUrl/inventory/save',
          ),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode(
            model.toMap(),
          ),
        );

        if (response.statusCode != 200) {
          return {
            'success': false,
            'error': 'فشل حفظ الجرد في السيرفر '
                'HTTP ${response.statusCode}',
          };
        }

        final Map<String, dynamic> result = jsonDecode(response.body);

        final String docId = result['doc_id']?.toString() ?? '';

        if (docId.isEmpty) {
          return {
            'success': false,
            'error': 'السيرفر لم يرجع doc_id',
          };
        }

        model.docId = docId;

        // --------------------------------------------------------
        // تحديث Hive
        // --------------------------------------------------------

        final String newKey = '${model.companyCode}_'
            '${model.branchCode}_'
            '${model.storeCode}_'
            '${model.date}';

        // ========================================================
        // الخطوة 1: حذف النسخة القديمة من جميع المفاتيح
        // ========================================================

        final keys = _inventoryBox.keys.toList();

        for (final oldKey in keys) {
          final raw = _inventoryBox.get(oldKey);

          if (raw is! List) {
            continue;
          }

          final List<Map<String, dynamic>> updatedList = [];
          bool found = false;

          for (final value in raw) {
            if (value is! Map) {
              continue;
            }

            final map = Map<String, dynamic>.from(value);

            if (map.isEmpty) {
              continue;
            }

            if (map['doc_id']?.toString() == docId) {
              found = true;
              continue;
            }

            if (map['is_deleted'] == true) {
              continue;
            }

            updatedList.add(map);
          }

          if (!found) {
            continue;
          }

          if (updatedList.isEmpty) {
            await _inventoryBox.delete(oldKey);
          } else {
            await _inventoryBox.put(oldKey, updatedList);
          }
        }

        // ========================================================
        // الخطوة 2: قراءة المفتاح الجديد
        // ========================================================

        List<Map<String, dynamic>> currentList = [];

        final raw = _inventoryBox.get(newKey);

        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }

        // ========================================================
        // الخطوة 3: تجهيز السجل الجديد
        // ========================================================

        final Map<String, dynamic> localItem =
            Map<String, dynamic>.from(model.toMap());

        localItem['doc_id'] = docId;
        localItem['is_deleted'] = false;

        currentList.removeWhere(
          (e) => e['doc_id']?.toString() == docId,
        );

        currentList.add(localItem);

        await _inventoryBox.put(newKey, currentList);

        // ========================================================
        // إضافة الأصناف الجديدة للتكويد
        //
        // تصحيح خطأ كان موجود:
        // كان يتم البحث في inventoryBox
        // والصحيح codingBox يتم التعامل معه من CodingService.
        // ========================================================

        final CodingService codingService = CodingService();

        // لا تسجيل أصناف جديدة من شاشة الجرد إلا بحق التكويد
        // الفعلي. بدون الحق لا نداء جانبي أصلاً، والتحقق المسبق
        // أعلاه يضمن عدم الحاجة.
        if (!PermissionsService().canAddCodingItem) {
          return {
            'success': true,
            'doc_id': docId,
            'serial': model.serial,
          };
        }

        final Set<String> existingCodes = catalogItems
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

          final result = await codingService.saveCode(
            companyCode: model.companyCode,
            category: 'items',
            model: CodingModel(
              code: item.code,
              name: item.name,
              wholesalePrice: item.wholesalePrice,
              sellingPrice: item.retailPrice,
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
          'action': result['action'] ?? 'update',
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
  // 3. حذف الجرد
  // ============================================================

  // يحذف حركة مخزون
  Future<bool> deleteInventory(
    String companyCode,
    String docId,
  ) async {
    return CachePartitions.run(() async {
      try {
        final response = await AuthHttp.delete(
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

        final List<dynamic> keys = _inventoryBox.keys.toList();

        for (final key in keys) {
          final dynamic raw = _inventoryBox.get(key);

          if (raw is! List) {
            continue;
          }

          final List<Map<String, dynamic>> updated = [];

          bool found = false;

          for (final item in raw) {
            if (item is! Map) {
              continue;
            }

            final map = Map<String, dynamic>.from(
              item,
            );

            if (map['doc_id']?.toString() == docId.toString()) {
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
    });
  }

  // ============================================================
  // 4. Full Sync للجرد
  //
  // يستخدم فقط عند عدم وجود lastSync.
  // ============================================================

  // يجلب كل بيانات المخزون من الخادم
  Future<void> fetchAllInventory(
    String companyCode, {
    bool replace = false,
  }) async {
    return CachePartitions.run(() async {
      final v2Candidate = await _captureV2(companyCode);

      print(
        "📥 الجرد: بدء FULL SYNC "
        "للشركة $companyCode",
      );

      try {
        final response = await AuthHttp.get(
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

        final List<dynamic> data = jsonDecode(response.body);

        final Set<String> replacedKeys = {};
        for (final rawItem in data) {
          if (rawItem is! Map) {
            continue;
          }

          final Map<String, dynamic> item = Map<String, dynamic>.from(
            rawItem,
          );

          // المحذوف لا يدخل Hive
          if (item['is_deleted'] == true) {
            continue;
          }

          final String key = "${item['company_code']}_"
              "${item['branch_code']}_"
              "${item['store_code']}_"
              "${item['date']}";

          List<Map<String, dynamic>> currentList = [];

          if (replace && replacedKeys.add(key)) {
            // epoch reconcile: start this list from the server copy only
          } else if (_inventoryBox.containsKey(
            key,
          )) {
            final raw = _inventoryBox.get(key);

            if (raw is List) {
              currentList = raw
                  .whereType<Map>()
                  .map(
                    (e) => Map<String, dynamic>.from(e),
                  )
                  .where(
                    (e) => e['is_deleted'] != true,
                  )
                  .toList();
            }
          }

          currentList.removeWhere(
            (e) => e['doc_id']?.toString() == item['doc_id']?.toString(),
          );

          item['is_deleted'] = false;

          currentList.add(
            item,
          );

          await _inventoryBox.put(
            key,
            currentList,
          );
        }

        if (replace) {
          final prefix = '${companyCode}_';
          for (final k in _inventoryBox.keys.toList()) {
            if (k.toString().startsWith(prefix) &&
                !replacedKeys.contains(k.toString())) {
              await _inventoryBox.delete(k);
            }
          }
        }

        print(
          "✅ تم FULL SYNC للجرد "
          "(${data.length} سجل)",
        );
        await _commitV2(companyCode, v2Candidate);
      } catch (e) {
        print(
          "❌ فشل FULL SYNC للجرد: $e",
        );

        rethrow;
      }
    });
  }

  // يطبق قائمة تغييرات على المخزون المحلي
  /// Applies a list of inventory changes (update/delete/tombstone) to the cached lists. Shared by the
  /// live incremental sync and by staged batches.
  Future<void> _applyChanges(String companyCode, List<dynamic> changes) async {
    for (final rawItem in changes) {
      if (rawItem is! Map) {
        continue;
      }

      final Map<String, dynamic> map = Map<String, dynamic>.from(
        rawItem,
      );

      final String action = map['action']?.toString() ??
          (map['is_deleted'] == true ? 'delete' : 'update');

      final String? docId = map['doc_id']?.toString();

      if (docId == null || docId.isEmpty) {
        throw Exception(
          'تحديث جرد بدون doc_id',
        );
      }

      // ======================================================
      // الخطوة 1: حذف doc_id من جميع المفاتيح
      //
      // مهم جدًا لو تم تعديل:
      // - التاريخ
      // - الفرع
      // - المخزن
      //
      // لأن المفتاح نفسه ممكن يتغير.
      // ======================================================

      final allKeys = _inventoryBox.keys.toList();

      for (final oldKey in allKeys) {
        final raw = _inventoryBox.get(oldKey);

        if (raw is! List) {
          continue;
        }

        final List<Map<String, dynamic>> updatedList = [];
        bool found = false;

        for (final value in raw) {
          if (value is! Map) {
            continue;
          }

          final mapItem = Map<String, dynamic>.from(value);

          if (mapItem.isEmpty) {
            continue;
          }

          if (mapItem['doc_id']?.toString() == docId) {
            found = true;
            continue;
          }

          if (mapItem['is_deleted'] == true) {
            continue;
          }

          updatedList.add(mapItem);
        }

        if (!found) {
          continue;
        }

        if (updatedList.isEmpty) {
          await _inventoryBox.delete(oldKey);
        } else {
          await _inventoryBox.put(oldKey, updatedList);
        }
      }

      // ======================================================
      // الخطوة 2: لو حذف، توقف هنا
      // ======================================================

      if (action == 'delete' || map['is_deleted'] == true) {
        print(
          "🗑️ حذف جرد [$docId] من Hive",
        );

        continue;
      }

      // ======================================================
      // الخطوة 3: إضافة السجل الجديد في المفتاح الصحيح
      // ======================================================

      final String company = map['company_code']?.toString() ?? companyCode;

      final String branch = map['branch_code']?.toString() ?? '';

      final String store = map['store_code']?.toString() ?? '';

      final String date = map['date']?.toString() ?? '';

      if (company.isEmpty || branch.isEmpty || store.isEmpty || date.isEmpty) {
        print(
          '⚠️ بيانات المفتاح ناقصة للجرد [$docId]',
        );
        continue;
      }

      final String newKey = '${company}_${branch}_${store}_$date';

      List<Map<String, dynamic>> list = [];

      final rawNew = _inventoryBox.get(newKey);

      if (rawNew is List) {
        list = rawNew
            .whereType<Map>()
            .map(
              (e) => Map<String, dynamic>.from(e),
            )
            .where(
              (e) => e['is_deleted'] != true,
            )
            .toList();
      }

      // منع التكرار (مرة أخرى للتأكيد)
      list.removeWhere(
        (e) => e['doc_id']?.toString() == docId,
      );

      map.remove('action');

      map['is_deleted'] = false;

      list.add(map);

      await _inventoryBox.put(
        newKey,
        list,
      );

      print(
        "✅ تم تحديث جرد [$docId] في Hive",
      );
    }
  }

  // ============================================================
  // Staged feed (/inventory/changes-v2) checkpoint + merge
  // ============================================================

  static void Function(String company)? onCheckpointChanged;

  // يعيد مفتاح مؤشر النسخة الثانية للمزامنة
  static String v2CursorKey(String c) =>
      '${ApiConstants.LAST_SYNC_INVENTORY}${c}_v2';

  // يعيد مفتاح نطاق النسخة الثانية للمزامنة
  static String v2ScopeKey(String c) =>
      '${ApiConstants.LAST_SYNC_INVENTORY}${c}_v2scope';

  // يعيد مفتاح عهد النسخة الثانية للمزامنة
  static String v2EpochKey(String c) =>
      '${ApiConstants.LAST_SYNC_INVENTORY}${c}_v2epoch';

  // يلتقط مؤشر المزامنة ونطاقه وعهده قبل الجلب
  Future<({String cursor, String scope, String epoch})?> _captureV2(
      String company) async {
    try {
      final r = await AuthHttp.get(
              Uri.parse('$baseUrl/inventory/changes-v2/$company?cursor=latest'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body);
      if (m is! Map ||
          m['invalid'] == true ||
          m['next_cursor'] is! String ||
          m['scope'] is! String ||
          (m['next_cursor'] as String).isEmpty ||
          (m['scope'] as String).isEmpty) return null;
      return (
        cursor: m['next_cursor'] as String,
        scope: m['scope'] as String,
        epoch: (m['epoch'] ?? '').toString()
      );
    } catch (_) {
      return null;
    }
  }

  // يثبّت المؤشر الملتقط بعد نجاح التطبيق
  Future<void> _commitV2(String company,
      ({String cursor, String scope, String epoch})? cand) async {
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

  // يعيد نقطة تحقق للعمل المرحلي للشركة
  Future<({String cursor, String scope})?> stagedCheckpoint(
      String company) async {
    try {
      final allowed = SyncReadAccess.allows('inventory');
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

  // يحدد هل يحق للمستخدم رؤية التكاليف
  bool _mayCosts() {
    final p = PermissionsService();
    return p.canBypassPermissions ||
        p.hasPermission('التكويد', 'سعر الشراء') ||
        p.hasPermission('المبيعات', 'عرض سعر الجملة') ||
        p.hasPermission('رصيد المخزون', 'عرض سعر الجملة');
  }

  static const _costKeys = ['total_wholesale', 'totalWholesale'];
  static const _itemCostKeys = [
    'wholesalePrice',
    'wholesaleValue',
    'wholesale_price'
  ];

  // يزيل الأسعار التي لا يحق للمستخدم رؤيتها
  /// Removes the pricing the viewer may not hold: inventory wholesale total and every item wholesale price/value.
  void _stripCosts(Map<String, dynamic> m) {
    for (final k in _costKeys) {
      m.remove(k);
    }
    final items = m['items'];
    if (items is List) {
      m['items'] = [
        for (final it in items)
          if (it is Map)
            {
              for (final e in it.entries)
                if (!_itemCostKeys.contains(e.key.toString()))
                  e.key.toString(): e.value
            }
          else
            it
      ];
    }
  }

  // يطبق دفعة مرحلية واحدة من استجابة التغييرات
  /// Applies one /inventory/changes-v2 response fetched by the service worker while the app was
  /// closed. Applied only when it continues exactly from the stored cursor and scope, under the
  /// inventory read right held NOW. Pricing is removed again at merge time when the cost right is
  /// gone. Returns true when applied.
  Future<bool> applyStagedBatch(String company, dynamic decoded,
      {required String fromCursor, required String fromScope}) async {
    try {
      return await CachePartitions.run(() async {
        final epoch = ReadAuthorizationEpoch.value;
        if (!SyncReadAccess.allows('inventory')) return false;
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
        for (final key in _inventoryBox.keys) {
          final raw = _inventoryBox.get(key);
          if (raw is! List) continue;
          for (final v in raw) {
            if (v is Map)
              localStamp[v['doc_id']?.toString() ?? ''] =
                  StagedChanges.stamp(v['updated_at']);
          }
        }
        final scopeBefore = PermissionsService().effectiveScopeSignature();
        final mayCosts = _mayCosts();
        final fresh = <Map<String, dynamic>>[];
        for (final raw in decoded['items'] as List) {
          if (raw is! Map) return false;
          final m = _toMapInv(raw);
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
          if (!SyncReadAccess.allows('inventory') ||
              epoch != ReadAuthorizationEpoch.value) return false;
          await _applyChanges(company, fresh);
        }
        if (!SyncReadAccess.allows('inventory') ||
            PermissionsService().effectiveScopeSignature() != scopeBefore) {
          // Scope (rights, branches, role, policy) moved while writing: take back this batch's rows.
          final written = {
            for (final m in fresh)
              if (m['action'] != 'delete') m['doc_id']?.toString()
          };
          if (written.isNotEmpty) {
            for (final key in _inventoryBox.keys.toList()) {
              final raw = _inventoryBox.get(key);
              if (raw is! List) continue;
              final keep = raw
                  .where((e) =>
                      !(e is Map && written.contains(e['doc_id']?.toString())))
                  .toList();
              if (keep.length == raw.length) continue;
              if (keep.isEmpty) {
                await _inventoryBox.delete(key);
              } else {
                await _inventoryBox.put(key, keep);
              }
            }
          }
          return false;
        }
        await prefs.setString(
            v2CursorKey(company), decoded['next_cursor'] as String);
        try {
          onCheckpointChanged?.call(company);
        } catch (_) {}
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  // يحوّل القيمة إلى خريطة المخزون
  Map<String, dynamic> _toMapInv(dynamic v) => v is Map
      ? Map<String, dynamic>.from(v.map((k, x) => MapEntry(k.toString(), x)))
      : <String, dynamic>{};

  // ============================================================
  // 5. المزامنة التزايدية للجرد
  //
  // جهاز قديم:
  // /changes فقط
  // ============================================================

  // يزامن تغييرات المخزون من الخادم
  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    return CachePartitions.run(() async {
      final prefs = await CachePartitions.preferences();

      final String lastSyncKey =
          '${ApiConstants.LAST_SYNC_INVENTORY}$companyCode';

      final String? lastSyncValue = lastSync ??
          prefs.getString(
            lastSyncKey,
          );

      // ==========================================================
      // جهاز جديد
      // ==========================================================

      if (lastSyncValue == null || lastSyncValue.isEmpty) {
        print(
          "📥 الجرد: لا يوجد lastSync "
          "→ FULL SYNC",
        );

        await fetchAllInventory(
          companyCode,
        );

        await prefs.setString(
          lastSyncKey,
          DateTime.now().toUtc().toIso8601String(),
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
        final v2Candidate = await _captureV2(companyCode);
        final String? storedEpoch = prefs.getString(v2EpochKey(companyCode));
        if (v2Candidate != null &&
            storedEpoch != null &&
            storedEpoch != v2Candidate.epoch) {
          print('📥 الجرد: feed epoch changed → FULL SYNC');
          final startedAt = DateTime.now().toUtc();
          await fetchAllInventory(companyCode, replace: true);
          await prefs.setString(lastSyncKey, startedAt.toIso8601String());
          return;
        }
        final DateTime syncStartedAt = DateTime.now().toUtc();

        final DateTime sinceDt = DateTime.parse(
          lastSyncValue,
        ).toUtc();

        final String effectiveSince = sinceDt.toIso8601String();

        final response = await AuthHttp.get(
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

        final List<dynamic> changes = jsonDecode(response.body);

        // --------------------------------------------------------
        // تطبيق التغييرات
        // --------------------------------------------------------

        await _applyChanges(companyCode, changes);

        // --------------------------------------------------------
        // حفظ lastSync بعد نجاح كل التغييرات
        // --------------------------------------------------------

        await prefs.setString(
          lastSyncKey,
          syncStartedAt.toIso8601String(),
        );
        await _commitV2(companyCode, v2Candidate);

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
    });
  }
}
