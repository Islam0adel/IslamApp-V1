import 'permissions_service.dart';

/// Mirrors the read endpoints' OR grants. Visibility is never data authority.
/// Write queues deliberately do not use this plan.
class SyncReadAccess {
  static const checks = <String, List<List<String>>>{
    'daily': [
      ['حركة الخزينة', 'المعاينة'],
      ['حركة الخزينة', 'ادخال اذون']
    ],
    'supplier': [
      ['حسابات الموردين', 'معاينة'],
      ['حسابات الموردين', 'اضافة']
    ],
    'settlement': [
      ['تسويات الموردين', 'معاينة'],
      ['تسويات الموردين', 'إضافة']
    ],
    'inventory': [
      ['حركة الجرد', 'معاينة'],
      ['حركة الجرد', 'اضافة']
    ],
    'sales': [
      ['المبيعات', 'معاينة']
    ],
    'returns': [
      ['المرتجعات', 'معاينة']
    ],
    'customer-payments': [
      ['حسابات العملاء', 'معاينة']
    ],
    'treasury_transfers': [
      ['تحويلات الخزائن', 'معاينة']
    ],
    'transfers': [
      ['التحويلات المخزنية', 'معاينة']
    ],
    'employees': [
      ['الموارد البشرية', 'canViewEmployees'],
      ['الموارد البشرية', 'canManageEmployees'],
      ['الموارد البشرية', 'canOpenAttendancePage'],
      ['الموارد البشرية', 'canOpenVacationsPage'],
      ['الموارد البشرية', 'canViewAdjustments'],
      ['الموارد البشرية', 'canViewBranchSalaryReport'],
      ['الموارد البشرية', 'canViewOwnHRData'],
      ['حسابات العملاء', 'إضافة تحصيل'],
      ['حسابات العملاء', 'معاينة'],
      ['المبيعات', 'إضافة'],
      ['المبيعات', 'معاينة'],
    ],
    'attendance': [
      ['الموارد البشرية', 'canOpenAttendancePage'],
      ['الموارد البشرية', 'canViewBranchSalaryReport']
    ],
    'vacations': [
      ['الموارد البشرية', 'canOpenVacationsPage'],
      ['الموارد البشرية', 'canViewBranchSalaryReport']
    ],
    'adjustments': [
      ['الموارد البشرية', 'canViewAdjustments'],
      ['الموارد البشرية', 'canViewBranchSalaryReport']
    ],
    'employee_settings': [
      ['الموارد البشرية', 'canEditWeeklyDay'],
      ['الموارد البشرية', 'canEditWorkSchedule'],
      ['الموارد البشرية', 'canEditDelayRules'],
      ['الموارد البشرية', 'canOpenAttendancePage']
    ],
    'coding': [
      ['التكويد', 'معاينة'],
      ['حركة الخزينة', 'المعاينة'],
      ['حركة الخزينة', 'ادخال اذون'],
      ['حسابات الموردين', 'معاينة'],
      ['حسابات الموردين', 'اضافة'],
      ['تسويات الموردين', 'معاينة'],
      ['تسويات الموردين', 'إضافة'],
      ['حركة الجرد', 'معاينة'],
      ['حركة الجرد', 'اضافة'],
      ['المبيعات', 'معاينة'],
      ['المبيعات', 'إضافة'],
      ['المرتجعات', 'معاينة'],
      ['المرتجعات', 'إضافة'],
      ['حسابات العملاء', 'معاينة'],
      ['حسابات العملاء', 'إضافة تحصيل'],
      ['التحويلات المخزنية', 'معاينة'],
      ['التحويلات المخزنية', 'إضافة'],
      ['رصيد المخزون', 'معاينة'],
      ['أرصدة خزائن المبيعات', 'معاينة'],
      ['التقارير', 'تقرير المبيعات'],
      ['التقارير', 'التقرير الموسع (صافي الجرد)'],
      ['الموارد البشرية', 'canOpenAttendancePage'],
      ['الموارد البشرية', 'canViewEmployees'],
      ['الموارد البشرية', 'canManageEmployees'],
      ['الموارد البشرية', 'canViewBranchSalaryReport'],
    ],
  };
  static bool allows(String module) {
    final p = PermissionsService();
    final grants = checks[module];
    return grants != null &&
        p.isLoaded &&
        (p.canBypassPermissions ||
            grants.any((g) => p.hasPermission(g[0], g[1])));
  }
}
