// lib/pages/hr/attendance_page.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/permissions_service.dart';  // ⭐ جديد
import '../../core/theme.dart';
import '../../core/hr_constants.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/employee_service.dart';
import '../../services/hr_service.dart';
import '../../services/hr_report_service.dart';
import '../../models/employee_model.dart';
import '../../models/hr_models.dart';
import 'dart:async';  // عشان unawaited

/// صفحة الحضور والانصراف
///
/// ⚠️ النسخة الجديدة:
/// - تعتمد على HRService (مش 4 services منفصلة)
/// - pending في Hive (مش في الذاكرة) → مايضيعش لو التطبيق اتقفل
/// - server fallback لتحميل الشهور القديمة
/// - إبطال كاش التقرير بعد أي حفظ
class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}


class _AttendancePageState extends State<AttendancePage> {
  // ============================================================
  // Services
  // ============================================================

  final EmployeeService _employeeService = EmployeeService();
  final HRService _hrService = HRService();
  final HRReportService _reportService = HRReportService();


  // ============================================================
  // State
  // ============================================================

  String _companyCode = '';
  bool _isLoading = true;
  bool _isSaving = false;

  List<EmployeeModel> _employees = [];
  EmployeeModel? _selectedEmployee;
  DateTime _selectedMonth = DateTime.now();

  // البيانات المحملة من Hive/السيرفر
    Map<String, HRAttendanceModel> _attendanceMap = {};
  Set<String> _vacationDates = {};
  HREmployeeSettingsModel? _employeeSettings;

  // ⭐ جديد: خصومات الشهر (للربط بين اليوم والخصم)
  List<HRAdjustmentModel> _monthAdjustments = [];


  // ============================================================
  // Constants
  // ============================================================

  static const int _graceMinutes = 15;
  static const List<String> _monthNamesAr = [
    'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
  ];
  static const List<String> _dayNamesAr = [
    'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس',
    'الجمعة', 'السبت', 'الأحد',
  ];


  // ============================================================
  // Getters — إعدادات الموظف
  // ============================================================

  String get _defaultCheckIn => _employeeSettings?.defaultCheckIn ?? '09:00';
  String get _defaultCheckOut => _employeeSettings?.defaultCheckOut ?? '17:00';
  int? get _weeklyVacationDay => _employeeSettings?.weeklyVacationDay;
  bool get _flexibleHours => _employeeSettings?.flexibleHours ?? false;


  // ============================================================
  // Getters — Pending
  // ============================================================

  /// عدد العمليات المعلقة للموظف الحالي (في كل الشهور)
  int get _pendingCount {
    if (_selectedEmployee == null) return 0;

    final allPending = _hrService.getAllPendingForCompany(_companyCode);
    final prefix = '${_companyCode}_${_selectedEmployee!.code}_';

    return allPending
        .where((p) => p['_key']?.toString().startsWith(prefix) ?? false)
        .length;
  }

  /// هل فيه تعديلات غير محفوظة؟
  bool get _hasUnsavedChanges => _pendingCount > 0;
    /// ⭐ هل يقدر المستخدم يحفظ؟ (أي صلاحية من الـ 3)
  bool get _canSaveChanges {
    final ps = PermissionsService();
    return ps.canAddAttendance ||
        ps.canEditAttendance ||
        ps.canDeleteAttendance;
  }


  // ============================================================
  // initState / dispose
  // ============================================================

  @override
  void initState() {
    super.initState();
    _loadEmployees();
  }


  // ============================================================
  // Helpers — تواريخ
  // ============================================================

  String _monthStr(DateTime dt) => HRConstants.monthToStr(dt);
  String _dateStr(DateTime dt) => HRConstants.dateToStr(dt);
  String _displayDate(DateTime dt) => '${dt.day}/${dt.month}';
  String _getDayName(DateTime dt) => _dayNamesAr[dt.weekday - 1];
  String _getMonthName(DateTime dt) =>
      '${_monthNamesAr[dt.month - 1]} ${dt.year}';
  int _daysInMonth(DateTime dt) => HRConstants.daysInMonth(dt);


  // ============================================================
  // Helper — هل التاريخ إجازة أسبوعية؟
  // ============================================================

  bool _isWeeklyVacationDay(DateTime date) {
    return HRConstants.isWeeklyVacation(date, _weeklyVacationDay);
  }


  // ============================================================
  // الخريطة الفعلية (Hive + Pending)
  //
  // ⭐ مهم: بندمج الـ pending فوق الـ attendance المحفوظ
  // عشان الـ UI يعرض آخر حالة يراها المستخدم.
  // ============================================================

  Map<String, HRAttendanceModel> _getEffectiveMap() {
    final result = Map<String, HRAttendanceModel>.from(_attendanceMap);

    if (_selectedEmployee == null) return result;

    final allPending = _hrService.getAllPendingForCompany(_companyCode);
    final prefix = '${_companyCode}_${_selectedEmployee!.code}_';

    for (final p in allPending) {
      final keyStr = p['_key']?.toString() ?? '';
      if (!keyStr.startsWith(prefix)) continue;

      // key = "{company}_{employee}_{YYYY-MM-DD}"
      final date = keyStr.substring(prefix.length);

      // فلترة على الشهر الحالي فقط
      if (!date.startsWith(_monthStr(_selectedMonth) + '-')) continue;

      final action = p['action']?.toString() ?? 'save';

      if (action == 'delete') {
        result.remove(date);
      } else if (action == 'save') {
        final data = p['data'];
        if (data is Map) {
          result[date] = HRAttendanceModel.fromMap(
            Map<String, dynamic>.from(data),
          );
        }
      }
    }

    return result;
  }


  // ============================================================
  // تحميل الموظفين
  // ============================================================

  Future<void> _loadEmployees() async {
    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      _companyCode = prefs.getString('company_code') ?? '';

      if (_companyCode.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

            final allEmployees = await _employeeService.getEmployeesList(
        companyCode: _companyCode,
      );

      // ⭐ فلترة حسب الصلاحيات (allowed_branches + hr_viewable_employees)
      _employees = allEmployees
          .where((e) => PermissionsService()
              .canViewEmployee(e.code, e.branchCode))
          .toList();

      if (_employees.isEmpty && allEmployees.isNotEmpty) {
        print('⚠️ لا يوجد موظفون مرئيون لهذا المستخدم');
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
          if (_employees.isNotEmpty && _selectedEmployee == null) {
            _selectedEmployee = _employees.first;
            _loadMonthData();
          }
        });
      }
    } catch (e) {
      print("❌ خطأ في تحميل الموظفين: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }


    // ============================================================
  // تحميل بيانات الشهر — من Hive فقط (local-first)
  //
  // ⭐ لو عايز تجيب من السيرفر: اضغط زر "تحديث" (بينادي _refreshFromServer)
  // ============================================================

  Future<void> _loadMonthData({bool showLoader = true}) async {
    if (_selectedEmployee == null) return;
    if (showLoader) setState(() => _isLoading = true);

    try {
      final monthStr = _monthStr(_selectedMonth);

      final settings = await _hrService.getEmployeeSettings(
        companyCode: _companyCode,
        employeeCode: _selectedEmployee!.code,
      );

      final attendance = await _hrService.getEmployeeMonthAttendance(
        companyCode: _companyCode,
        employeeCode: _selectedEmployee!.code,
        month: monthStr,
      );

      final vacations = await _hrService.getVacations(
        companyCode: _companyCode,
        fromDate: '$monthStr-01',
        toDate: '$monthStr-31',
        branchCode: _selectedEmployee!.branchCode,
        employeeCode: _selectedEmployee!.code,
      );

      final vacationSet = vacations.map((v) => v.date).toSet();

      final monthAdjustments = await _hrService.getAdjustmentsForMonth(
        companyCode: _companyCode,
        month: monthStr,
        branchCode: _selectedEmployee!.branchCode,
      );

      final deductions = monthAdjustments
          .where((a) =>
              a.employeeCode == _selectedEmployee!.code &&
              a.isDeduction)
          .toList();

      if (mounted) {
        setState(() {
          _employeeSettings = settings;
          _attendanceMap = attendance;
          _vacationDates = vacationSet;
          _monthAdjustments = deductions;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("❌ خطأ في تحميل بيانات الشهر: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// ⭐ تحديث من السيرفر — متوازي عشان يكون سريع
  Future<void> _refreshFromServer() async {
    setState(() => _isLoading = true);

    try {
      // ✅ تحميل متوازي بدل sequential
      await Future.wait([
        _hrService.fetchAllAttendance(_companyCode),
        _hrService.fetchAllVacations(_companyCode),
        _hrService.fetchAllAdjustments(_companyCode),
        _hrService.fetchAllEmployeeSettings(_companyCode),
      ]);

      await _reportService.invalidateCache(companyCode: _companyCode);

      if (!mounted) return;
      _showSnackBar(
        "تم التحديث من السيرفر ✅",
        AppTheme.successStrongFor(context),
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(
        "فشل التحديث: $e",
        AppTheme.dangerStrongFor(context),
      );
    } finally {
      if (mounted) {
        await _loadMonthData(showLoader: false);
      }
    }
  }


  // ============================================================
  // اختيار الشهر
  // ============================================================

  Future<void> _pickMonth() async {
    final canProceed = await _confirmSaveIfNeeded();
    if (!canProceed) return;

    final picked = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => _MonthPickerDialog(initial: _selectedMonth),
    );

    if (picked != null) {
      setState(() {
        _selectedMonth = DateTime(picked.year, picked.month, 1);
      });
      _loadMonthData();
    }
  }


  // ============================================================
  // تبديل الموظف
  // ============================================================

  Future<void> _onEmployeeChanged(EmployeeModel? v) async {
    if (v == null || v.code == _selectedEmployee?.code) return;

    final canProceed = await _confirmSaveIfNeeded();
    if (!canProceed) return;

    setState(() {
      _selectedEmployee = v;
      _attendanceMap = {};
      _vacationDates = {};
      _employeeSettings = null;
    });
    _loadMonthData();
  }


  /// قبل التنقل (تغيير موظف/شهر/خروج) — نحفظ تلقائياً بدون سؤال
  Future<bool> _confirmSaveIfNeeded() async {
    if (!_hasUnsavedChanges) return true;

    // ⭐ نحفظ فوراً بدون سؤال (optimistic save)
    await _saveAll();

    // نرجع true دايماً — مفيش خطر فقدان
    // (الـ pending في Hive، والرفع في الخلفية)
    return true;
  }


  // ============================================================
  // إحصائيات (بناءً على effective map + vacation dates)
  // ============================================================

  int get _presentDays => _getEffectiveMap().values
      .where((a) => a.isPresentStatus)
      .length;

  int get _absentDays => _getEffectiveMap().values
      .where((a) => a.status == 'absent')
      .length;

  int get _lateMinutesTotal => _getEffectiveMap()
      .values
      .fold(0, (sum, a) => sum + a.lateMinutes);

  int get _overtimeMinutesTotal => _getEffectiveMap()
      .values
      .fold(0, (sum, a) => sum + a.overtimeMinutes);

  int get _vacationDays {
    final effective = _getEffectiveMap();
    int count = 0;
    final days = _daysInMonth(_selectedMonth);

    for (int day = 1; day <= days; day++) {
      final date = DateTime(_selectedMonth.year, _selectedMonth.month, day);
      final str = _dateStr(date);

      // ⭐ لو فيه سجل حضور → مش إجازة (الموظف اشتغل)
      if (effective[str] != null) continue;

      if (_isWeeklyVacationDay(date)) {
        count++;
        continue;
      }
      if (_vacationDates.contains(str)) {
        count++;
      }
    }
    return count;
  }
    // ⭐ إجمالي الخصومات في الشهر (بالجنيه)
  double get _totalDiscountsAmount {
    return _monthAdjustments
        .where((a) => a.isDeduction)
        .fold<double>(0.0, (sum, a) => sum + a.amount);
  }

  // ⭐ إجمالي الخصومات في الشهر (بالأيام)
  int get _totalDiscountsDays {
    final dailyRate = (_selectedEmployee?.salary ?? 0) / 30;
    if (dailyRate <= 0) return 0;
    return (_totalDiscountsAmount / dailyRate).round();
  }
  

  // ============================================================
  // Helpers — وقت (HH:MM → دقائق)
  // ============================================================

  int _timeToMinutes(String time) {
    final parts = time.split(':');
    if (parts.length != 2) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return h * 60 + m;
  }

  int _calculateLateMinutes(String checkIn) {
    if (_flexibleHours) return 0;
    final actual = _timeToMinutes(checkIn);
    final expected = _timeToMinutes(_defaultCheckIn) + _graceMinutes;
    return actual > expected ? actual - _timeToMinutes(_defaultCheckIn) : 0;
  }

  int _calculateOvertimeMinutes(String checkOut) {
    if (_flexibleHours) return 0;
    final actual = _timeToMinutes(checkOut);
    final expected = _timeToMinutes(_defaultCheckOut);
    return actual > expected ? actual - expected : 0;
  }

  int _calculateEarlyLeave(String checkOut) {
    if (_flexibleHours) return 0;
    final actual = _timeToMinutes(checkOut);
    final expected = _timeToMinutes(_defaultCheckOut);
    return actual < expected ? expected - actual : 0;
  }


  // ============================================================
  // تسجيل حضور سريع (pending — يُحفظ في Hive فورًا)
  //
  // ⭐ التغيير الرئيسي:
  // - قبل: setState(_pendingAttendance[dateStr] = model)
  // - بعد: await _hrService.addPendingSave(model)
  //
  // الفايدة: pending في Hive → مايضيعش لو التطبيق اتقفل
  // ============================================================

    Future<void> _quickRecordAttendance(String dateStr) async {
    if (_selectedEmployee == null) return;

    // ⭐ فحص الصلاحية
    if (!PermissionsService().canAddAttendance) {
      _showSnackBar(
        "ليس لديك صلاحية تسجيل الحضور",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final effective = _getEffectiveMap();
    final existing = effective[dateStr];

    // لو اليوم مكتمل (فيه checkIn + checkOut) → متسجل بالفعل
    if (existing != null && existing.checkOut.isNotEmpty) {
      _showSnackBar(
        "اليوم مكتمل بالفعل",
        AppTheme.warningOrangeSoftFor(context),
      );
      return;
    }

    final lateMinutes = _calculateLateMinutes(_defaultCheckIn);
    final overtimeMinutes = _calculateOvertimeMinutes(_defaultCheckOut);
    final earlyLeave = _calculateEarlyLeave(_defaultCheckOut);

    final model = HRAttendanceModel(
      id: existing?.id,
      companyCode: _companyCode,
      branchCode: _selectedEmployee!.branchCode,
      employeeCode: _selectedEmployee!.code,
      date: dateStr,
      status: lateMinutes > 0 ? 'late' : 'present',
      checkIn: _defaultCheckIn,
      checkOut: _defaultCheckOut,
      lateMinutes: lateMinutes,
      overtimeMinutes: overtimeMinutes,
      earlyLeaveMinutes: earlyLeave,
      notes: existing?.notes ?? '',
    );

    // ⭐ حفظ في Hive (pending) بدل الذاكرة
    await _hrService.addPendingSave(model);

    if (!mounted) return;
    setState(() {}); // تحديث UI (الـ pending بقى في Hive)
    _showSnackBar(
      "تم التسجيل ✅",
      AppTheme.successFor(context),
    );
  }


  // ============================================================
  // تعديل/إدخال يوم (pending — يُحفظ في Hive فورًا)
  // ============================================================

    Future<void> _editDay(String dateStr) async {
    if (_selectedEmployee == null) return;

    // ⭐ فحص الصلاحية
    if (!PermissionsService().canEditAttendance) {
      _showSnackBar(
        "ليس لديك صلاحية تعديل الحضور",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final effective = _getEffectiveMap();
    final existing = effective[dateStr];

    final result = await showDialog<dynamic>(
      context: context,
      builder: (ctx) => _EditAttendanceDialog(
        existing: existing,
        companyCode: _companyCode,
        branchCode: _selectedEmployee!.branchCode,
        employeeCode: _selectedEmployee!.code,
        date: dateStr,
        defaultCheckIn: _defaultCheckIn,
        defaultCheckOut: _defaultCheckOut,
        flexibleHours: _flexibleHours,
      ),
    );

    if (result == null) return;

    // المستخدم اختار "حذف"
    if (result is String && result == 'delete') {
      await _deleteDay(dateStr);
      return;
    }

    // المستخدم حفظ تعديل
    if (result is HRAttendanceModel) {
      await _hrService.addPendingSave(result);

      if (!mounted) return;
      setState(() {});
      _showSnackBar(
        "تم التعديل ✅",
        AppTheme.successFor(context),
      );
    }
  }


  // ============================================================
  // حذف يوم (pending)
  //
  // منطق:
  // - لو السجل موجود على السيرفر (فيه id) → pending delete
  //   (لما المستخدم يدوس "حفظ"، بيتبعت DELETE API)
  // - لو السجل مش موجود (كان pending save بس) → امسح الـ pending
  // ============================================================

    Future<void> _deleteDay(String dateStr) async {
    if (_selectedEmployee == null) return;

    // ⭐ فحص الصلاحية
    if (!PermissionsService().canDeleteAttendance) {
      _showSnackBar(
        "ليس لديك صلاحية حذف الحضور",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final existing = _attendanceMap[dateStr];

    if (existing != null && existing.id != null) {
      // سجل موجود على السيرفر → pending delete
      await _hrService.addPendingDelete(
        companyCode: _companyCode,
        employeeCode: _selectedEmployee!.code,
        date: dateStr,
      );
    } else {
      // سجل جديد (كان pending save بس) → امسح الـ pending
      await _hrService.removePending(
        _companyCode,
        _selectedEmployee!.code,
        dateStr,
      );
    }

    if (!mounted) return;
    setState(() {});
    _showSnackBar(
      "تم الحذف — اضغط حفظ لتأكيد الكل",
      AppTheme.warningOrangeSoftFor(context),
    );
  }


  // ============================================================
  // خصم مباشر
  //
  // ⭐ التغيير الرئيسي:
  // - قبل: setState(_pendingAdjustments.add(adj))
  // - بعد: await _hrService.saveAdjustment(model: adj) — حفظ فوري
  //
  // ليه حفظ فوري مش pending؟
  // - الخصم عملية نادرة (مرة كل فين وفين)
  // - المستخدم متوقع إنه يتحفظ فورًا
  // - توفير تعقيد pending adjustments في الـ HRService
  // ============================================================

    // ============================================================
  // إدارة خصومات اليوم (فتح Dialog للعرض/الإضافة/الحذف)
  // ============================================================

    Future<void> _manageDiscounts(String dateStr) async {
    if (_selectedEmployee == null) return;
    if (_isSaving) return;

    // ⭐ فحص الصلاحية
    if (!PermissionsService().canAddDirectDiscount) {
      _showSnackBar(
        "ليس لديك صلاحية الخصم المباشر",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final dailyRate = _selectedEmployee!.salary / 30;
    final currentDiscounts = _getDayDiscounts(dateStr);

    await showDialog<void>(
      context: context,
      builder: (ctx) => _ManageDiscountsDialog(
        dateStr: dateStr,
        month: _getMonthName(_selectedMonth),
        dailyRate: dailyRate,
        initialDiscounts: currentDiscounts,
        onAdd: (days, reason) => _saveDiscount(
          dateStr: dateStr,
          days: days,
          reason: reason,
        ),
        onDelete: (id) => _deleteDiscount(id),
        onReload: () async => _getDayDiscounts(dateStr),
      ),
    );

    if (!mounted) return;
    setState(() {});
  }


  // ============================================================
  // حفظ خصم جديد بتاريخ محدد
  // ============================================================

  Future<bool> _saveDiscount({
    required String dateStr,
    required double days,
    required String reason,
  }) async {
    if (_selectedEmployee == null) return false;

    final dailyRate = _selectedEmployee!.salary / 30;
    final amount = dailyRate * days;

    final adj = HRAdjustmentModel(
      companyCode: _companyCode,
      branchCode: _selectedEmployee!.branchCode,
      employeeCode: _selectedEmployee!.code,
      month: _monthStr(_selectedMonth),
      date: dateStr,  // ⭐ مربوط باليوم
      type: 'deduction',
      amount: amount,
      reason: reason.isEmpty ? _buildDiscountReason(days) : reason,
      status: 'approved',
    );

    final saveResult = await _hrService.saveAdjustment(model: adj);

    if (saveResult['success'] != true) {
      print('❌ [save discount] ${saveResult['error']}');
      return false;
    }

    // إعادة تحميل الخصومات
    await _reloadAdjustments();

    // ⭐ إبطال كاش التقرير
    await _reportService.invalidateCache(
      companyCode: _companyCode,
      employeeCode: _selectedEmployee!.code,
      month: _monthStr(_selectedMonth),
    );

    return true;
  }


  // ============================================================
  // حذف خصم
  // ============================================================

  Future<bool> _deleteDiscount(int id) async {
    if (_selectedEmployee == null) return false;

    final ok = await _hrService.deleteAdjustment(
      companyCode: _companyCode,
      adjustmentId: id,
    );

    if (!ok) return false;

    // إعادة تحميل الخصومات
    await _reloadAdjustments();

    // إبطال كاش التقرير
    await _reportService.invalidateCache(
      companyCode: _companyCode,
      employeeCode: _selectedEmployee!.code,
      month: _monthStr(_selectedMonth),
    );

    return true;
  }

  

  // ============================================================
  // ⭐ Helpers — إدارة الخصومات على مستوى اليوم
  // ============================================================

  /// إرجاع خصومات اليوم المحدد
  List<HRAdjustmentModel> _getDayDiscounts(String dateStr) {
    return _monthAdjustments
        .where((a) => a.isDeduction && a.date == dateStr)
        .toList();
  }


  /// إعادة تحميل خصومات الشهر من السيرفر
  Future<void> _reloadAdjustments() async {
    if (_selectedEmployee == null) return;

    final all = await _hrService.getAdjustmentsForMonth(
      companyCode: _companyCode,
      month: _monthStr(_selectedMonth),
      branchCode: _selectedEmployee!.branchCode,
    );

    if (!mounted) return;

    setState(() {
      _monthAdjustments = all
          .where((a) =>
              a.employeeCode == _selectedEmployee!.code &&
              a.isDeduction)
          .toList();
    });
  }


  /// بناء سبب الخصم من عدد الأيام
  String _buildDiscountReason(double days) {
    if (days == 1) return 'خصم يوم';
    if (days == 0.25) return 'خصم ربع يوم';
    if (days == 0.5) return 'خصم نصف يوم';
    return 'خصم ${days.toStringAsFixed(2)} يوم';
  }
  // ============================================================
  // ⭐ حفظ فوري — الـ UI يتحدّث فوراً + الرفع في الخلفية
  //
  // التصميم:
  //   1. نحوّل الـ pending لـ local committed (optimistic save)
  //   2. نبدأ الرفع fire-and-forget
  //   3. المستخدم يشوف "تم الحفظ" فوراً
  //
  // الضمان:
  //   - الـ pending تفضل في Hive لحد ما الرفع ينجح
  //   - لو المستخدم قفل التطبيق → retryAllPending يرفعها لما يرجع
  // ============================================================

  Future<void> _saveAll() async {
    if (_selectedEmployee == null) return;
    if (!_hasUnsavedChanges) return;
    if (_isSaving) return;

    if (!_canSaveChanges) {
      _showSnackBar(
        "ليس لديك صلاحية حفظ التعديلات",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final pendingCount = _pendingCount;

    // ✅ 1) Optimistic local save: نمسك الـ effective map (اللي فيه الـ pending)
    //    ونخليه هو الـ attendanceMap — يعني الأيام تظهر كأنها محفوظة
    final effective = _getEffectiveMap();

    setState(() {
      _attendanceMap = effective;
    });

    // ✅ 2) نبدأ الرفع في الخلفية (fire-and-forget) — مش بنستنى
    unawaited(_hrService.commitPendingFast(
      companyCode: _companyCode,
      employeeCode: _selectedEmployee!.code,
    ));

    // ✅ 3) نمسح كاش التقرير (fire-and-forget)
    unawaited(_reportService.invalidateCache(
      companyCode: _companyCode,
      employeeCode: _selectedEmployee!.code,
    ));

    // ✅ 4) setState عشان النقط البرتقالية تختفي فوراً
    setState(() {});

    // ✅ 5) snackbar سريع
    _showSnackBar(
      pendingCount > 1
          ? "تم حفظ $pendingCount تعديل ✅"
          : "تم الحفظ ✅",
      AppTheme.successStrongFor(context),
    );
  }


  // ============================================================
  // SnackBar helper
  // ============================================================

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: color,
      ),
    );
  }

 

  // ============================================================
  // build
  // ============================================================

    @override
  Widget build(BuildContext context) {
    // ⭐ فحص صلاحية فتح الصفحة
    if (!PermissionsService().canOpenAttendancePage) {
      return _buildNoPermissionScreen('عرض الحضور');
    }

    return PopScope(
      canPop: !_hasUnsavedChanges,
      onPopInvoked: (didPop) async {
        if (didPop) return;

        final canProceed = await _confirmSaveIfNeeded();
        if (canProceed && mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text(
            "الحضور والانصراف",
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMainFor(context),
            ),
          ),
          centerTitle: true,
          backgroundColor: AppTheme.appBarBg,
          elevation: 0,
          iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
          actions: [
            // ============================================
            // زر الحفظ (مع badge عدد التعديلات)
            // ============================================
            if (_canSaveChanges)
              Stack(
                clipBehavior: Clip.none,
                children: [
                  
                  IconButton(
                    icon: Icon(
                      _hasUnsavedChanges
                          ? Icons.save_rounded
                          : Icons.save_outlined,
                      color: _hasUnsavedChanges
                          ? AppTheme.successStrongFor(context)
                          : AppTheme.textMutedFor(context),
                    ),
                    onPressed: _hasUnsavedChanges ? _saveAll : null,
                    tooltip: _hasUnsavedChanges
                        ? 'حفظ $_pendingCount تعديل'
                        : 'لا توجد تعديلات',
                  ),
                  if (_hasUnsavedChanges)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.dangerFor(context),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _pendingCount > 99 ? '99+' : '$_pendingCount',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ),
                    ),
                ],
              ),

                        // زر التحديث من السيرفر
            IconButton(
              icon: Icon(
                Icons.refresh_rounded,
                color: AppTheme.textMainFor(context),
              ),
              onPressed: _isSaving ? null : _refreshFromServer,
              tooltip: 'تحديث من السيرفر',
            ),
          ],
        ),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: AppTheme.dashGradientMain(context),
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: _isLoading
                ? Center(
                    child: CircularProgressIndicator(
                      color: AppTheme.accentFor(context),
                    ),
                  )
                : _employees.isEmpty
                    ? _buildEmptyState()
                    : _buildScrollableContent(),
          ),
        ),
      ),
    );
  }


  // ============================================================
  // Empty state (مفيش موظفين)
  // ============================================================

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.people_outline_rounded,
            size: 64,
            color: AppTheme.textMutedFor(context),
          ),
          const SizedBox(height: 12),
          Text(
            'لا يوجد موظفون مسجلون',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'أضف موظفين من صفحة التكويد أولاً',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // المحتوى (Header + أيام الشهر في ListView واحد)
  // ============================================================

  Widget _buildScrollableContent() {
    final daysCount = _daysInMonth(_selectedMonth);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(15, 15, 15, 15),
      itemCount: daysCount + 1, // +1 للـ header
      itemBuilder: (context, index) {
        // Header
        if (index == 0) {
          return _buildHeader();
        }

        // يوم
        final day = index;
        final date = DateTime(
          _selectedMonth.year,
          _selectedMonth.month,
          day,
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildDayCard(date),
        );
      },
    );
  }


  // ============================================================
  // Header (Dropdown + Month + Stats)
  // ============================================================

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          // Dropdown الموظف
          GlassCard(
            padding: const EdgeInsets.all(8),
            child: DropdownButtonFormField<EmployeeModel>(
              initialValue: _selectedEmployee,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'الموظف',
                labelStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
                prefixIcon: Icon(
                  Icons.person_rounded,
                  color: AppTheme.accentFor(context),
                  size: 20,
                ),
                filled: true,
                fillColor: GlassStyle.fill05For(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: _employees
                  .map((e) => DropdownMenuItem(
                        value: e,
                        child: Text(
                          '${e.name} (${e.code})',
                          style: const TextStyle(fontFamily: 'Cairo'),
                        ),
                      ))
                  .toList(),
              onChanged: _isSaving ? null : _onEmployeeChanged,
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontSize: 14,
              ),
            ),
          ),

          const SizedBox(height: 10),

          // زر اختيار الشهر
          GlassCard(
            padding: const EdgeInsets.all(4),
            child: InkWell(
              onTap: _isSaving ? null : _pickMonth,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_month_rounded,
                      color: AppTheme.warningFor(context),
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'الشهر',
                            style: TextStyle(
                              color: AppTheme.textMutedFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            _getMonthName(_selectedMonth),
                            style: TextStyle(
                              color: AppTheme.textMainFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.edit_rounded,
                      color: AppTheme.textMutedFor(context),
                      size: 16,
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 10),

          _buildStatsRow(),
        ],
      ),
    );
  }


  // ============================================================
  // الإحصائيات
  // ============================================================

    Widget _buildStatsRow() {
    final canSeeAmounts = PermissionsService().canViewSalaryAmounts;

    return GlassCard(
      padding: const EdgeInsets.all(10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _buildStatChip(
            'حاضر',
            '$_presentDays',
            AppTheme.successFor(context),
          ),
          _buildStatChip(
            'غائب',
            '$_absentDays',
            AppTheme.dangerFor(context),
          ),
          _buildStatChip(
            'إجازة',
            '$_vacationDays',
            AppTheme.extraTealFor(context),
          ),
          _buildStatChip(
            'تأخير',
            '$_lateMinutesTotal د',
            AppTheme.warningOrangeSoftFor(context),
          ),
          _buildStatChip(
            'إضافي',
            '$_overtimeMinutesTotal د',
            AppTheme.accentFor(context),
          ),
          _buildStatChip(
            'خصم',
            canSeeAmounts
                ? '${_totalDiscountsAmount.toStringAsFixed(0)} ج.م'
                : '$_totalDiscountsDays يوم',
            AppTheme.dangerStrongFor(context),
          ),
        ],
      ),
    );
  }


    Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      constraints: const BoxConstraints(minWidth: 60),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontFamily: 'Cairo',
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }

  

  // ============================================================
  // بطاقة اليوم
  //
  // ⭐ منطق الحالة (نفس النسخة القديمة):
  //   1. لو فيه سجل حضور → اعرض حالته (present/late/absent/vacation/permission)
  //   2. لو مفيش سجل + إجازة رسمية → "إجازة"
  //   3. لو مفيش سجل + راحة أسبوعية → "راحة"
  //   4. لو مستقبل → "قادم"
  //   5. لو مفيش سجل + مفيش إجازة → "غير مسجل"
  //
  // ⭐ جديد:
  // - Border أحمر/برتقالي لو اليوم فيه pending
  // - نقطة برتقالية صغيرة بجانب اسم اليوم
  // ============================================================

  Widget _buildDayCard(DateTime date) {
    final dateStr = _dateStr(date);
    final effective = _getEffectiveMap();
    final attendance = effective[dateStr];
    final isVacation = _vacationDates.contains(dateStr);
    final isWeeklyVacation = _isWeeklyVacationDay(date);
    final isFuture = date.isAfter(DateTime.now());
    final isPending = _selectedEmployee != null &&
        _hrService.hasPending(
          _companyCode,
          _selectedEmployee!.code,
          dateStr,
        );
        // ⭐ جديد: خصومات اليوم
    final dayDiscounts = _getDayDiscounts(dateStr);
    final hasDiscount = dayDiscounts.isNotEmpty;
    final totalDiscountAmount =
        dayDiscounts.fold<double>(0, (sum, d) => sum + d.amount);

    // ============================================================
    // تحديد الحالة (الأولوية لسجل الحضور)
    // ============================================================
    Color statusColor;
    IconData statusIcon;
    String statusLabel;

    if (attendance != null) {
      // 1️⃣ فيه سجل → اعرض حالته
      if (attendance.status == 'absent') {
        statusColor = AppTheme.dangerFor(context);
        statusIcon = Icons.cancel_rounded;
        statusLabel = 'غائب';
      } else if (attendance.status == 'vacation') {
        statusColor = AppTheme.extraTealFor(context);
        statusIcon = Icons.beach_access_rounded;
        statusLabel = 'إجازة';
      } else if (attendance.status == 'permission') {
        statusColor = AppTheme.infoFor(context);
        statusIcon = Icons.assignment_turned_in_rounded;
        statusLabel = 'إذن';
      } else if (attendance.lateMinutes > 0) {
        statusColor = AppTheme.warningOrangeSoftFor(context);
        statusIcon = Icons.timer_rounded;
        statusLabel = 'متأخر ${attendance.lateMinutes}د';
      } else {
        statusColor = AppTheme.successFor(context);
        statusIcon = Icons.check_circle_rounded;
        statusLabel = 'حاضر';
      }
    } else if (isVacation) {
      // 2️⃣ مفيش سجل + إجازة رسمية
      statusColor = AppTheme.extraTealFor(context);
      statusIcon = Icons.beach_access_rounded;
      statusLabel = 'إجازة';
    } else if (isWeeklyVacation) {
      // 3️⃣ مفيش سجل + راحة أسبوعية
      statusColor = AppTheme.extraTealFor(context);
      statusIcon = Icons.weekend_rounded;
      statusLabel = 'راحة';
    } else if (isFuture) {
      // 4️⃣ مستقبل
      statusColor = AppTheme.textMutedFor(context);
      statusIcon = Icons.schedule_rounded;
      statusLabel = 'قادم';
    } else {
      // 5️⃣ مفيش سجل + مفيش إجازة
      statusColor = AppTheme.textMutedFor(context);
      statusIcon = Icons.help_outline_rounded;
      statusLabel = 'غير مسجل';
    }

    // ============================================================
    // الأعلام
    // ============================================================

    final hasTimes = attendance != null &&
        attendance.checkIn.isNotEmpty &&
        (attendance.status == 'present' || attendance.status == 'late');

    final isComplete = attendance != null && attendance.checkOut.isNotEmpty;
    final hasRecord = attendance != null;

    // ============================================================
    // الأزرار: تظهر في أي يوم **مش مستقبلي**
    // (بما فيها الإجازات والراحة الأسبوعية)
    // ============================================================
    final showActions = !isFuture;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isPending
              ? AppTheme.warningFor(context).withValues(alpha: 0.6)
              : GlassStyle.line10For(context),
          width: isPending ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          // ============================================
          // أيقونة الحالة
          // ============================================
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(statusIcon, size: 13, color: statusColor),
              ),
              // نقطة pending (صغيرة — فوق اليمين)
              if (isPending)
                Positioned(
                  top: -1,
                  right: -1,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppTheme.warningOrangeSoftFor(context),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppTheme.appBarBg,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 8),

          // ============================================
          // اليوم والتاريخ
          // ============================================
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _getDayName(date),
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                _displayDate(date),
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 9,
                ),
              ),
            ],
          ),

          const SizedBox(width: 6),

          // ============================================
          // الأوقات / الحالة
          // ============================================
                    Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // الحالة / الأوقات (زي ما هي)
                if (hasTimes)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.login_rounded,
                          size: 10,
                          color: AppTheme.successFor(context),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          attendance.checkIn,
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 8,
                          color: AppTheme.textMutedFor(context),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          Icons.logout_rounded,
                          size: 10,
                          color: attendance.checkOut.isNotEmpty
                              ? AppTheme.dangerFor(context)
                              : AppTheme.textMutedFor(context),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          attendance.checkOut.isNotEmpty
                              ? attendance.checkOut
                              : '—',
                          style: TextStyle(
                            color: attendance.checkOut.isNotEmpty
                                ? AppTheme.textMainFor(context)
                                : AppTheme.warningOrangeSoftFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontFamily: 'Cairo',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                // ⭐ Badge الخصم (لو موجود)
                if (hasDiscount) ...[
                  const SizedBox(height: 2),
                  _buildDiscountBadge(totalDiscountAmount),
                ],
              ],
            ),
          ),

                    // ============================================
          // الأزرار (تظهر في كل يوم غير مستقبلي + حسب الصلاحيات)
          // ============================================
          if (showActions) ...[
            // تسجيل اليوم
            if (PermissionsService().canAddAttendance)
              _iconBtn(
                icon: isComplete
                    ? Icons.check_rounded
                    : Icons.fingerprint_rounded,
                color: isComplete
                    ? AppTheme.successFor(context).withValues(alpha: 0.4)
                    : AppTheme.successFor(context),
                tooltip: isComplete ? 'مكتمل' : 'تسجيل اليوم',
                onTap: isComplete
                    ? null
                    : () => _quickRecordAttendance(dateStr),
              ),

            // إدخال / تعديل
            if (PermissionsService().canEditAttendance)
              _iconBtn(
                icon: hasRecord ? Icons.edit_rounded : Icons.add_rounded,
                color: AppTheme.accentFor(context),
                tooltip: hasRecord ? 'تعديل' : 'إدخال',
                onTap: () => _editDay(dateStr),
              ),

            // خصم مباشر
            if (PermissionsService().canAddDirectDiscount)
              _iconBtn(
                icon: Icons.money_off_rounded,
                color: hasDiscount
                    ? AppTheme.dangerFor(context)
                    : AppTheme.warningOrangeSoftFor(context),
                tooltip: hasDiscount
                    ? 'إدارة الخصومات (${dayDiscounts.length})'
                    : 'خصم مباشر',
                onTap: () => _manageDiscounts(dateStr),
              ),

            // حذف (لو فيه سجل)
            if (hasRecord && PermissionsService().canDeleteAttendance)
              _iconBtn(
                icon: Icons.delete_outline_rounded,
                color: AppTheme.dangerFor(context),
                tooltip: 'حذف',
                onTap: () => _deleteDay(dateStr),
              ),
          ],
        ],
      ),
    );
  }
  

  // ============================================================
  // ⭐ Badge صغير لعرض الخصم على بطاقة اليوم
  // ============================================================

    Widget _buildDiscountBadge(double totalAmount) {
    final canSeeAmounts = PermissionsService().canViewSalaryAmounts;
    final label = canSeeAmounts
        ? 'خصم ${totalAmount.toStringAsFixed(0)}'
        : 'خصم';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.dangerFor(context).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.money_off_rounded,
            size: 9,
            color: AppTheme.dangerFor(context),
          ),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.dangerFor(context),
              fontFamily: 'Cairo',
              fontSize: 8,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // زر أيقونة صغير (helper)
  // ============================================================

  Widget _iconBtn({
    required IconData icon,
    required Color color,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            icon,
            size: 16,
            color: enabled ? color : color.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  // ⭐ شاشة "لا صلاحية"
  Widget _buildNoPermissionScreen(String permission) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "الحضور والانصراف",
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMainFor(context),
          ),
        ),
        centerTitle: true,
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientMain(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 64,
                  color: AppTheme.textMutedFor(context),
                ),
                const SizedBox(height: 12),
                Text(
                  'ليس لديك صلاحية $permission',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}


// ============================================================
// Dialog 1: اختيار الشهر
// ============================================================

class _MonthPickerDialog extends StatefulWidget {
  final DateTime initial;
  const _MonthPickerDialog({required this.initial});

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}


class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _year;
  late int _month;

  static const List<String> _months = [
    'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
  ];

  @override
  void initState() {
    super.initState();
    _year = widget.initial.year;
    _month = widget.initial.month;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.accentFor(context),
            ),
            onPressed: () => setState(() => _year--),
          ),
          Expanded(
            child: Text(
              '$_year',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.chevron_left_rounded,
              color: AppTheme.accentFor(context),
            ),
            onPressed: () => setState(() => _year++),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2,
          children: List.generate(12, (index) {
            final m = index + 1;
            final isSelected = m == _month;

            return InkWell(
              onTap: () => setState(() => _month = m),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.accentFor(context).withValues(alpha: 0.2)
                      : GlassStyle.fill05For(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected
                        ? AppTheme.accentFor(context)
                        : GlassStyle.line10For(context),
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Text(
                  _months[index],
                  style: TextStyle(
                    color: isSelected
                        ? AppTheme.accentFor(context)
                        : AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'إلغاء',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
            ),
          ),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, DateTime(_year, _month, 1)),
          child: Text(
            'اختيار',
            style: TextStyle(
              color: AppTheme.accentFor(context),
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}




// ============================================================
// Dialog: إدارة الخصومات (عرض + إضافة + حذف)
//
// ⭐ الفروق عن _DiscountDialog القديمة:
// 1. بتعرض الخصومات الموجودة (لو فيه)
// 2. زر حذف لكل خصم
// 3. تفضل مفتوحة بعد كل عملية (تقدر تضيف/تحذف بسرعة)
// 4. Badge حي بقيمة الخصم
// 5. الـ parent بيتولى API + Cache Invalidation
//    (الـ dialog مسؤول عن UI + state فقط)
// ============================================================

class _ManageDiscountsDialog extends StatefulWidget {
  /// تاريخ اليوم (YYYY-MM-DD)
  final String dateStr;

  /// اسم الشهر (للعرض)
  final String month;

  /// قيمة اليوم (salary / 30)
  final double dailyRate;

  /// الخصومات الموجودة حالياً لهذا اليوم
  final List<HRAdjustmentModel> initialDiscounts;

  /// Callback: إضافة خصم جديد
  /// يرجّع true لو نجح
  final Future<bool> Function(double days, String reason) onAdd;

  /// Callback: حذف خصم بـ id
  /// يرجّع true لو نجح
  final Future<bool> Function(int id) onDelete;

  /// Callback: إعادة تحميل الخصومات من السيرفر
  /// يرجّع قائمة محدثة
  final Future<List<HRAdjustmentModel>> Function() onReload;

  const _ManageDiscountsDialog({
    required this.dateStr,
    required this.month,
    required this.dailyRate,
    required this.initialDiscounts,
    required this.onAdd,
    required this.onDelete,
    required this.onReload,
  });

  @override
  State<_ManageDiscountsDialog> createState() =>
      _ManageDiscountsDialogState();
}


class _ManageDiscountsDialogState extends State<_ManageDiscountsDialog> {
  // ============================================================
  // State
  // ============================================================

  late List<HRAdjustmentModel> _discounts;
  final _daysCtrl = TextEditingController(text: '1');
  final _reasonCtrl = TextEditingController();
  bool _isProcessing = false;
  String? _errorMessage;

  // ============================================================
  // Lifecycle
  // ============================================================

  @override
  void initState() {
    super.initState();
    _discounts = List.from(widget.initialDiscounts);
  }

  @override
  void dispose() {
    _daysCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  // ============================================================
  // Getters
  // ============================================================

  double get _days => double.tryParse(_daysCtrl.text) ?? 0;
  double get _newAmount => widget.dailyRate * _days;
  double get _totalAmount =>
      _discounts.fold<double>(0.0, (sum, d) => sum + d.amount);

  // ============================================================
  // Handlers
  // ============================================================

  Future<void> _handleAdd() async {
    if (_days <= 0) return;
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    final reason = _reasonCtrl.text.trim();

    try {
      final ok = await widget.onAdd(_days, reason);

      if (!mounted) return;

      if (ok) {
        // إعادة تحميل القائمة من الـ parent
        final updated = await widget.onReload();
        if (!mounted) return;

        setState(() {
          _discounts = updated;
          _isProcessing = false;
        });

        // تصفير الفورم
        _daysCtrl.text = '1';
        _reasonCtrl.clear();
      } else {
        setState(() {
          _isProcessing = false;
          _errorMessage = 'فشل حفظ الخصم. حاول مرة أخرى.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _errorMessage = 'خطأ: $e';
      });
    }
  }


  Future<void> _handleDelete(HRAdjustmentModel discount) async {
    if (discount.id == null) return;
    if (_isProcessing) return;

    // تأكيد الحذف
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Text(
          'حذف الخصم',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'سيتم حذف "${discount.reason}" '
          'بقيمة ${discount.amount.toStringAsFixed(2)} ج.م.',
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'إلغاء',
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'حذف',
              style: TextStyle(
                color: AppTheme.dangerFor(context),
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final ok = await widget.onDelete(discount.id!);

      if (!mounted) return;

      if (ok) {
        final updated = await widget.onReload();
        if (!mounted) return;

        setState(() {
          _discounts = updated;
          _isProcessing = false;
        });
      } else {
        setState(() {
          _isProcessing = false;
          _errorMessage = 'فشل حذف الخصم. حاول مرة أخرى.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _errorMessage = 'خطأ: $e';
      });
    }
  }


  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      title: Row(
        children: [
          Icon(
            Icons.money_off_rounded,
            color: AppTheme.warningOrangeSoftFor(context),
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'إدارة الخصومات',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInfoCard(),
              const SizedBox(height: 12),
              if (_discounts.isNotEmpty) ...[
                _buildExistingDiscountsSection(),
                const SizedBox(height: 12),
              ],
              _buildAddNewSection(),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                _buildErrorBox(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _isProcessing ? null : () => Navigator.pop(context),
          child: Text(
            'إغلاق',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }


  // ============================================================
  // بطاقة المعلومات (التاريخ + الشهر + قيمة اليوم)
  // ============================================================

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.calendar_today_rounded,
                color: AppTheme.accentFor(context),
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${widget.dateStr} • ${widget.month}',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
                    // ⭐ يظهر "قيمة اليوم" فقط لو عنده صلاحية رؤية المبالغ
          if (PermissionsService().canViewSalaryAmounts) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.attach_money_rounded,
                  color: AppTheme.successFor(context),
                  size: 14,
                ),
                const SizedBox(width: 6),
                Text(
                  'قيمة اليوم: ${widget.dailyRate.toStringAsFixed(2)} ج.م',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }


  // ============================================================
  // قسم الخصومات الموجودة
  // ============================================================

  Widget _buildExistingDiscountsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header + إجمالي
        Row(
          children: [
            Icon(
              Icons.list_alt_rounded,
              color: AppTheme.dangerFor(context),
              size: 16,
            ),
            const SizedBox(width: 6),
            Text(
              'الخصومات الموجودة (${_discounts.length})',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
                        const Spacer(),
            // ⭐ الإجمالي يظهر فقط لو عنده صلاحية
            if (PermissionsService().canViewSalaryAmounts)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.dangerFor(context).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${_totalAmount.toStringAsFixed(2)} ج.م',
                  style: TextStyle(
                    color: AppTheme.dangerFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),

        // قائمة الخصومات
        ..._discounts.map(_buildDiscountRow),
      ],
    );
  }


  // ============================================================
  // صف خصم واحد
  // ============================================================

  Widget _buildDiscountRow(HRAdjustmentModel discount) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.dangerFor(context).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppTheme.dangerFor(context).withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.remove_circle_rounded,
            color: AppTheme.dangerFor(context),
            size: 16,
          ),
          const SizedBox(width: 8),

          // السبب + المبلغ
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  discount.reason.isNotEmpty
                      ? discount.reason
                      : 'خصم',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                                // ⭐ المبلغ يظهر فقط لو عنده صلاحية
                if (PermissionsService().canViewSalaryAmounts)
                  Text(
                    '${discount.amount.toStringAsFixed(2)} ج.م',
                    style: TextStyle(
                      color: AppTheme.dangerFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),

          // زر حذف
          IconButton(
            icon: Icon(
              Icons.delete_outline_rounded,
              color: AppTheme.dangerFor(context),
              size: 18,
            ),
            onPressed: _isProcessing
                ? null
                : () => _handleDelete(discount),
            tooltip: 'حذف',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // قسم إضافة خصم جديد
  // ============================================================

  Widget _buildAddNewSection() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.warningOrangeSoftFor(context).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.warningOrangeSoftFor(context).withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Icons.add_circle_rounded,
                color: AppTheme.warningOrangeSoftFor(context),
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                'إضافة خصم جديد',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // عدد الأيام
          TextField(
            controller: _daysCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            enabled: !_isProcessing,
            onChanged: (v) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'عدد الأيام',
              hintText: 'مثال: 1 أو 0.5 أو 0.25',
              labelStyle: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
                fontSize: 12,
              ),
              filled: true,
              fillColor: GlassStyle.fill05For(context),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMainFor(context),
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),

          // أزرار سريعة
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final v in [0.25, 0.5, 1.0, 2.0, 3.0])
                InkWell(
                  onTap: _isProcessing
                      ? null
                      : () => setState(() => _daysCtrl.text = v.toString()),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: GlassStyle.fill05For(context),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: GlassStyle.line10For(context),
                      ),
                    ),
                    child: Text(
                      _daysLabel(v),
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // السبب (اختياري)
          TextField(
            controller: _reasonCtrl,
            enabled: !_isProcessing,
            maxLines: 1,
            decoration: InputDecoration(
              labelText: 'السبب (اختياري)',
              hintText: 'مثال: تأخير / غياب بدون إذن',
              labelStyle: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
                fontSize: 12,
              ),
              filled: true,
              fillColor: GlassStyle.fill05For(context),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMainFor(context),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),

          // Badge القيمة الحية + زر إضافة
          Row(
            children: [
                            // Badge القيمة (يظهر فقط لو عنده صلاحية رؤية المبالغ)
              if (PermissionsService().canViewSalaryAmounts)
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.warningOrangeSoftFor(context)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.warningOrangeSoftFor(context)
                            .withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'قيمة الخصم',
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 9,
                          ),
                        ),
                        Text(
                          '${_newAmount.toStringAsFixed(2)} ج.م',
                          style: TextStyle(
                            color: AppTheme.warningOrangeSoftFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ⭐ لو مفيش صلاحية، الزر ياخد المساحة كلها
              if (!PermissionsService().canViewSalaryAmounts)
                const Spacer(),
              const SizedBox(width: 8),

              // زر الإضافة
              ElevatedButton.icon(
                onPressed: (_isProcessing || _days <= 0)
                    ? null
                    : _handleAdd,
                icon: _isProcessing
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.onAccentFor(context),
                        ),
                      )
                    : const Icon(Icons.add_rounded, size: 16),
                label: Text(
                  _isProcessing ? 'جاري...' : 'إضافة',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.warningOrangeSoftFor(context),
                  foregroundColor: AppTheme.onAccentFor(context),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }


  // ============================================================
  // صندوق الخطأ
  // ============================================================

  Widget _buildErrorBox() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.dangerFor(context).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppTheme.dangerFor(context).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: AppTheme.dangerFor(context),
            size: 14,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: AppTheme.dangerFor(context),
                fontFamily: 'Cairo',
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // Helper: تسمية عدد الأيام
  // ============================================================

  String _daysLabel(double v) {
    if (v == 0.25) return 'ربع يوم';
    if (v == 0.5) return 'نصف يوم';
    if (v == 1) return 'يوم';
    if (v == 2) return 'يومان';
    return '$v أيام';
  }
}

// ============================================================
// نهاية ملف attendance_page.dart
//
// الملف بيستخدم:
// - HRService: عمليات attendance + pending + adjustments
// - HRReportService: إبطال كاش التقرير بعد الحفظ
// - EmployeeService: جلب قائمة الموظفين
// - HRConstants: helpers للتواريخ + isWeeklyVacation
// - HRAttendanceModel, HREmployeeSettingsModel, HRAdjustmentModel: من hr_models.dart
//
// الفروق الرئيسية عن النسخة القديمة:
// 1. 3 services بدل 5 (HRService موحد)
// 2. Pending في Hive (مش الذاكرة) → مايضيعش لو التطبيق اتقفل
// 3. server fallback للشهور القديمة (getEmployeeMonthAttendance)
// 4. إبطال كاش التقرير بعد كل حفظ/تعديل/حذف
// 5. Badge عددي على زر الحفظ
// 6. نقطة برتقالية على أيام الـ pending
// 7. ⭐ خصومات مرتبطة بتاريخ اليوم (date في HRAdjustment)
// 8. ⭐ Badge "خصم" على اليوم في _buildDayCard
// 9. ⭐ Dialog إدارة الخصومات (عرض + إضافة + حذف بدون إغلاق)
// ============================================================


// ============================================================
// Dialog 3: إدخال / تعديل الحضور
// ============================================================

class _EditAttendanceDialog extends StatefulWidget {
  final HRAttendanceModel? existing;
  final String companyCode;
  final String branchCode;
  final String employeeCode;
  final String date;
  final String defaultCheckIn;
  final String defaultCheckOut;
  final bool flexibleHours;

  const _EditAttendanceDialog({
    this.existing,
    required this.companyCode,
    required this.branchCode,
    required this.employeeCode,
    required this.date,
    required this.defaultCheckIn,
    required this.defaultCheckOut,
    required this.flexibleHours,
  });

  @override
  State<_EditAttendanceDialog> createState() => _EditAttendanceDialogState();
}


class _EditAttendanceDialogState extends State<_EditAttendanceDialog> {
  late String _status;
  late String _checkIn;
  late String _checkOut;
  late TextEditingController _notesCtrl;

  @override
  void initState() {
    super.initState();
    _status = widget.existing?.status ?? 'present';
    _checkIn = widget.existing?.checkIn.isNotEmpty == true
        ? widget.existing!.checkIn
        : widget.defaultCheckIn;
    _checkOut = widget.existing?.checkOut.isNotEmpty == true
        ? widget.existing!.checkOut
        : widget.defaultCheckOut;
    _notesCtrl = TextEditingController(
      text: widget.existing?.notes ?? '',
    );
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickTime({required bool isCheckIn}) async {
    final current = isCheckIn ? _checkIn : _checkOut;
    final parts = current.split(':');
    final initH = int.tryParse(parts.isNotEmpty ? parts[0] : '9') ?? 9;
    final initM = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;

    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initH, minute: initM),
    );

    if (picked != null) {
      final str =
          '${picked.hour.toString().padLeft(2, '0')}:'
          '${picked.minute.toString().padLeft(2, '0')}';
      setState(() {
        if (isCheckIn) {
          _checkIn = str;
        } else {
          _checkOut = str;
        }
      });
    }
  }

  int _timeToMinutes(String time) {
    final parts = time.split(':');
    if (parts.length != 2) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return h * 60 + m;
  }

  int _calcLate(String checkIn) {
    if (widget.flexibleHours) return 0;
    final actual = _timeToMinutes(checkIn);
    final expected = _timeToMinutes(widget.defaultCheckIn) + 15;
    return actual > expected
        ? actual - _timeToMinutes(widget.defaultCheckIn)
        : 0;
  }

  int _calcOver(String checkOut) {
    if (widget.flexibleHours) return 0;
    final actual = _timeToMinutes(checkOut);
    final expected = _timeToMinutes(widget.defaultCheckOut);
    return actual > expected ? actual - expected : 0;
  }

  int _calcEarly(String checkOut) {
    if (widget.flexibleHours) return 0;
    final actual = _timeToMinutes(checkOut);
    final expected = _timeToMinutes(widget.defaultCheckOut);
    return actual < expected ? expected - actual : 0;
  }

  @override
  Widget build(BuildContext context) {
    final showTimes = _status == 'present' || _status == 'late';
    final isNew = widget.existing == null;

    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Text(
        isNew ? 'إدخال حضور' : 'تعديل الحضور',
        style: TextStyle(
          color: AppTheme.textMainFor(context),
          fontFamily: 'Cairo',
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: GlassStyle.fill05For(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    color: AppTheme.accentFor(context),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.date,
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ============================================
            // الحالة
            // ============================================
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: InputDecoration(
                labelText: 'الحالة',
                labelStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
                filled: true,
                fillColor: GlassStyle.fill05For(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'present',
                  child: Text(
                    'حاضر',
                    style: TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
                DropdownMenuItem(
                  value: 'permission',
                  child: Text(
                    'إذن',
                    style: TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
                DropdownMenuItem(
                  value: 'absent',
                  child: Text(
                    'غائب',
                    style: TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
                DropdownMenuItem(
                  value: 'vacation',
                  child: Text(
                    'إجازة',
                    style: TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _status = v ?? 'present'),
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
              ),
            ),

            // ============================================
            // الأوقات (بس لو حاضر)
            // ============================================
            if (showTimes) ...[
              const SizedBox(height: 10),
              InkWell(
                onTap: () => _pickTime(isCheckIn: true),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: GlassStyle.fill05For(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.login_rounded,
                        color: AppTheme.successFor(context),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'الحضور: ',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.textMutedFor(context),
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        _checkIn,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.textMainFor(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => _pickTime(isCheckIn: false),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: GlassStyle.fill05For(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.logout_rounded,
                        color: AppTheme.dangerFor(context),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'الانصراف: ',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.textMutedFor(context),
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        _checkOut,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.textMainFor(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 10),
            TextField(
              controller: _notesCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'ملاحظات',
                labelStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
                filled: true,
                fillColor: GlassStyle.fill05For(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.existing?.id != null)
          TextButton.icon(
            onPressed: () => Navigator.pop(context, 'delete'),
            icon: Icon(
              Icons.delete_rounded,
              color: AppTheme.dangerFor(context),
              size: 16,
            ),
            label: Text(
              'حذف',
              style: TextStyle(
                color: AppTheme.dangerFor(context),
                fontFamily: 'Cairo',
              ),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'إلغاء',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
            ),
          ),
        ),
        TextButton(
          onPressed: () {
            final model = HRAttendanceModel(
              id: widget.existing?.id,
              companyCode: widget.companyCode,
              branchCode: widget.branchCode,
              employeeCode: widget.employeeCode,
              date: widget.date,
              status: _status,
              checkIn: showTimes ? _checkIn : '',
              checkOut: showTimes ? _checkOut : '',
              lateMinutes: showTimes ? _calcLate(_checkIn) : 0,
              overtimeMinutes: showTimes ? _calcOver(_checkOut) : 0,
              earlyLeaveMinutes: showTimes ? _calcEarly(_checkOut) : 0,
              notes: _notesCtrl.text.trim(),
            );
            Navigator.pop(context, model);
          },
          child: Text(
            isNew ? 'إضافة' : 'حفظ',
            style: TextStyle(
              color: AppTheme.accentFor(context),
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// نهاية ملف attendance_page.dart
//
// الملف بيستخدم:
// - HRService: عمليات attendance + pending
// - HRReportService: إبطال كاش التقرير بعد الحفظ
// - EmployeeService: جلب قائمة الموظفين
// - HRConstants: helpers للتواريخ + isWeeklyVacation
// - HRAttendanceModel, HREmployeeSettingsModel: من hr_models.dart
//
// الفروق الرئيسية عن النسخة القديمة:
// 1. 3 services بدل 5 (HRService موحد)
// 2. Pending في Hive (مش الذاكرة) → مايضيعش لو التطبيق اتقفل
// 3. server fallback للشهور القديمة (getEmployeeMonthAttendance)
// 4. إبطال كاش التقرير بعد كل حفظ/تعديل/حذف
// 5. Badge عددي على زر الحفظ
// 6. نقطة برتقالية على أيام الـ pending
// ============================================================