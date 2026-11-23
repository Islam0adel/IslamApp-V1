import 'cache_partitions.dart';
import 'employee_identity.dart';
import 'permission_hierarchy.dart';

/// Financial retention only. Section access and write authority are separate.
class HRCacheScope {
  static const moneyFields = {
    'salary',
    'base_salary',
    'net_salary',
    'gross_salary',
    'total_salary',
    'net',
    'base_pay',
    'bonuses_total',
    'deductions_total',
    'loans_total',
    'debt_remaining',
    'absence_deduction',
    'late_deduction',
    'permission_deduction',
    'early_leave_deduction',
    'overtime_bonus',
    'amount',
  };
  static bool right(Map<String, dynamic>? permissions, String key) =>
      PermissionHierarchy.allows(permissions, 'الموارد البشرية', key);
  static bool isHRKey(String key, String company) =>
      key == '${company}_employees' || key.startsWith('${company}_hr_');

  static Set<String> ownCodes(
      {required String company,
      required String? uid,
      required String verifiedEmail,
      required Map<String, dynamic>? permissions}) {
    if (uid == null ||
        uid.isEmpty ||
        !right(permissions, 'canViewOwnHRData') ||
        !CachePartitions.isBoxOpen('coding_box')) return {};
    final rows = CachePartitions.box('coding_box').get('${company}_employees');
    if (rows is! List) return {};
    return rows
        .whereType<Map>()
        .where((row) =>
            (row['company_code'] == null || row['company_code'] == company) &&
            EmployeeIdentity.matches(row, uid: uid, email: verifiedEmail))
        .map((row) => (row['code'] ?? '').toString())
        .where((code) => code.isNotEmpty)
        .toSet();
  }

  static dynamic withoutAmounts(dynamic value) {
    if (value is Map)
      return {
        for (final entry in value.entries)
          if (!moneyFields.contains(entry.key))
            entry.key: withoutAmounts(entry.value)
      };
    if (value is List) return value.map(withoutAmounts).toList();
    return value;
  }

  static Future<bool> apply(
      {required String company,
      required String? uid,
      required String verifiedEmail,
      required Map<String, dynamic>? permissions,
      List<String>? branches,
      List<String>? viewable,
      bool invalidateTotals = false,
      bool compact = false}) async {
return CachePartitions.run(() async {

    if (!CachePartitions.isBoxOpen('coding_box')) return false;
    final box = CachePartitions.box('coding_box');
    final own = ownCodes(
        company: company,
        uid: uid,
        verifiedEmail: verifiedEmail,
        permissions: permissions);
    final salary = right(permissions, 'canViewSalaryAmounts');
    final employees = box.get('${company}_employees');
    final byCode = <String, Map>{
      if (employees is List)
        for (final row in employees.whereType<Map>())
          (row['code'] ?? '').toString(): row
    };
    bool visible(String code) {
      if (own.contains(code)) return true;
      if (viewable != null && viewable.isNotEmpty && !viewable.contains(code))
        return false;
      if (branches == null || branches.isEmpty || branches.contains('all'))
        return true;
      return branches.contains(byCode[code]?['branch_code']?.toString());
    }

    var changed = false;
    for (final key in box.keys.toList()) {
      final name = key.toString();
      if (name.startsWith('salary_report_${company}__')) {
        final rest = name.substring('salary_report_${company}__'.length);
        final boundary = rest.lastIndexOf('__');
        final code = boundary < 1 ? '' : rest.substring(0, boundary);
        if (code.isEmpty ||
            (!salary && !own.contains(code)) ||
            !visible(code)) {
          await box.delete(key);
          changed = true;
        }
        continue;
      }
      if (name.startsWith('branch_salaries_${company}__')) {
        // An old aggregate cannot be safely re-scoped or partially redacted.
        if (invalidateTotals ||
            !salary ||
            !right(permissions, 'canViewBranchSalaryReport')) {
          await box.delete(key);
          changed = true;
        }
        continue;
      }
      if (!isHRKey(name, company)) continue;
      final rows = box.get(key);
      if (rows is! List) continue;
      var edited = false;
      final out = rows.map((row) {
        if (row is! Map) return row;
        final code =
            (row[name == '${company}_employees' ? 'code' : 'employee_code'] ??
                    '')
                .toString();
        if (salary || own.contains(code)) return row;
        final clean = withoutAmounts(row);
        // Compare recursively without importing the permission service.
        if (_containsAmounts(row)) edited = true;
        return clean;
      }).toList();
      if (edited) {
        await box.put(key, out);
        changed = true;
      }
    }
    if (changed || compact) await box.compact();
    return changed;
});
}

  static bool _containsAmounts(dynamic value) {
    if (value is Map)
      return value.entries.any((entry) =>
              moneyFields.contains(entry.key) && entry.value != null) ||
          value.values.any(_containsAmounts);
    if (value is List) return value.any(_containsAmounts);
    return false;
  }
}
