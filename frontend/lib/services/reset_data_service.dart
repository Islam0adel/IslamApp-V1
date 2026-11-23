import 'cache_partitions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'journal_cache.dart';
import 'treasury_transfer_service.dart';
// lib/services/reset_data_service.dart
import 'package:hive_flutter/hive_flutter.dart';

import 'daily_service.dart';
import 'coding_service.dart';
import 'inventory_service.dart';
import 'supplier_service.dart';
import 'hr_service.dart';
import 'employee_service.dart';

class ResetDataService {
  final DailyService _dailyService = DailyService();
  final CodingService _codingService = CodingService();
  final InventoryService _inventoryService = InventoryService();
  final SupplierService _supplierService = SupplierService();
  final HRService _hrService = HRService();
  final EmployeeService _employeeService = EmployeeService();

  Future<void> _clearCompanyRecords(Box box, String companyCode) async {
return CachePartitions.run(() async {

    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is List) {
        final kept = raw.where((row) => row is! Map || row['company_code']?.toString() != companyCode).toList();
        if (kept.length == raw.length) continue;
        if (kept.isEmpty) { await box.delete(key); }
        else { await box.put(key, kept); }
      } else if (raw is Map && raw['company_code']?.toString() == companyCode) {
        await box.delete(key);
      }
    }
});
}

  // ============================================================
  // إعادة تعيين اليوميات
  // ============================================================
  Future<void> resetDailyTransactions(String companyCode) async {
return CachePartitions.run(() async {

    final box = CachePartitions.box('daily_transactions_box');
    await JournalCache.deleteCompany(box, companyCode);
    await _dailyService.fetchAllTransactions(companyCode);
});
}

  // ============================================================
  // إعادة تعيين التكويدات (selective)
  //
  // ⚠️ مهم: بنمسح بس مفاتيح التكويد للشركة، مش كل coding_box
  // عشان ما نمسحش:
  //   - بيانات HR (موظفين + حضور + إجازات + ...)
  //   - الصلاحيات (permissions_*)
  //   - الفروع المسموحة (allowed_branches_*)
  //   - كاش التقارير (salary_report_* / branch_salaries_*)
  // ============================================================
  Future<void> resetCoding(String companyCode) async {
return CachePartitions.run(() async {

    final box = CachePartitions.box('coding_box');

    final toDelete = <dynamic>[];
    for (final k in box.keys) {
      final ks = k.toString();

      // احتفظ بالصلاحيات
      if (ks.startsWith('permissions_')) continue;
      if (ks.startsWith('allowed_branches_')) continue;
      if (ks.startsWith('hr_viewable_employees_')) continue;

      // احتفظ ببيانات HR
      if (ks == '${companyCode}_employees') continue;
      if (ks == '${companyCode}_hr_attendance') continue;
      if (ks == '${companyCode}_hr_vacations') continue;
      if (ks == '${companyCode}_hr_adjustments') continue;
      if (ks == '${companyCode}_hr_employee_settings') continue;

      // احتفظ بالكاش (هيتبطل تلقائيًا بعد الفيتش)
      if (ks.startsWith('salary_report_')) continue;
      if (ks.startsWith('branch_salaries_')) continue;

      // بس مفاتيح الشركة الحالية
      if (!ks.startsWith('${companyCode}_')) continue;

      toDelete.add(k);
    }

    for (final k in toDelete) {
      await box.delete(k);
    }

    await _codingService.fetchAllCoding(companyCode);
});
}

  // ============================================================
  // إعادة تعيين الجرد
  // ============================================================
  Future<void> resetInventory(String companyCode) async {
return CachePartitions.run(() async {

    final box = CachePartitions.box('inventory_box');
    await _clearCompanyRecords(box, companyCode);
    await _inventoryService.fetchAllInventory(companyCode);
});
}

  // ============================================================
  // إعادة تعيين الموردين
  // ============================================================
  Future<void> resetSupplier(String companyCode) async {
return CachePartitions.run(() async {

    final box = CachePartitions.box('supplier_box');
    await _clearCompanyRecords(box, companyCode);
    await _supplierService.fetchAllSupplier(companyCode);
});
}

  // ============================================================
  // ⭐ إعادة تعيين الموارد البشرية (جديد)
  //
  // الخطوات:
  //   1. امسح مفاتيح HR من coding_box
  //   2. امسح hr_pending_box (العمليات المعلقة)
  //   3. امسح كاش التقارير المالية للشركة
  //   4. امسح last_sync_hr_* من SharedPreferences (يفرض full sync في المرة الجاية)
  //   5. Full refetch من السيرفر
  // ============================================================
  Future<void> resetHR(String companyCode) async {
return CachePartitions.run(() async {

    // 1) امسح مفاتيح HR
    final box = CachePartitions.box('coding_box');
    final hrKeys = <String>[
      '${companyCode}_employees',
      '${companyCode}_hr_attendance',
      '${companyCode}_hr_vacations',
      '${companyCode}_hr_adjustments',
      '${companyCode}_hr_employee_settings',
    ];
    for (final k in hrKeys) {
      await box.delete(k);
    }

    // 2) امسح pending operations
    if (CachePartitions.isBoxOpen('hr_pending_box')) {
      final pending = CachePartitions.box('hr_pending_box');
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null && uid.isNotEmpty) {
        final keys = pending.keys.where((key) {
          final op = pending.get(key);
          return op is Map && op['company_code'] == companyCode && op['user_uid'] == uid;
        }).toList();
        await pending.deleteAll(keys);
      }
    }

    // 3) امسح كاش التقارير المالية
    final cacheToDelete = <dynamic>[];
    for (final k in box.keys) {
      final ks = k.toString();
      if (ks.startsWith('salary_report_${companyCode}__') ||
          ks.startsWith('branch_salaries_${companyCode}__')) {
        cacheToDelete.add(k);
      }
    }
    for (final k in cacheToDelete) {
      await box.delete(k);
    }

    // 4) امسح last_sync_hr_* — يجبر full sync في المرة الجاية
    final prefs = await CachePartitions.preferences();
    final syncKeys = <String>[
      'last_sync_hr_attendance_$companyCode',
      'last_sync_hr_vacations_$companyCode',
      'last_sync_hr_adjustments_$companyCode',
      'last_sync_hr_employee_settings_$companyCode',
      'last_sync_employees_$companyCode',
    ];
    for (final k in syncKeys) {
      await prefs.remove(k);
    }

    // 5) Full refetch من السيرفر
    // (لو السيرفر فاضي بعد TRUNCATE، بيرجع فاضي — وده صح)
    await _employeeService.fetchAllEmployees(companyCode);
    await _hrService.fetchAllAttendance(companyCode);
    await _hrService.fetchAllVacations(companyCode);
    await _hrService.fetchAllAdjustments(companyCode);
    await _hrService.fetchAllEmployeeSettings(companyCode);
});
}

  // ============================================================
  // إعادة تعيين الكل
  // ============================================================
  Future<void> resetAll(String companyCode) async {
return CachePartitions.run(() async {

    await resetDailyTransactions(companyCode);
    await resetCoding(companyCode);
    await resetInventory(companyCode);
    await resetSupplier(companyCode);
    await resetHR(companyCode);
    await TreasuryTransferService().reset(companyCode);
});
}
}