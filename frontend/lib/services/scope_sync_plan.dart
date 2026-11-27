// frontend/lib/services/scope_sync_plan.dart
import 'company_permission_policy.dart';

// خطة مزامنة تغيّر النطاق
/// Disposable server snapshots only. Pending queues are never reset here.
class ScopeSyncPlan {
  static const all = {
    'daily',
    'settlement',
    'coding',
    'employees',
    'hr',
    'supplier',
    'inventory',
    'sales',
    'returns',
    'customer-payments',
    'transfers',
    'treasury'
  };
  static const categories = <String, Set<String>>{
    'حركة الخزينة': {'daily', 'treasury'},
    'أرصدة خزائن المبيعات': {'daily', 'treasury'},
    'تحويلات الخزائن': {'treasury'},
    'التكويد': {'coding'},
    'حسابات الموردين': {'supplier'},
    'تسويات الموردين': {'settlement'},
    'حركة الجرد': {'inventory'},
    'رصيد المخزون': {'coding', 'sales', 'returns', 'transfers'},
    'المبيعات': {'sales', 'coding'},
    'المرتجعات': {'returns'},
    'حسابات العملاء': {'customer-payments'},
    'التحويلات المخزنية': {'transfers'},
    'الموارد البشرية': {'employees', 'hr'},
    'التقارير': {
      'daily',
      'treasury',
      'inventory',
      'supplier',
      'settlement',
      'sales',
      'returns',
      'customer-payments',
      'transfers',
      'employees',
      'hr'
    },
  };

  // يحدد هل النطاقان متطابقان
  static bool sameScope(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.toSet().length == b.toSet().length && a.toSet().containsAll(b);
  }

  // يحدد الوحدات المتأثرة بين نطاقين
  static Set<String> between(
      {required Map<String, dynamic>? before,
      required Map<String, dynamic>? after,
      List<String>? oldBranches,
      List<String>? branches,
      List<String>? oldEmployees,
      List<String>? employees}) {
    if (before == null || after == null || !sameScope(oldBranches, branches))
      return {...all};
    final old = CompanyPermissionPolicy.grants(before),
        next = CompanyPermissionPolicy.grants(after);
    final changed = old.difference(next).union(next.difference(old));
    final modules = <String>{};
    for (final right in changed) {
      // Section menu visibility alone does not change server data scope.
      if (right.category == 'صلاحيات عامة' ||
          right.category == 'إدارة المستخدمين') continue;
      final mapped = categories[right.category];
      if (mapped == null)
        modules.addAll(all);
      else
        modules.addAll(mapped);
    }
    if (!sameScope(oldEmployees, employees))
      modules.addAll({'employees', 'hr'});
    return modules;
  }

  // يعيد مفاتيح المؤشرات للوحدات
  static Set<String> cursorKeys(String company, Set<String> modules) => {
        for (final module in modules)
          ...switch (module) {
            'hr' => {
                'last_sync_hr_attendance_$company',
                'last_sync_hr_vacations_$company',
                'last_sync_hr_adjustments_$company',
                'last_sync_hr_employee_settings_$company'
              },
            'customer-payments' => {'last_sync_customer_payments_$company'},
            'employees' => {
                'last_sync_employees_$company',
                'last_sync_coding__employees_$company'
              },
            'treasury' => <String>{},
            _ => {'last_sync_${module}_$company'},
          }
      };
}
