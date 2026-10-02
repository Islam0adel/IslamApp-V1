// lib/services/stock_balance_service.dart

import 'package:hive_flutter/hive_flutter.dart';
import '../models/inventory_model.dart';

class StockBalanceService {
  static Future<List<Map<String, dynamic>>> calculateBalances({
    required String companyCode,
    required String branchCode,
    required String storeCode,
    required DateTime toDate,
  }) async {
    final inventoryBox = Hive.box('inventory_box');
    final supplierBox = Hive.box('supplier_box');
    final codingBox = Hive.box('coding_box');

    final selectedDay = DateTime(toDate.year, toDate.month, toDate.day);

    // ============================================================
    // 1) تحميل أصناف التكويد (كـ Fallback فقط)
    // ============================================================
    final Map<String, Map<String, dynamic>> codingItems = {};

    final rawItems = codingBox.get('${companyCode}_items');
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        if (_toBool(item['is_deleted']) == true) continue;

        final code = item['code']?.toString() ?? '';
        if (code.isNotEmpty) codingItems[code] = item;
      }
    }

    // ============================================================
    // 2) جمع الجردات - Dedup حسب doc_id
    // ============================================================
    final Map<String, InventoryModel> uniqueInventories = {};

    for (final key in inventoryBox.keys) {
      final raw = inventoryBox.get(key);
      if (raw is! List) continue;

      for (final value in raw) {
        if (value is! Map) continue;

        final item = Map<String, dynamic>.from(value);

        if (_toBool(item['is_deleted']) == true) continue;
        if (item['company_code']?.toString() != companyCode) continue;
        if (item['branch_code']?.toString() != branchCode) continue;
        if (item['store_code']?.toString() != storeCode) continue;

        final date = DateTime.tryParse(item['date']?.toString() ?? '');
        if (date == null) continue;

        final day = DateTime(date.year, date.month, date.day);
        if (day.isAfter(selectedDay)) continue;

        try {
          final inv = InventoryModel.fromMap(item);
          final docId = inv.docId ?? '';
          if (docId.isEmpty) continue;

          final existing = uniqueInventories[docId];
          if (existing == null ||
              inv.updatedAt.isAfter(existing.updatedAt)) {
            uniqueInventories[docId] = inv;
          }
        } catch (_) {}
      }
    }

    final dedupedInventories = uniqueInventories.values.toList();
    dedupedInventories.sort((a, b) {
      final dateCompare = a.date.compareTo(b.date);
      if (dateCompare != 0) return dateCompare;

      final aPriority = a.inventoryType == 'general' ? 2 : 1;
      final bPriority = b.inventoryType == 'general' ? 2 : 1;
      if (aPriority != bPriority) return aPriority.compareTo(bPriority);

      final updatedCompare = a.updatedAt.compareTo(b.updatedAt);
      if (updatedCompare != 0) return updatedCompare;

      return (a.serial ?? 0).compareTo(b.serial ?? 0);
    });

    // ============================================================
    // 3) جمع المشتريات - Dedup حسب doc_id
    // ============================================================
    final Map<String, Map<String, dynamic>> uniquePurchases = {};

    for (final key in supplierBox.keys) {
      final raw = supplierBox.get(key);
      if (raw is! List) continue;

      for (final value in raw) {
        if (value is! Map) continue;

        final purchase = Map<String, dynamic>.from(value);

        if (_toBool(purchase['is_deleted']) == true) continue;
        if (purchase['company_code']?.toString() != companyCode) continue;
        if (purchase['branch_code']?.toString() != branchCode) continue;
        if (purchase['store_code']?.toString() != storeCode) continue;
        if (_toBool(purchase['is_add_to_store']) != true) continue;

        final date = DateTime.tryParse(purchase['date']?.toString() ?? '');
        if (date == null) continue;

        final day = DateTime(date.year, date.month, date.day);
        if (day.isAfter(selectedDay)) continue;

        final docId = purchase['doc_id']?.toString() ?? '';
        if (docId.isEmpty) continue;

        final existing = uniquePurchases[docId];
        if (existing == null) {
          uniquePurchases[docId] = purchase;
        } else {
          final existingUpd = _parseDate(existing['updated_at']);
          final currentUpd = _parseDate(purchase['updated_at']);
          if (currentUpd.isAfter(existingUpd)) {
            uniquePurchases[docId] = purchase;
          }
        }
      }
    }

    final purchases = uniquePurchases.values.toList();
    purchases.sort((a, b) {
      final dateCompare = (a['date']?.toString() ?? '')
          .compareTo(b['date']?.toString() ?? '');
      if (dateCompare != 0) return dateCompare;

      final serialA = int.tryParse(a['serial']?.toString() ?? '0') ?? 0;
      final serialB = int.tryParse(b['serial']?.toString() ?? '0') ?? 0;
      if (serialA != serialB) return serialA.compareTo(serialB);

      return _parseDate(a['updated_at'])
          .compareTo(_parseDate(b['updated_at']));
    });

    // ============================================================
    // 4) بناء الـ Timeline
    // ============================================================
    final List<_StockEvent> events = [];

    for (final inventory in dedupedInventories) {
      events.add(_StockEvent(
        date: DateTime.parse(inventory.date),
        priority: inventory.inventoryType == 'general' ? 2 : 1,
        type: 'inventory',
        data: inventory,
      ));
    }

    for (final purchase in purchases) {
      events.add(_StockEvent(
        date: DateTime.parse(purchase['date'].toString()),
        priority: 0,
        type: 'purchase',
        data: purchase,
      ));
    }

    events.sort((a, b) {
      final dateCompare = a.date.compareTo(b.date);
      if (dateCompare != 0) return dateCompare;
      return a.priority.compareTo(b.priority);
    });

    // ============================================================
    // 5) تطبيق الأحداث بالترتيب مع تتبّع الأسعار التاريخية
    // ============================================================
    final Map<String, double> balances = {};

    // الأسعار التاريخية - آخر سعر معروف لكل صنف حتى تاريخ الحساب
    final Map<String, double> wholesalePrices = {};
    final Map<String, double> retailPrices = {};

    for (final event in events) {
      // ----- جرد -----
      if (event.type == 'inventory') {
        final inventory = event.data as InventoryModel;

        if (inventory.inventoryType == 'general') {
          // الجرد العام يعيد ضبط الكميات والأسعار معاً
          balances.clear();
          wholesalePrices.clear();
          retailPrices.clear();
        }

        for (final item in inventory.items) {
          final code = item.code;
          if (code.isEmpty) continue;

          // تحديث الكمية
          balances[code] = (balances[code] ?? 0.0) + item.quantity;

          // تحديث الأسعار (فقط لو موجودة في الجرد، أي > 0)
          if (item.wholesalePrice > 0) {
            wholesalePrices[code] = item.wholesalePrice;
          }
          if (item.retailPrice > 0) {
            retailPrices[code] = item.retailPrice;
          }
        }
        continue;
      }

      // ----- مشتريات -----
      final purchase = event.data as Map<String, dynamic>;

      final isReturn =
          purchase['payment_method']?.toString() == 'مرتجع' ||
              (_toDouble(purchase['total_amount']) < 0);

      final rawItems = purchase['items'];
      if (rawItems is! List) continue;

      for (final rawProduct in rawItems) {
        if (rawProduct is! Map) continue;

        final product = Map<String, dynamic>.from(rawProduct);
        final code = product['code']?.toString() ?? '';
        if (code.isEmpty) continue;

        double qty = _toDouble(product['quantity']);
        final price = _toDouble(product['price']);

        if (isReturn) {
          balances[code] = (balances[code] ?? 0.0) - qty.abs();
        } else {
          balances[code] = (balances[code] ?? 0.0) + qty;

          // سعر الشراء من فاتورة المورد يحدّث سعر الجملة فقط
          // (لا يلمس سعر البيع، لأن البيع يأتي من الجرد)
          if (price > 0) {
            wholesalePrices[code] = price;
          }
        }
      }
    }

    // ============================================================
    // 6) حذف الأرصدة الصفرية
    // ============================================================
    balances.removeWhere((code, quantity) => quantity == 0);

    // ============================================================
    // 7) تجهيز البيانات مع الأسعار التاريخية
    // ============================================================
    final List<Map<String, dynamic>> itemsData = [];

    balances.forEach((code, quantity) {
      // Fallback: التكويد الحالي (لو لا يوجد سعر تاريخي)
      final codingItem = codingItems[code] ?? {};

      // سعر الجملة التاريخي، أو من التكويد
      final wholesalePrice =
          wholesalePrices[code] ??
              _toDouble(
                codingItem['wholesale_price'] ??
                    codingItem['wholesalePrice'] ??
                    0,
              );

      // سعر البيع التاريخي، أو من التكويد
      final sellingPrice =
          retailPrices[code] ??
              _toDouble(
                codingItem['selling_price'] ??
                    codingItem['sellingPrice'] ??
                    0,
              );

      itemsData.add({
        'code': code,
        'name': codingItem['name'] ?? 'غير معروف',
        'quantity': quantity,
        'wholesalePrice': wholesalePrice,
        'sellingPrice': sellingPrice,
        'totalWholesale': quantity * wholesalePrice,
        'totalRetail': quantity * sellingPrice,
        // علامة اختيارية: هل السعر تاريخي أم من التكويد الحالي
        'priceSource': wholesalePrices.containsKey(code) ||
                retailPrices.containsKey(code)
            ? 'historical'
            : 'coding',
      });
    });

    itemsData.sort(
      (a, b) => a['code'].toString().compareTo(b['code'].toString()),
    );

    return itemsData;
  }

  static Future<double> calculateTotalWholesale({
    required String companyCode,
    required String branchCode,
    required String storeCode,
    required DateTime toDate,
  }) async {
    final items = await calculateBalances(
      companyCode: companyCode,
      branchCode: branchCode,
      storeCode: storeCode,
      toDate: toDate,
    );

    double total = 0.0;
    for (final item in items) {
      total += (item['totalWholesale'] as double);
    }
    return total;
  }

  // ============================================================
  // Helpers
  // ============================================================

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '0') ?? 0.0;
  }

  static bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is String) {
      return value.toLowerCase() == 'true' || value == '1';
    }
    if (value is num) return value != 0;
    return false;
  }

  static DateTime _parseDate(dynamic value) {
    if (value == null) return DateTime.fromMillisecondsSinceEpoch(0);
    try {
      return DateTime.parse(value.toString());
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}

// ============================================================
// حدث داخلي
// ============================================================

class _StockEvent {
  final DateTime date;
  final int priority;
  final String type;
  final dynamic data;

  const _StockEvent({
    required this.date,
    required this.priority,
    required this.type,
    required this.data,
  });
}