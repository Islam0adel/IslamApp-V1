// lib/models/hr_salary_report_model.dart


class HRAdjustmentLine {
  final String type; // bonus / deduction / loan
  final String label;
  final double amount;

  HRAdjustmentLine({
    required this.type,
    required this.label,
    required this.amount,
  });

  factory HRAdjustmentLine.fromMap(Map<String, dynamic> map) {
    return HRAdjustmentLine(
      type: map['type']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      amount: _toDouble(map['amount']),
    );
  }
}


class HRAttendanceDetail {
  final String date;
  final String status;
  final String note;
  final String? checkIn;
  final String? checkOut;
  final int lateMinutes;
  final int overtimeMinutes;

  HRAttendanceDetail({
    required this.date,
    required this.status,
    required this.note,
    this.checkIn,
    this.checkOut,
    required this.lateMinutes,
    required this.overtimeMinutes,
  });

  factory HRAttendanceDetail.fromMap(Map<String, dynamic> map) {
    return HRAttendanceDetail(
      date: map['date']?.toString() ?? '',
      status: map['status']?.toString() ?? '',
      note: map['note']?.toString() ?? '',
      checkIn: map['check_in']?.toString(),
      checkOut: map['check_out']?.toString(),
      lateMinutes: _toInt(map['late_minutes']),
      overtimeMinutes: _toInt(map['overtime_minutes']),
    );
  }

  String get statusLabel {
    switch (status) {
      case 'present':
        return 'حاضر';
      case 'late':
        return 'متأخر';
      case 'absent':
        return 'غائب';
      case 'vacation':
        return 'إجازة';
      case 'permission':
        return 'إذن';
      case 'future':
        return 'لم يأتِ';
      case 'half_day':
        return 'نصف يوم';
      default:
        return status;
    }
  }
}


class HRSalaryReportModel {
  final String companyCode;
  final String branchCode;
  final String employeeCode;
  final String employeeName;
  final String month;

  final double baseSalary;
  final int workDays;

  // ⭐ الأيام اللي عدّت والأيام المستقبلية
  final int elapsedDays;
  final int futureDays;

  // ⭐ هل الشهر ثابت 30 يوم؟
  final bool useFixedMonthDays;

  final int presentDays;
  final int absentDays;
  final int vacationDays;
  final int lateMinutesTotal;
  final int overtimeMinutesTotal;
  final int earlyLeaveMinutesTotal;

  final double basePay;
  final double absenceDeduction;
  final double lateDeduction;
  final double earlyLeaveDeduction;
  final double overtimeBonus;

  final double bonusesTotal;
  final double deductionsTotal;
  final double loansTotal;

  final double netSalary;

  /// ⭐ الدين المتبقي (لو الصافي سالب — الموظف مدين للشركة)
  final double debtRemaining;

  final List<HRAdjustmentLine> adjustmentLines;
  final List<HRAttendanceDetail> attendanceDetails;

  HRSalaryReportModel({
    required this.companyCode,
    required this.branchCode,
    required this.employeeCode,
    required this.employeeName,
    required this.month,
    required this.baseSalary,
    required this.workDays,
    required this.elapsedDays,
    required this.futureDays,
    required this.useFixedMonthDays,
    required this.presentDays,
    required this.absentDays,
    required this.vacationDays,
    required this.lateMinutesTotal,
    required this.overtimeMinutesTotal,
    required this.earlyLeaveMinutesTotal,
    required this.basePay,
    required this.absenceDeduction,
    required this.lateDeduction,
    required this.earlyLeaveDeduction,
    required this.overtimeBonus,
    required this.bonusesTotal,
    required this.deductionsTotal,
    required this.loansTotal,
    required this.netSalary,
    required this.debtRemaining,   // ⭐
    required this.adjustmentLines,
    required this.attendanceDetails,
  });

  factory HRSalaryReportModel.fromMap(Map<String, dynamic> map) {
    return HRSalaryReportModel(
      companyCode: map['company_code']?.toString() ?? '',
      branchCode: map['branch_code']?.toString() ?? '',
      employeeCode: map['employee_code']?.toString() ?? '',
      employeeName: map['employee_name']?.toString() ?? '',
      month: map['month']?.toString() ?? '',
      baseSalary: _toDouble(map['base_salary']),
      workDays: _toInt(map['work_days']),
      elapsedDays: _toInt(map['elapsed_days']),
      futureDays: _toInt(map['future_days']),
      useFixedMonthDays: map['use_fixed_month_days'] == null
          ? true
          : (map['use_fixed_month_days'] == true),
      presentDays: _toInt(map['present_days']),
      absentDays: _toInt(map['absent_days']),
      vacationDays: _toInt(map['vacation_days']),
      lateMinutesTotal: _toInt(map['late_minutes_total']),
      overtimeMinutesTotal: _toInt(map['overtime_minutes_total']),
      earlyLeaveMinutesTotal: _toInt(map['early_leave_minutes_total']),
      basePay: _toDouble(map['base_pay']),
      absenceDeduction: _toDouble(map['absence_deduction']),
      lateDeduction: _toDouble(map['late_deduction']),
      earlyLeaveDeduction: _toDouble(map['early_leave_deduction']),
      overtimeBonus: _toDouble(map['overtime_bonus']),
      bonusesTotal: _toDouble(map['bonuses_total']),
      deductionsTotal: _toDouble(map['deductions_total']),
      loansTotal: _toDouble(map['loans_total']),
      netSalary: _toDouble(map['net_salary']),
      debtRemaining: _toDouble(map['debt_remaining']),   // ⭐
      adjustmentLines: (map['adjustment_lines'] as List?)
              ?.whereType<Map>()
              .map((e) => HRAdjustmentLine.fromMap(Map<String, dynamic>.from(e)))
              .toList() ??
          [],
      attendanceDetails: (map['attendance_details'] as List?)
              ?.whereType<Map>()
              .map((e) => HRAttendanceDetail.fromMap(Map<String, dynamic>.from(e)))
              .toList() ??
          [],
    );
  }

  /// نص التقرير للنسخ / المشاركة
  String toPlainText() {
    final buffer = StringBuffer();

    buffer.writeln('📊 تقرير راتب - $employeeName');
    buffer.writeln('الشهر: $month');
    buffer.writeln('كود الموظف: $employeeCode');
    buffer.writeln('الفرع: $branchCode');
    buffer.writeln('─────────────────────');

    buffer.writeln('الراتب الأساسي (الشهري): ${baseSalary.toStringAsFixed(2)} ج.م');
    buffer.writeln('أيام الشهر: $workDays (عدّى منها: $elapsedDays)');
    if (futureDays > 0) {
      buffer.writeln('⚠️ $futureDays يوم لم يأتِ بعد — غير محسوب في المستحق');
    }
    buffer.writeln('  ✅ حاضر: $presentDays');
    buffer.writeln('  ❌ غائب: $absentDays');
    buffer.writeln('  🏖️ إجازة: $vacationDays');
    if (futureDays > 0) {
      buffer.writeln('  ⏳ قادم: $futureDays');
    }
    buffer.writeln('─────────────────────');

    buffer.writeln('الحساب:');
    buffer.writeln('  + المستحق: ${basePay.toStringAsFixed(2)}');

    if (absenceDeduction > 0) {
      buffer.writeln('  - غياب ($absentDays يوم): -${absenceDeduction.toStringAsFixed(2)}');
    }
    if (lateDeduction > 0) {
      buffer.writeln('  - تأخير ($lateMinutesTotal د): -${lateDeduction.toStringAsFixed(2)}');
    }
    if (earlyLeaveDeduction > 0) {
      buffer.writeln('  - انصراف مبكر: -${earlyLeaveDeduction.toStringAsFixed(2)}');
    }
    if (overtimeBonus > 0) {
      buffer.writeln('  + إضافي ($overtimeMinutesTotal د): +${overtimeBonus.toStringAsFixed(2)}');
    }

    for (final line in adjustmentLines) {
      final sign = line.amount >= 0 ? '+' : '';
      buffer.writeln('  $sign${line.amount.toStringAsFixed(2)} - ${line.label}');
    }

    buffer.writeln('─────────────────────');
    buffer.writeln('💰 الصافي: ${netSalary.toStringAsFixed(2)} ج.م');
    if (netSalary < 0) {
      buffer.writeln('⚠️ مدين للشركة بـ ${debtRemaining.toStringAsFixed(2)} ج.م');
    }

    return buffer.toString();
  }
}


// ============================================================
// Helpers
// ============================================================

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}

int _toInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}