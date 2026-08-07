// lib/services/reset_data_service.dart
import 'package:hive_flutter/hive_flutter.dart';
import 'daily_service.dart';
import 'coding_service.dart';
import 'inventory_service.dart';
import 'supplier_service.dart';

class ResetDataService {
  final DailyService _dailyService = DailyService();
  final CodingService _codingService = CodingService();
  final InventoryService _inventoryService = InventoryService();
  final SupplierService _supplierService = SupplierService();

  // إعادة تعيين اليوميات والخزائن
  Future<void> resetDailyTransactions(String companyCode) async {
    final box = Hive.box('daily_transactions_box');
    await box.clear();
    await _dailyService.fetchAllTransactions(companyCode);
  }

  // إعادة تعيين التكويدات
  Future<void> resetCoding(String companyCode) async {
    final box = Hive.box('coding_box');
    await box.clear();
    await _codingService.fetchAllCoding(companyCode);
  }

  // إعادة تعيين الجرد
  Future<void> resetInventory(String companyCode) async {
    final box = Hive.box('inventory_box');
    await box.clear();
    await _inventoryService.fetchAllInventory(companyCode);
  }

  // إعادة تعيين الموردين
  Future<void> resetSupplier(String companyCode) async {
    final box = Hive.box('supplier_box');
    await box.clear();
    await _supplierService.fetchAllSupplier(companyCode);
  }

  // إعادة تعيين الكل
  Future<void> resetAll(String companyCode) async {
    await resetDailyTransactions(companyCode);
    await resetCoding(companyCode);
    await resetInventory(companyCode);
    await resetSupplier(companyCode);
  }
}