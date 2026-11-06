// lib/models/hr_models.dart

import '../core/hr_constants.dart';


// ============================================================
// Helper functions
//
// (top-level, قابلة للاستخدام من أي موديل في الملف)
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

int? _toIntNullable(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

bool _toBool(dynamic value) {
  if (value is bool) return value;
  if (value is String) {
    return value.toLowerCase() == 'true' || value == '1';
  }
  if (value is num) return value != 0;
  return false;
}


// ============================================================
// 1. HRAttendanceModel — سجل الحضور اليومي
// ============================================================

/// نموذج سجل حضور الموظف في يوم واحد
///
/// المفتاح الفريد في النظام: (companyCode, employeeCode, date)
/// — سجل واحد لكل موظف في اليوم.
class HRAttendanceModel {
  final int? id;
  final String companyCode;
  final String branchCode;
  final String employeeCode;
  final String date; // "YYYY-MM-DD"

  // الحالة: present / absent / vacation / late / permission
  final String status;

  final String checkIn;   // "HH:MM"
  final String checkOut;  // "HH:MM"

  final int lateMinutes;
  final int earlyLeaveMinutes;
  final int overtimeMinutes;

  final String notes;
  final String createdBy;
  final bool isDeleted;

  HRAttendanceModel({
    this.id,
    required this.companyCode,
    required this.branchCode,
    required this.employeeCode,
    required this.date,
    this.status = 'present',
    this.checkIn = '',
    this.checkOut = '',
    this.lateMinutes = 0,
    this.earlyLeaveMinutes = 0,
    this.overtimeMinutes = 0,
    this.notes = '',
    this.createdBy = '',
    this.isDeleted = false,
  });

  factory HRAttendanceModel.fromMap(Map<String, dynamic> map) {
    return HRAttendanceModel(
      id: _toIntNullable(map['id']),
      companyCode: map['company_code']?.toString() ?? '',
      branchCode: map['branch_code']?.toString() ?? '',
      employeeCode: map['employee_code']?.toString() ?? '',
      date: map['date']?.toString() ?? '',
      status: map['status']?.toString() ?? 'present',
      checkIn: map['check_in']?.toString() ?? '',
      checkOut: map['check_out']?.toString() ?? '',
      lateMinutes: _toInt(map['late_minutes']),
      earlyLeaveMinutes: _toInt(map['early_leave_minutes']),
      overtimeMinutes: _toInt(map['overtime_minutes']),
      notes: map['notes']?.toString() ?? '',
      createdBy: map['created_by']?.toString() ?? '',
      isDeleted: _toBool(map['is_deleted']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'company_code': companyCode,
      'branch_code': branchCode,
      'employee_code': employeeCode,
      'date': date,
      'status': status,
      'check_in': checkIn,
      'check_out': checkOut,
      'late_minutes': lateMinutes,
      'early_leave_minutes': earlyLeaveMinutes,
      'overtime_minutes': overtimeMinutes,
      'notes': notes,
      'created_by': createdBy,
      'is_deleted': isDeleted,
    };
  }

  HRAttendanceModel copyWith({
    int? id,
    String? companyCode,
    String? branchCode,
    String? employeeCode,
    String? date,
    String? status,
    String? checkIn,
    String? checkOut,
    int? lateMinutes,
    int? earlyLeaveMinutes,
    int? overtimeMinutes,
    String? notes,
    String? createdBy,
    bool? isDeleted,
  }) {
    return HRAttendanceModel(
      id: id ?? this.id,
      companyCode: companyCode ?? this.companyCode,
      branchCode: branchCode ?? this.branchCode,
      employeeCode: employeeCode ?? this.employeeCode,
      date: date ?? this.date,
      status: status ?? this.status,
      checkIn: checkIn ?? this.checkIn,
      checkOut: checkOut ?? this.checkOut,
      lateMinutes: lateMinutes ?? this.lateMinutes,
      earlyLeaveMinutes: earlyLeaveMinutes ?? this.earlyLeaveMinutes,
      overtimeMinutes: overtimeMinutes ?? this.overtimeMinutes,
      notes: notes ?? this.notes,
      createdBy: createdBy ?? this.createdBy,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  /// هل السجل ده "حضور فعلي" (يستحق راتب)؟
  ///
  /// يشمل: present, late, permission
  bool get isPresentStatus =>
      status == 'present' || status == 'late' || status == 'permission';

  /// هل السجل مكتمل (فيه check_in + check_out)؟
  bool get isComplete =>
      checkIn.isNotEmpty && checkOut.isNotEmpty;

  /// هل السجل لسه ما اترفعش على السيرفر؟
  bool get isPending => id == null;
}


// ============================================================
// 2. HRVacationModel — إجازة (رسمية/أسبوعية/استثنائية)
// ============================================================

/// نموذج الإجازة
///
/// نطاق الإجازة:
/// - كل الفروع:         branchCode=null, employeeCode=null
/// - فرع معين:          branchCode=X,    employeeCode=null
/// - موظف معين:         employeeCode=Y (branchCode دايمًا null)
class HRVacationModel {
  final int? id;
  final String companyCode;
  final String? branchCode;
  final String? employeeCode;
  final String date; // "YYYY-MM-DD"
  final String name;
  final String type; // official / weekly
  final String createdBy;
  final bool isDeleted;

  HRVacationModel({
    this.id,
    required this.companyCode,
    this.branchCode,
    this.employeeCode,
    required this.date,
    required this.name,
    this.type = 'official',
    this.createdBy = '',
    this.isDeleted = false,
  });

  factory HRVacationModel.fromMap(Map<String, dynamic> map) {
    return HRVacationModel(
      id: _toIntNullable(map['id']),
      companyCode: map['company_code']?.toString() ?? '',
      branchCode: (map['branch_code'] == null || map['branch_code'] == '')
          ? null
          : map['branch_code'].toString(),
      employeeCode:
          (map['employee_code'] == null || map['employee_code'] == '')
              ? null
              : map['employee_code'].toString(),
      date: map['date']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      type: map['type']?.toString() ?? 'official',
      createdBy: map['created_by']?.toString() ?? '',
      isDeleted: _toBool(map['is_deleted']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'company_code': companyCode,
      'branch_code': branchCode,
      'employee_code': employeeCode,
      'date': date,
      'name': name,
      'type': type,
      'created_by': createdBy,
      'is_deleted': isDeleted,
    };
  }

  /// هل تنطبق على الفرع المحدد؟
  bool appliesToBranch(String? targetBranch) {
    if (branchCode == null) return true;
    if (targetBranch == null) return false;
    return branchCode == targetBranch;
  }

  /// هل تنطبق على الموظف المحدد؟
  bool appliesToEmployee(String? targetEmployee) {
    if (employeeCode == null) return true;
    if (targetEmployee == null) return false;
    return employeeCode == targetEmployee;
  }

  /// هل تنطبق على موظف في فرع معين؟ (التحقق المشترك)
  ///
  /// المنطق:
  /// - إجازة موظف محدد → لازم تطابق employeeCode
  /// - إجازة عامة → نتحقق من الفرع
  bool appliesTo({String? targetBranch, String? targetEmployee}) {
    if (employeeCode != null) {
      return employeeCode == targetEmployee;
    }
    return appliesToBranch(targetBranch);
  }

  /// تسمية النطاق (للعرض في الواجهة)
  String get scopeLabel {
    if (employeeCode != null) return 'موظف: $employeeCode';
    if (branchCode != null) return 'فرع: $branchCode';
    return 'كل الفروع';
  }

  /// هل هي إجازة أسبوعية؟
  bool get isWeekly => type == 'weekly';

  /// هل هي إجازة رسمية؟
  bool get isOfficial => type == 'official';

  HRVacationModel copyWith({
    int? id,
    String? companyCode,
    String? branchCode,
    bool clearBranch = false,
    String? employeeCode,
    bool clearEmployee = false,
    String? date,
    String? name,
    String? type,
    String? createdBy,
    bool? isDeleted,
  }) {
    return HRVacationModel(
      id: id ?? this.id,
      companyCode: companyCode ?? this.companyCode,
      branchCode: clearBranch ? null : (branchCode ?? this.branchCode),
      employeeCode:
          clearEmployee ? null : (employeeCode ?? this.employeeCode),
      date: date ?? this.date,
      name: name ?? this.name,
      type: type ?? this.type,
      createdBy: createdBy ?? this.createdBy,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}


// ============================================================
// 3. HRAdjustmentModel — تسوية مالية (خصم/مكافأة/سلفة)
// ============================================================

/// نموذج التسوية المالية
///
/// الأنواع:
/// - deduction : خصم
/// - bonus     : مكافأة
/// - loan      : سلفة (كل قسط بيتسجل كصف منفصل)
class HRAdjustmentModel {
  final int? id;
  final String companyCode;
  final String branchCode;
  final String employeeCode;
  final String month; // "YYYY-MM"
  final String? date; // ⭐ جديد: "YYYY-MM-DD" (للخصومات المرتبطة بيوم)
  final String type;  // deduction / bonus / loan
  final double amount;
  final String reason;
  final String installmentRef; // للسلف: "1/3", "2/3", ...
  final String status;          // approved / pending / cancelled
  final String createdBy;
  final bool isDeleted;

  HRAdjustmentModel({
    this.id,
    required this.companyCode,
    required this.branchCode,
    required this.employeeCode,
    required this.month,
    this.date,  // ⭐ جديد
    required this.type,
    required this.amount,
    this.reason = '',
    this.installmentRef = '',
    this.status = 'approved',
    this.createdBy = '',
    this.isDeleted = false,
  });

  factory HRAdjustmentModel.fromMap(Map<String, dynamic> map) {
    return HRAdjustmentModel(
      id: _toIntNullable(map['id']),
      companyCode: map['company_code']?.toString() ?? '',
      branchCode: map['branch_code']?.toString() ?? '',
      employeeCode: map['employee_code']?.toString() ?? '',
      month: map['month']?.toString() ?? '',
      date: map['date'] == null || map['date'] == ''
          ? null
          : map['date'].toString(),  // ⭐ جديد
      type: map['type']?.toString() ?? '',
      amount: _toDouble(map['amount']),
      reason: map['reason']?.toString() ?? '',
      installmentRef: map['installment_ref']?.toString() ?? '',
      status: map['status']?.toString() ?? 'approved',
      createdBy: map['created_by']?.toString() ?? '',
      isDeleted: _toBool(map['is_deleted']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'company_code': companyCode,
      'branch_code': branchCode,
      'employee_code': employeeCode,
      'month': month,
      if (date != null && date!.isNotEmpty) 'date': date,  // ⭐ جديد
      'type': type,
      'amount': amount,
      'reason': reason,
      'installment_ref': installmentRef,
      'status': status,
      'created_by': createdBy,
      'is_deleted': isDeleted,
    };
  }

  HRAdjustmentModel copyWith({
    int? id,
    String? companyCode,
    String? branchCode,
    String? employeeCode,
    String? month,
    String? date,
    bool clearDate = false,  // ⭐ جديد
    String? type,
    double? amount,
    String? reason,
    String? installmentRef,
    String? status,
    String? createdBy,
    bool? isDeleted,
  }) {
    return HRAdjustmentModel(
      id: id ?? this.id,
      companyCode: companyCode ?? this.companyCode,
      branchCode: branchCode ?? this.branchCode,
      employeeCode: employeeCode ?? this.employeeCode,
      month: month ?? this.month,
      date: clearDate ? null : (date ?? this.date),
      type: type ?? this.type,
      amount: amount ?? this.amount,
      reason: reason ?? this.reason,
      installmentRef: installmentRef ?? this.installmentRef,
      status: status ?? this.status,
      createdBy: createdBy ?? this.createdBy,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  /// تسمية النوع بالعربي
  String get typeLabel {
    switch (type) {
      case 'deduction':
        return 'خصم';
      case 'bonus':
        return 'مكافأة';
      case 'loan':
        return 'سلفة';
      default:
        return type;
    }
  }

  /// هل دي سلفة؟
  bool get isLoan => type == 'loan';

  /// هل دي مكافأة؟
  bool get isBonus => type == 'bonus';

  /// هل ده خصم؟
  bool get isDeduction => type == 'deduction';

  /// هل التسوية معتمدة؟
  bool get isApproved => status == 'approved';

  /// هل هي قسط سلفة (لسه فيه أقساط)؟
  bool get isLoanInstallment => type == 'loan' && installmentRef.isNotEmpty;

  /// هل هي خصم مربوط بتاريخ معين؟
  bool get hasDate => date != null && date!.isNotEmpty;
}


// ============================================================
// 4. HREmployeeSettingsModel — إعدادات الموظف في HR
// ============================================================

/// نموذج إعدادات الموظف
///
/// ⚠️ مهم:
/// الـ `delayRules` الافتراضية بتيجي من `HRConstants.defaultDelayRules`
/// (مش من defaults محلية) — عشان نضمن التطابق مع الباك.
class HREmployeeSettingsModel {
  final int? id;
  final String companyCode;
  final String employeeCode;

  /// 0 = الأحد، 1 = الاثنين، ... 5 = الجمعة، 6 = السبت
  /// null = مفيش إجازة أسبوعية
  final int? weeklyVacationDay;

  final String defaultCheckIn;  // "HH:MM"
  final String defaultCheckOut; // "HH:MM"

  /// مرونة المواعيد: لو true، حساب الحضور بالمدة مش بالتوقيت
  final bool flexibleHours;
  final bool useFixedMonthDays; 
  /// قواعد التأخير والغياب
  /// كل قيمة = عدد أيام الخصم
  final Map<String, double> delayRules;

  HREmployeeSettingsModel({
    this.id,
    required this.companyCode,
    required this.employeeCode,
    this.weeklyVacationDay,
    this.defaultCheckIn = '09:00',
    this.defaultCheckOut = '17:00',
    this.flexibleHours = false,
    this.useFixedMonthDays = true, 
    Map<String, double>? delayRules,
  }) : delayRules = delayRules ?? Map.from(HRConstants.defaultDelayRules);

  factory HREmployeeSettingsModel.fromMap(Map<String, dynamic> map) {
    // تحويل delay_rules مع دمج القيم الافتراضية
    final Map<String, double> parsedRules =
        Map.from(HRConstants.defaultDelayRules);

    final rawRules = map['delay_rules'];
    if (rawRules is Map) {
      rawRules.forEach((k, v) {
        final key = k.toString();
        double? val;
        if (v is num) val = v.toDouble();
        if (v is String) val = double.tryParse(v);
        if (val != null) parsedRules[key] = val;
      });
    }

    return HREmployeeSettingsModel(
      id: _toIntNullable(map['id']),
      companyCode: map['company_code']?.toString() ?? '',
      employeeCode: map['employee_code']?.toString() ?? '',
      weeklyVacationDay: _toIntNullable(map['weekly_vacation_day']),
      defaultCheckIn: map['default_check_in']?.toString() ?? '09:00',
      defaultCheckOut: map['default_check_out']?.toString() ?? '17:00',
      flexibleHours: _toBool(map['flexible_hours']),
      useFixedMonthDays: map['use_fixed_month_days'] == null
          ? true
          : _toBool(map['use_fixed_month_days']), 
      delayRules: parsedRules,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'company_code': companyCode,
      'employee_code': employeeCode,
      'weekly_vacation_day': weeklyVacationDay,
      'default_check_in': defaultCheckIn,
      'default_check_out': defaultCheckOut,
      'flexible_hours': flexibleHours,
      'use_fixed_month_days': useFixedMonthDays,  
      'delay_rules': delayRules,
    };
  }

  HREmployeeSettingsModel copyWith({
    int? id,
    String? companyCode,
    String? employeeCode,
    int? weeklyVacationDay,
    bool clearWeekly = false,
    String? defaultCheckIn,
    String? defaultCheckOut,
    bool? flexibleHours,
    bool? useFixedMonthDays, 
    Map<String, double>? delayRules,
  }) {
    return HREmployeeSettingsModel(
      id: id ?? this.id,
      companyCode: companyCode ?? this.companyCode,
      employeeCode: employeeCode ?? this.employeeCode,
      weeklyVacationDay: clearWeekly
          ? null
          : (weeklyVacationDay ?? this.weeklyVacationDay),
      defaultCheckIn: defaultCheckIn ?? this.defaultCheckIn,
      defaultCheckOut: defaultCheckOut ?? this.defaultCheckOut,
      flexibleHours: flexibleHours ?? this.flexibleHours,
      useFixedMonthDays: useFixedMonthDays ?? this.useFixedMonthDays, 
      delayRules: delayRules ?? Map.from(this.delayRules),
    );
  }

  /// هل الموظف عنده إجازة أسبوعية محددة؟
  bool get hasWeeklyVacation => weeklyVacationDay != null;

  /// اسم يوم الإجازة الأسبوعية بالعربي (أو null لو مفيش)
  String? get weeklyDayLabel => weeklyVacationDay != null
      ? HRConstants.weekdayNameAr(weeklyVacationDay!)
      : null;

  /// هل التاريخ المحدد إجازة أسبوعية للموظف؟
  bool isWeeklyVacation(DateTime date) {
    return HRConstants.isWeeklyVacation(date, weeklyVacationDay);
  }
}


// ============================================================
// نهاية ملف hr_models.dart
//
// الموديلات:
// - HRAttendanceModel    : سجل حضور يومي
// - HRVacationModel      : إجازة (رسمية/أسبوعية/استثنائية)
// - HRAdjustmentModel    : تسوية (خصم/مكافأة/سلفة)
// - HREmployeeSettingsModel : إعدادات الموظف (مواعيد + قواعد تأخير)
//
// ملاحظات:
// - HRSalaryReportModel موجود في ملفه الخاص (hr_salary_report_model.dart)
//   لأنه نموذج قراءة فقط (response من الباك) — مش بيتحفظ في Hive.
// ============================================================