// lib/services/reset_data_service.dart
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // ============================================================
  // إعادة تعيين اليوميات
  // ============================================================
  Future<void> resetDailyTransactions(String companyCode) async {
    final box = Hive.box('daily_transactions_box');
    await box.clear();
    await _dailyService.fetchAllTransactions(companyCode);
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
    final box = Hive.box('coding_box');

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
  }

  // ============================================================
  // إعادة تعيين الجرد
  // ============================================================
  Future<void> resetInventory(String companyCode) async {
    final box = Hive.box('inventory_box');
    await box.clear();
    await _inventoryService.fetchAllInventory(companyCode);
  }

  // ============================================================
  // إعادة تعيين الموردين
  // ============================================================
  Future<void> resetSupplier(String companyCode) async {
    final box = Hive.box('supplier_box');
    await box.clear();
    await _supplierService.fetchAllSupplier(companyCode);
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
    // 1) امسح مفاتيح HR
    final box = Hive.box('coding_box');
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
    if (Hive.isBoxOpen('hr_pending_box')) {
      await Hive.box('hr_pending_box').clear();
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
    final prefs = await SharedPreferences.getInstance();
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
  }

  // ============================================================
  // إعادة تعيين الكل
  // ============================================================
  Future<void> resetAll(String companyCode) async {
    await resetDailyTransactions(companyCode);
    await resetCoding(companyCode);
    await resetInventory(companyCode);
    await resetSupplier(companyCode);
    await resetHR(companyCode);
  }
}