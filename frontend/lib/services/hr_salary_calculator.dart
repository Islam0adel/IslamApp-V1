// lib/services/hr_salary_calculator.dart

import '../core/hr_constants.dart';
import '../models/hr_models.dart';


/// حاسبة الراتب الشهري (نسخة Dart مطابقة لـ Python)
///
/// ⚠️ مهم جداً:
/// هذا الملف هو **نسخة طبق الأصل** من:
///   backend/app/services/hr_salary_calculator.py
///
/// أي تعديل في مكان لازم يتعدل في التاني.
/// نستخدم test fixtures مشتركة لضمان التطابق.
///
/// القواعد (مطابقة للباك):
/// - قيمة اليوم = الراتب الأساسي / 30 (أو / أيام الشهر لو useFixedMonthDays=false)
/// - قيمة الساعة = قيمة اليوم / ساعات العمل (افتراضي 8)
/// - الإجازات (official + weekly + vacation) = مدفوعة بدون خصم
/// - الغياب = خصم حسب delay_rules['absence'] (افتراضي: 3 أيام)
/// - الغياب بإذن = خصم حسب delay_rules['absence_with_permission'] (افتراضي: 1 يوم)
/// - التأخير = خصم حسب delay_rules (يُحدد الشريحة من late_minutes)
/// - الإضافي = (دقائق / 60) × قيمة الساعة × multiplier
/// - ⭐ الأيام المستقبلية لا تُحسب غياب
/// - ⭐ base_pay = elapsed_days × daily_rate (المرتب المستحق)
class HRSalaryCalculator {
  HRSalaryCalculator._(); // private constructor (utility class)

  // ============================================================
  // Helper: تحديد أيام الخصم من دقائق التأخير
  //
  // الشرائح (مطابقة للباك):
  // - 0-10 دقيقة     → delay_10min
  // - 11-30 دقيقة    → delay_15min
  // - 31-60 دقيقة    → delay_30min
  // - 61-120 دقيقة   → delay_60min
  // - أكثر من 120    → delay_120min
  // ============================================================

  static double _getDelayDeductionDays(
    int lateMinutes,
    Map<String, double> rules,
  ) {
    if (lateMinutes <= 10) {
      return rules['delay_10min'] ?? 0.0;
    } else if (lateMinutes <= 30) {
      return rules['delay_15min'] ?? 0.25;
    } else if (lateMinutes <= 60) {
      return rules['delay_30min'] ?? 0.5;
    } else if (lateMinutes <= 120) {
      return rules['delay_60min'] ?? 1.0;
    } else {
      return rules['delay_120min'] ?? 2.0;
    }
  }

    static int _timeToMinutes(String time) {
    if (time.isEmpty) return 0;
    final parts = time.split(':');
    if (parts.length < 2) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return h * 60 + m;
  }

  // ============================================================
  // الدالة الرئيسية: حساب الراتب
  //
  // ⚠️ هذه دالة نقية (pure, sync):
  // - لا تلمس Hive
  // - لا تلمس HTTP
  // - كل المدخلات من parameters
  //
  // Returns:
  //   Map<String, dynamic> بنفس شكل الباك
  //   (يتحول لـ HRSalaryReportModel في HRReportService)
  // ============================================================

  static Map<String, dynamic> calculate({
    required String companyCode,
    required String employeeCode,
    required String month, // "YYYY-MM"
    required String employeeName,
    required double baseSalary,
    required String branchCode,

    // إعدادات الموظف
    required HREmployeeSettingsModel employeeSettings,

    // البيانات
    required Map<String, HRAttendanceModel> attendanceByDate,
    required List<HRVacationModel> vacations,
    required List<HRAdjustmentModel> adjustments,

    // إعدادات HR العامة (افتراضيات)
    double workHours = HRConstants.defaultWorkHoursPerDay,
    int graceMinutes = HRConstants.defaultGraceMinutes,
    double overtimeMultiplier = HRConstants.defaultOvertimeMultiplier,

    // يوم الإجازة الأسبوعي (اختياري — يأتي من إعدادات الموظف)
    int? weeklyVacationDay,
  }) {
    // ============================================================
    // 1) استخراج القيم من الإعدادات
    // ============================================================

    final flexibleHours = employeeSettings.flexibleHours;
    final defaultCheckIn = employeeSettings.defaultCheckIn;
    final defaultCheckOut = employeeSettings.defaultCheckOut;
    final useFixedMonthDays = employeeSettings.useFixedMonthDays;

    // دمج قواعد التأخير: defaults + employee overrides
    // (نفس ما يفعله الباك: DEFAULT_DELAY_RULES ثم emp_settings.delay_rules)
    final delayRules = Map<String, double>.from(
      HRConstants.defaultDelayRules,
    );
    delayRules.addAll(employeeSettings.delayRules);

    // يوم الإجازة الأسبوعي (الممرر يتغلب على إعدادات الموظف)
    final effectiveWeeklyDay =
        weeklyVacationDay ?? employeeSettings.weeklyVacationDay;

    // ============================================================
    // 2) الحسابات الأساسية
    // ============================================================

    final monthDate = DateTime.parse('$month-01');
    final daysInMonth = HRConstants.daysInMonth(monthDate);

    // ⭐ dailyRate حسب إعداد الموظف
    final dailyRate = useFixedMonthDays
        ? baseSalary / HRConstants.daysPerMonth
        : (daysInMonth > 0 ? baseSalary / daysInMonth : 0.0);

    final hourlyRate = workHours > 0 ? dailyRate / workHours : 0.0;
    final minuteRate = hourlyRate / 60;

    // ⭐ الأيام اللي عدّت
    //
    // - شهر ماضي كامل    → elapsedDays = daysInMonth
    // - شهر حالي        → elapsedDays = اليوم الحالي
    // - شهر مستقبلي     → elapsedDays = 0
    final now = DateTime.now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final monthFirst = DateTime(monthDate.year, monthDate.month, 1);
    final monthLast = DateTime(monthDate.year, monthDate.month, daysInMonth);

    int elapsedDays;
    if (todayDate.isAfter(monthLast)) {
      elapsedDays = daysInMonth;
    } else if (todayDate.isBefore(monthFirst)) {
      elapsedDays = 0;
    } else {
      elapsedDays = todayDate.day;
    }

    // ============================================================
    // 3) تجهيز الإجازات المطبقة على هذا الموظف
    //
    // المنطق (مطابق للباك):
    // - إجازة موظف محدد → تطبق فقط لو employee_code = الموظف
    // - إجازة فرع محدد → تطبق فقط لو branch_code = الفرع
    // - إجازة عامة → تطبق للجميع
    // ============================================================

    final applicableVacations = <String>{};

    for (final v in vacations) {
      if (v.employeeCode != null) {
        if (v.employeeCode == employeeCode) {
          applicableVacations.add(v.date);
        }
      } else if (v.branchCode != null) {
        if (v.branchCode == branchCode) {
          applicableVacations.add(v.date);
        }
      } else {
        applicableVacations.add(v.date);
      }
    }

    // ============================================================
    // 4) عدادات
    // ============================================================

    int presentDays = 0;
    int absentDays = 0;
    int vacationDays = 0;
    int permissionDays = 0;
    int futureDays = 0;

    int totalLateMinutes = 0;
    int totalEarlyLeaveMinutes = 0;
    int totalOvertimeMinutes = 0;

    double delayDeductionDays = 0.0;
    double absenceDeductionDays = 0.0;
    double permissionDeductionDays = 0.0;

    final attendanceDetails = <Map<String, dynamic>>[];

    // ============================================================
    // 5) الحلقة الرئيسية على أيام الشهر
    //
    // ⚠️ الأولوية:
    //   1. سجل حضور (لو موجود)
    //   2. يوم مستقبلي (isFuture)
    //   3. إجازة أسبوعية/رسمية
    //   4. غياب
    // ============================================================

        for (int dayNum = 1; dayNum <= daysInMonth; dayNum++) {
      final dateStr = '$month-${dayNum.toString().padLeft(2, '0')}';
      final date = DateTime.parse(dateStr);

      final isWeekly = HRConstants.isWeeklyVacation(date, effectiveWeeklyDay);
      final isVacation = applicableVacations.contains(dateStr);
      final att = attendanceByDate[dateStr];
      final isFuture = dayNum > elapsedDays;

      // ------------------------------------------------
      // 5.1 فيه سجل حضور → له الأولوية المطلقة
      // ------------------------------------------------
      if (att != null) {
        // إجازة مسجلة يدويًا
        if (att.status == 'vacation') {
          vacationDays++;
          attendanceDetails.add({
            'date': dateStr, 'status': 'vacation',
            'note': att.notes.isNotEmpty ? att.notes : 'إجازة',
            'check_in': null, 'check_out': null,
            'late_minutes': 0, 'overtime_minutes': 0,
            'deduction_days': 0.0,
          });
          continue;
        }

        // غياب مسجل
        if (att.status == 'absent') {
          absentDays++;
          final deduction = delayRules['absence'] ?? 3.0;
          absenceDeductionDays += deduction;
          attendanceDetails.add({
            'date': dateStr, 'status': 'absent',
            'note': att.notes.isNotEmpty ? att.notes : 'غياب',
            'check_in': null, 'check_out': null,
            'late_minutes': 0, 'overtime_minutes': 0,
            'deduction_days': deduction,
          });
          continue;
        }

        // إذن
        if (att.status == 'permission') {
          permissionDays++;
          presentDays++;
          final deduction = delayRules['absence_with_permission'] ?? 1.0;
          permissionDeductionDays += deduction;
          attendanceDetails.add({
            'date': dateStr, 'status': 'permission',
            'note': att.notes.isNotEmpty ? att.notes : 'إذن',
            'check_in': att.checkIn.isNotEmpty ? att.checkIn : null,
            'check_out': att.checkOut.isNotEmpty ? att.checkOut : null,
            'late_minutes': 0, 'overtime_minutes': 0,
            'deduction_days': deduction,
          });
          continue;
        }

        // حاضر / متأخر
        presentDays++;
        int late = 0;
        int overtimeMin = 0;
        final earlyLeave = att.earlyLeaveMinutes;

        if (flexibleHours) {
          // مرونة: الإضافي فقط لو worked > required
          if (att.checkIn.isNotEmpty && att.checkOut.isNotEmpty) {
            final inMin = _timeToMinutes(att.checkIn);
            final outMin = _timeToMinutes(att.checkOut);
            final workedMin = outMin > inMin ? outMin - inMin : 0;
            final requiredMin = (workHours * 60).round();
            if (workedMin > requiredMin) {
              overtimeMin = workedMin - requiredMin;
            }
          }
        } else {
          late = att.lateMinutes;
          overtimeMin = att.overtimeMinutes;
          if (late <= graceMinutes) late = 0;
        }

        totalLateMinutes += late;
        totalEarlyLeaveMinutes += earlyLeave;
        totalOvertimeMinutes += overtimeMin;

        double delayDeduction = 0.0;
        if (late > 0) {
          delayDeduction = _getDelayDeductionDays(late, delayRules);
          delayDeductionDays += delayDeduction;
        }

        final noteSuffix =
            (isWeekly || isVacation) ? ' (عمل في يوم إجازة)' : '';
        final baseNote = att.notes.isNotEmpty ? att.notes : '';

        attendanceDetails.add({
          'date': dateStr,
          'status': att.status,
          'note': baseNote + noteSuffix,
          'check_in': att.checkIn.isNotEmpty ? att.checkIn : null,
          'check_out': att.checkOut.isNotEmpty ? att.checkOut : null,
          'late_minutes': late,
          'overtime_minutes': overtimeMin,
          'deduction_days': delayDeduction,
        });
        continue;
      }

      // ------------------------------------------------
      // 5.2 مفيش سجل حضور
      // ------------------------------------------------
      if (isFuture) {
        futureDays++;
        attendanceDetails.add({
          'date': dateStr, 'status': 'future',
          'note': 'لم يأتِ بعد', 'check_in': null, 'check_out': null,
          'late_minutes': 0, 'overtime_minutes': 0,
          'deduction_days': 0.0,
        });
        continue;
      }

      if (isWeekly || isVacation) {
        vacationDays++;
        attendanceDetails.add({
          'date': dateStr, 'status': 'vacation',
          'note': isWeekly ? 'إجازة أسبوعية' : 'إجازة رسمية',
          'check_in': null, 'check_out': null,
          'late_minutes': 0, 'overtime_minutes': 0,
          'deduction_days': 0.0,
        });
        continue;
      }

      // غياب (مفيش سجل + يوم ماضي + مفيش إجازة)
      absentDays++;
      final deduction = delayRules['absence'] ?? 3.0;
      absenceDeductionDays += deduction;
      attendanceDetails.add({
        'date': dateStr, 'status': 'absent',
        'note': 'بدون سجل', 'check_in': null, 'check_out': null,
        'late_minutes': 0, 'overtime_minutes': 0,
        'deduction_days': deduction,
      });
    }


    // ============================================================
    // 6) الحسابات المالية (بناءً على الأيام)
    // ============================================================

    final absenceDeduction = absenceDeductionDays * dailyRate;
    final permissionDeduction = permissionDeductionDays * dailyRate;
    final delayDeduction = delayDeductionDays * dailyRate;
    final overtimeBonus =
        totalOvertimeMinutes * minuteRate * overtimeMultiplier;

    // early_leave_deduction — مش مستخدم (مشمول في delay_rules)
    const earlyLeaveDeduction = 0.0;

    // ============================================================
    // 7) التسويات (مكافآت / خصومات / سلف)
    // ============================================================

    double bonusesTotal = 0.0;
    double deductionsTotal = 0.0;
    double loansTotal = 0.0;

    final adjustmentLines = <Map<String, dynamic>>[];

    for (final adj in adjustments) {
      final amount = adj.amount;

      if (adj.type == 'bonus') {
        bonusesTotal += amount;
        adjustmentLines.add({
          'type': 'bonus',
          'label': adj.reason.isNotEmpty
              ? 'مكافأة: ${adj.reason}'
              : 'مكافأة',
          'amount': amount,
        });
      } else if (adj.type == 'deduction') {
        deductionsTotal += amount;
        adjustmentLines.add({
          'type': 'deduction',
          'label': adj.reason.isNotEmpty
              ? 'خصم: ${adj.reason}'
              : 'خصم',
          'amount': -amount,
        });
      } else if (adj.type == 'loan') {
        loansTotal += amount;
        var label = 'قسط سلفة';
        if (adj.installmentRef.isNotEmpty) {
          label += ' (${adj.installmentRef})';
        }
        if (adj.reason.isNotEmpty) {
          label += ' - ${adj.reason}';
        }
        adjustmentLines.add({
          'type': 'loan',
          'label': label,
          'amount': -amount,
        });
      }
    }

    // ============================================================
    // 8) صافي الراتب
    //
    // ⭐ basePay = المرتب المستحق لحد النهاردة
    // (elapsedDays × dailyRate) — بدل baseSalary الكامل
    // ============================================================

    final basePay = elapsedDays * dailyRate;

    var netSalary = basePay -
        absenceDeduction -
        permissionDeduction -
        delayDeduction -
        deductionsTotal -
        loansTotal +
        overtimeBonus +
        bonusesTotal;

    // لو الصافي سالب، نخليه صفر (مطابق للباك)
    if (netSalary < 0) {
      netSalary = 0.0;
    }

    // ============================================================
    // 9) Return Map (نفس شكل الباك بالضبط)
    //
    // ملاحظة: التقريب بـ 2 خانة (round) — مهم للـ JS/Dart
    // لأن العمليات العشرية ممكن تنتج float مش دقيق.
    // ============================================================

    return {
      // معلومات أساسية
      'company_code': companyCode,
      'branch_code': branchCode,
      'employee_code': employeeCode,
      'employee_name': employeeName,
      'month': month,

      // الإعدادات
      'flexible_hours': flexibleHours,
      'use_fixed_month_days': useFixedMonthDays,
      'default_check_in': defaultCheckIn,
      'default_check_out': defaultCheckOut,
      'weekly_vacation_day': effectiveWeeklyDay,

      // الحضور
      'base_salary': _round2(baseSalary),
      'work_days': daysInMonth,
      'elapsed_days': elapsedDays,
      'present_days': presentDays,
      'absent_days': absentDays,
      'vacation_days': vacationDays,
      'future_days': futureDays,
      'permission_days': permissionDays,
      'late_minutes_total': totalLateMinutes,
      'overtime_minutes_total': totalOvertimeMinutes,
      'early_leave_minutes_total': totalEarlyLeaveMinutes,

      // أيام الخصم
      'absence_deduction_days': _round2(absenceDeductionDays),
      'delay_deduction_days': _round2(delayDeductionDays),
      'permission_deduction_days': _round2(permissionDeductionDays),

      // البنود المالية
      'base_pay': _round2(basePay),
      'absence_deduction': _round2(absenceDeduction),
      'permission_deduction': _round2(permissionDeduction),
      'late_deduction': _round2(delayDeduction),
      'early_leave_deduction': _round2(earlyLeaveDeduction),
      'overtime_bonus': _round2(overtimeBonus),

      'bonuses_total': _round2(bonusesTotal),
      'deductions_total': _round2(deductionsTotal),
      'loans_total': _round2(loansTotal),

      'net_salary': _round2(netSalary),

      // التفاصيل
      'adjustment_lines': adjustmentLines,
      'attendance_details': attendanceDetails,

      // قواعد التأخير المستخدمة (للمراجعة)
      'delay_rules': delayRules,
    };
  }


  // ============================================================
  // Helper: تقريب لـ 2 خانة عشرية
  //
  // ⚠️ مهم: تقريب Dart → 2 خانة بطريقة مطابقة لـ Python round()
  // - 2.675 → "2.67" أو "2.68" حسب الـ float precision
  // - نستخدم * 100 → round → / 100 للحصول على أدق نتيجة
  // ============================================================

  static double _round2(double value) {
    return (value * 100).round() / 100;
  }
}

// ============================================================
// نهاية ملف hr_salary_calculator.dart
//
// ملخص:
// - HRSalaryCalculator.calculate() — دالة نقية (pure, sync)
// - المدخلات: بيانات الموظف + الحضور + الإجازات + التسويات + الإعدادات
// - المخرجات: Map بنفس شكل الباك (HRSalaryReportModel.fromMap)
//
// ⚠️ توافق مع الباك:
// - DEFAULT_DELAY_RULES: 3.0 للغياب، 1.0 للغياب بإذن
// - daily_rate = base_salary / 30 (أو / أيام الشهر لو use_fixed_month_days=false)
// - delay_deduction: 5 شرائح (10/15/30/60/120 دقيقة)
// - الأولوية في الحلقة: سجل حضور → مستقبلي → إجازة → غياب
// - base_pay = elapsed_days × daily_rate (المرتب المستحق)
// - الراتب الصافي لا يقل عن صفر
//
// 🧪 اختبار التطابق:
// - Test fixtures في: test/fixtures/hr_salary_cases.json
// - نفس الـ fixtures تُستخدم في Python و Dart
// - أي اختلاف = bug في واحد منهم
// ============================================================