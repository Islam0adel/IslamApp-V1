// Salary-report visibility contract. Calculations are not changed.
class SalaryVisibility {
  static const reportSafeKeys = <String>{
    "absence",
    "absence_deduction_days",
    "absence_with_permission",
    "absent_days",
    "attendance_details",
    "branch_code",
    "check_in",
    "check_out",
    "company_code",
    "date",
    "deduction_days",
    "default_check_in",
    "default_check_out",
    "delay_deduction_days",
    "early_leave_minutes_total",
    "elapsed_days",
    "employee_code",
    "employee_name",
    "flexible_hours",
    "future_days",
    "grace_minutes",
    "late_minutes",
    "late_minutes_total",
    "month",
    "overtime_minutes",
    "overtime_minutes_total",
    "overtime_multiplier",
    "permission",
    "permission_days",
    "present_days",
    "status",
    "use_fixed_month_days",
    "vacation_days",
    "weekly_vacation_day",
    "work_days"
  };
  static const lineSafeKeys = <String>{"date", "label", "note", "type"};
  static const branchTopKeys = <String>{"company_code", "month", "branch_code"};
  static const branchTotalKeys = <String>{"employees_count"};
  static Map<String, dynamic> report(Map<String, dynamic> data) {
    final out = {
      for (final entry in data.entries)
        if (reportSafeKeys.contains(entry.key)) entry.key: entry.value
    };
    final lines = data['adjustment_lines'];
    if (lines is List)
      out['adjustment_lines'] = lines
          .whereType<Map>()
          .map((line) => {
                for (final entry in line.entries)
                  if (lineSafeKeys.contains(entry.key)) entry.key: entry.value
              })
          .toList();
    return out;
  }

  static Map<String, dynamic> branch(Map<String, dynamic> data) {
    final totals = data['totals'];
    final employees = data['employees'];
    return {
      for (final entry in data.entries)
        if (branchTopKeys.contains(entry.key)) entry.key: entry.value,
      'totals': {
        if (totals is Map)
          for (final entry in totals.entries)
            if (branchTotalKeys.contains(entry.key)) entry.key: entry.value
      },
      'employees': employees is List
          ? employees
              .whereType<Map>()
              .map((row) => report(Map<String, dynamic>.from(row)))
              .toList()
          : [],
    };
  }
}
