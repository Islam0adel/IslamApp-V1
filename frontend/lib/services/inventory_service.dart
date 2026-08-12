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
  final String baseUrl = ApiConstants.baseUrl;
  final Box _inventoryBox = Hive.box('inventory_box');

  Future<List<InventoryModel>> getInventoryList({
    required String companyCode,
    required String branchCode,
    required String storeCode,
    required String date,
  }) async {
    final String localKey = '${companyCode}_${branchCode}_${storeCode}_$date';
    if (_inventoryBox.containsKey(localKey)) {
      final dynamic raw = _inventoryBox.get(localKey);
      if (raw is List) {
        return raw
            .map((e) => InventoryModel.fromMap(Map<String, dynamic>.from(e)))
            .toList();
      }
    }

    try {
      final response = await http.get(
        Uri.parse(
            '$baseUrl/inventory/list/$companyCode?branch_code=$branchCode&store_code=$storeCode&date=$date'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> decoded = json.decode(response.body);
        final List<InventoryModel> list =
            decoded.map((e) => InventoryModel.fromMap(e)).toList();
        await _inventoryBox.put(localKey, list.map((e) => e.toMap()).toList());
        return list;
      }
    } catch (e) {
      print('❌ فشل جلب الجرد من السيرفر: $e');
    }
    return [];
  }

  Future<Map<String, dynamic>> saveInventory(InventoryModel model) async {
    try {
      // حساب الإجماليات
      double totalWholesale = 0.0;
      double totalRetail = 0.0;
      for (var item in model.items) {
        item.wholesaleValue = item.wholesalePrice * item.quantity;
        item.retailValue = item.retailPrice * item.quantity;
        totalWholesale += item.wholesaleValue;
        totalRetail += item.retailValue;
      }
      model.totalWholesale = totalWholesale;
      model.totalRetail = totalRetail;

      // إضافة serial إذا لم يكن موجوداً
      if (model.serial == null) {
        // حساب serial تلقائياً
        int maxSerial = 0;
        for (var key in _inventoryBox.keys) {
          final raw = _inventoryBox.get(key);
          if (raw is List) {
            for (var item in raw) {
              if (item['company_code'] == model.companyCode &&
                  item['branch_code'] == model.branchCode &&
                  item['store_code'] == model.storeCode &&
                  item['date'] == model.date) {
                int s = int.tryParse(item['serial']?.toString() ?? '0') ?? 0;
                if (s > maxSerial) maxSerial = s;
              }
            }
          }
        }
        model.serial = maxSerial + 1;
      }

      final response = await http.post(
        Uri.parse('$baseUrl/inventory/save'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(model.toMap()),
      );

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        final String docId = result['doc_id'] ?? '';
        model.docId = docId;

        // تحديث Hive
        final String localKey =
            '${model.companyCode}_${model.branchCode}_${model.storeCode}_${model.date}';
        List<Map<String, dynamic>> currentList = [];
        if (_inventoryBox.containsKey(localKey)) {
          final raw = _inventoryBox.get(localKey);
          if (raw is List) {
            currentList = raw
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
        }
        // إزالة أي عنصر له نفس docId ثم إضافة الجديد
        currentList.removeWhere((e) => e['doc_id'] == docId);
        currentList.add(model.toMap());
        await _inventoryBox.put(localKey, currentList);

        // ✅ إضافة الأصناف إلى تكويد الأصناف تلقائياً
        final CodingService codingService = CodingService();
        for (var item in model.items) {
          // التحقق من وجود الصنف
          bool exists = false;
          final itemsKey = '${model.companyCode}_items';
          if (_inventoryBox.containsKey(itemsKey)) {
            final raw = _inventoryBox.get(itemsKey);
            if (raw is List) {
              for (var existing in raw) {
                if (existing['code']?.toString() == item.code) {
                  exists = true;
                  break;
                }
              }
            }
          }
          if (!exists) {
            // إضافة الصنف
            await codingService.saveCode(
              companyCode: model.companyCode,
              category: 'items',
              model: CodingModel(
                code: item.code,
                name: item.name,
                wholesalePrice: item.wholesalePrice,
                sellingPrice: item.retailPrice,
              ),
            );
          }
        }

        return {'success': true, 'doc_id': docId};
      } else {
        return {'success': false, 'error': 'فشل حفظ الجرد في السيرفر'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<bool> deleteInventory(String companyCode, String docId) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/inventory/delete/$companyCode/$docId'),
      );
      if (response.statusCode == 200) {
        // حذف من Hive
        final keys = _inventoryBox.keys.toList();
        for (var key in keys) {
          final raw = _inventoryBox.get(key);
          if (raw is List) {
            final updated = raw.where((e) => e['doc_id'] != docId).toList();
            if (updated.length != raw.length) {
              await _inventoryBox.put(key, updated);
              break;
            }
          }
        }
        return true;
      }
      return false;
    } catch (e) {
      print('خطأ في حذف الجرد: $e');
      return false;
    }
  }

  // جلب جميع سجلات الجرد من السيرفر وتخزينها في Hive
  Future<void> fetchAllInventory(String companyCode) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/inventory/list/$companyCode'),
      );
      if (response.statusCode == 200) {
        List<dynamic> data = jsonDecode(response.body);
        // تخزين كل سجل في مفتاح مركب (company_branch_store_date)
        for (var item in data) {
          String key = "${item['company_code']}_${item['branch_code']}_${item['store_code']}_${item['date']}";
          // قراءة القائمة الحالية لهذا المفتاح
          List<Map<String, dynamic>> currentList = [];
          if (_inventoryBox.containsKey(key)) {
            final raw = _inventoryBox.get(key);
            if (raw is List) {
              currentList = raw.map((e) => Map<String, dynamic>.from(e)).toList();
            }
          }
          // إزالة أي عنصر له نفس doc_id ثم إضافة الجديد
          currentList.removeWhere((e) => e['doc_id'] == item['doc_id']);
          currentList.add(Map<String, dynamic>.from(item));
          await _inventoryBox.put(key, currentList);
        }
        print("✅ تم جلب ${data.length} سجل جرد من السيرفر وتخزينها محلياً");
      } else {
        throw 'فشل جلب الجرد من السيرفر';
      }
    } catch (e) {
      print("❌ فشل جلب الجرد: $e");
      rethrow;
    }
  }

  // ✅ المزامنة التزايدية للجرد (تجلب فقط التغييرات منذ آخر مزامنة)
  // ✅ المزامنة التزايدية للجرد
Future<void> syncChangesFromServer(String companyCode, [String? lastSync]) async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncKey = '${ApiConstants.LAST_SYNC_INVENTORY}$companyCode';
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    if (lastSyncValue == null) {
      print('📥 لا يوجد lastSync للجرد، جاري التحميل الكامل...');
      await fetchAllInventory(companyCode);
      await prefs.setString(lastSyncKey, DateTime.now().toUtc().toIso8601String());
      return;
    }

    try {
      final syncStartedAt = DateTime.now().toUtc();

      final response = await http.get(
        Uri.parse('$baseUrl/inventory/changes/$companyCode?since=$lastSyncValue'),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'فشل مزامنة الجرد. HTTP ${response.statusCode}: ${response.body}',
        );
      }

      final List<dynamic> changes = jsonDecode(response.body);

      for (final item in changes) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);
        final action = map['action']?.toString() ?? 'update';
        final docId = map['doc_id']?.toString();

        if (docId == null || docId.isEmpty) {
          throw Exception('تحديث جرد بدون doc_id');
        }

        final key =
            '${map['company_code']}_${map['branch_code']}_${map['store_code']}_${map['date']}';

        List<Map<String, dynamic>> list = [];
        if (_inventoryBox.containsKey(key)) {
          final raw = _inventoryBox.get(key);
          if (raw is List) {
            list = raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
          }
        }

        list.removeWhere((e) => e['doc_id']?.toString() == docId);

        if (action != 'delete') {
          map.remove('action');
          list.add(map);
        }

        if (list.isEmpty) {
          await _inventoryBox.delete(key);
        } else {
          await _inventoryBox.put(key, list);
        }
      }

      await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
      print('✅ تمت مزامنة ${changes.length} تحديث للجرد');
    } catch (e) {
      print('❌ فشل مزامنة الجرد: $e');
      // لا نغير lastSync عند الفشل.
      rethrow;
    }
  }
}