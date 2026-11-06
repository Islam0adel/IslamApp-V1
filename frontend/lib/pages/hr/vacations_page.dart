// lib/pages/hr/vacations_page.dart

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


/// صفحة الإعدادات والإجازات
///
/// 5 تبويبات:
///   1. أسبوعية       → يوم الراحة الأسبوعي
///   2. استثنائية     → إجازات محددة لموظف
///   3. مواعيد العمل   → check_in / check_out / flexible
///   4. السلف والمكافآت → HRAdjustment
///   5. إعدادات التأخير → delay_rules
///
/// ⚠️ النسخة الجديدة:
/// - HRService بدل 4 services منفصلة
/// - إبطال كاش التقرير بعد كل عملية حفظ
/// - HRConstants للـ helpers
class VacationsPage extends StatefulWidget {
  const VacationsPage({super.key});

  @override
  State<VacationsPage> createState() => _VacationsPageState();
}


class _VacationsPageState extends State<VacationsPage>
    with TickerProviderStateMixin {
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

  HREmployeeSettingsModel? _settings;
  List<HRVacationModel> _exceptionalVacations = [];
  List<HRAdjustmentModel> _adjustments = [];

  late TabController _tabController;


  // ============================================================
  // Lifecycle
  // ============================================================

    @override
  void initState() {
    super.initState();

    // ⭐ عدد التبويبات ديناميكي حسب الصلاحيات
    final count = _visibleTabsCount();
    _tabController = TabController(
      length: count > 0 ? count : 1,  // 1 على الأقل لتفادي crash
      vsync: this,
    );
    _loadEmployees();
  }

    // ⭐ عدد التبويبات المرئية حسب الصلاحيات
  int _visibleTabsCount() {
    final ps = PermissionsService();
    int count = 0;

    if (ps.canEditWeeklyDay) count++;                           // أسبوعية
    if (ps.canAddVacation || ps.canDeleteVacation ||
        ps.canEditVacation) count++;                            // استثنائية
    if (ps.canEditWorkSchedule) count++;                        // مواعيد العمل
    if (ps.canViewAdjustments) count++;                         // السلف والمكافآت
    if (ps.canEditDelayRules) count++;                          // إعدادات التأخير

    return count;
  }

  // ⭐ هل فيه أي صلاحية داخل الصفحة؟
  bool _hasAnyTab() => _visibleTabsCount() > 0;

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }


  // ============================================================
  // Helpers — أشهر
  // ============================================================

  String _currentMonth() {
    final now = DateTime.now();
    return HRConstants.monthToStr(now);
  }

  String _addMonths(String month, int count) {
    final parts = month.split('-');
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final monthNum = int.tryParse(parts[1]) ?? DateTime.now().month;
    final dt = DateTime(year, monthNum + count);
    return HRConstants.monthToStr(dt);
  }


  // ============================================================
  // Load employees
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

      // ⭐ فلترة حسب الصلاحيات
      _employees = allEmployees
          .where((e) => PermissionsService()
              .canViewEmployee(e.code, e.branchCode))
          .toList();

      if (mounted) {
        setState(() {
          _isLoading = false;
          if (_employees.isNotEmpty && _selectedEmployee == null) {
            _selectedEmployee = _employees.first;
            _loadEmployeeData();
          }
        });
      }
    } catch (e) {
      print("❌ خطأ في تحميل الموظفين: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // ============================================================
  // Load employee data
  //
  // ⭐ HRService بيتولى:
  // - settings (Hive أو السيرفر)
  // - vacations (فلترة على الموظف)
  // - adjustments (فلترة على الشهر الحالي)
  // ============================================================

  Future<void> _loadEmployeeData({bool showLoader = true}) async {
    if (_selectedEmployee == null) return;
    if (showLoader) setState(() => _isLoading = true);

    try {
      // 1) إعدادات الموظف
      final settings = await _hrService.getEmployeeSettings(
        companyCode: _companyCode,
        employeeCode: _selectedEmployee!.code,
      );

      // 2) الإجازات (كل الإجازات المطبقة على الموظف)
      final allVacations = await _hrService.getVacations(
        companyCode: _companyCode,
        branchCode: _selectedEmployee!.branchCode,
        employeeCode: _selectedEmployee!.code,
      );

      // نفلتر على الاستثنائية (اللي فيها employee_code محدد)
      final exceptional = allVacations
          .where((v) => v.employeeCode == _selectedEmployee!.code)
          .toList();

      // ترتيب تنازلي بالتاريخ (الأحدث أولاً)
      exceptional.sort((a, b) => b.date.compareTo(a.date));

      // 3) التسويات (خصم/مكافأة/سلف للشهر الحالي)
      final currentMonth = _currentMonth();
      final allAdjustments = await _hrService.getAdjustmentsForMonth(
        companyCode: _companyCode,
        month: currentMonth,
        branchCode: _selectedEmployee!.branchCode,
      );

      final empAdjustments = allAdjustments
          .where(
            (a) =>
                a.employeeCode == _selectedEmployee!.code &&
                (a.type == 'bonus' || a.type == 'loan'),
          )
          .toList();

      if (mounted) {
        setState(() {
          _settings = settings;
          _exceptionalVacations = exceptional;
          _adjustments = empAdjustments;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("❌ خطأ في تحميل بيانات الموظف: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // ============================================================
  // إبطال كاش التقرير بعد أي حفظ
  // ============================================================

  Future<void> _invalidateCacheForEmployee() async {
    if (_selectedEmployee == null) return;
    await _reportService.invalidateCache(
      companyCode: _companyCode,
      employeeCode: _selectedEmployee!.code,
    );
  }

  Future<void> _invalidateCacheForCompany() async {
    await _reportService.invalidateCache(companyCode: _companyCode);
  }


  // ============================================================
  // إضافة إجازة عامة (لكل الشركة)
  // ============================================================

    Future<void> _addGeneralVacation() async {
    // ⭐ فحص
    if (!PermissionsService().canAddVacation) {
      _showSnackBar(
        "ليس لديك صلاحية إضافة إجازة",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => const _AddGeneralVacationDialog(),
    );

    if (result == null) return;

    final model = HRVacationModel(
      companyCode: _companyCode,
      branchCode: null,
      employeeCode: null,
      date: result['date'],
      name: result['name'],
      type: 'official',
    );

    final saveResult = await _hrService.saveVacation(model: model);

    if (!mounted) return;

    if (saveResult['success'] == true) {
      // ⭐ الإجازة العامة تؤثر على كل الموظفين → مسح كاش الشركة
      await _invalidateCacheForCompany();

      _showSnackBar(
        "تم حفظ الإجازة العامة",
        AppTheme.successStrongFor(context),
      );
      _loadEmployeeData(showLoader: false);
    } else {
      _showSnackBar(
        "فشل: ${saveResult['error']}",
        AppTheme.dangerStrongFor(context),
      );
    }
  }


  // ============================================================
  // حفظ يوم الراحة الأسبوعي
  // ============================================================

    Future<void> _saveWeeklyDay(int? day) async {
    if (_settings == null || _selectedEmployee == null) return;

    // ⭐ فحص
    if (!PermissionsService().canEditWeeklyDay) {
      _showSnackBar(
        "ليس لديك صلاحية تعديل يوم الإجازة",
        AppTheme.dangerFor(context),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final updated = day == null
          ? _settings!.copyWith(clearWeekly: true)
          : _settings!.copyWith(weeklyVacationDay: day);

      final result = await _hrService.saveEmployeeSettings(model: updated);

      if (!mounted) return;

      if (result['success'] == true) {
        setState(() => _settings = updated);

        // ⭐ تغيير يوم الراحة → يؤثر على كل الشهور
        await _invalidateCacheForEmployee();

        _showSnackBar(
          day == null ? "تم إلغاء الإجازة الأسبوعية" : "تم الحفظ",
          AppTheme.successStrongFor(context),
        );
      } else {
        _showSnackBar(
          "فشل: ${result['error']}",
          AppTheme.dangerStrongFor(context),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          "خطأ: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }


  // ============================================================
  // إضافة إجازة استثنائية
  // ============================================================

    Future<void> _addExceptionalVacation() async {
    if (_selectedEmployee == null) return;

    // ⭐ فحص
    if (!PermissionsService().canAddVacation) {
      _showSnackBar(
        "ليس لديك صلاحية إضافة إجازة",
        AppTheme.dangerFor(context),
      );
      return;
    }

    // 1) اختيار التاريخ
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: 'اختر تاريخ الإجازة',
    );

    if (picked == null) return;

    final dateStr = HRConstants.dateToStr(picked);

    // 2) اسم الإجازة
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: 'إجازة استثنائية');
        return AlertDialog(
          backgroundColor: AppTheme.dialogBackground(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Text(
            'اسم الإجازة',
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'إلغاء',
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(
                'حفظ',
                style: TextStyle(
                  color: AppTheme.accentFor(context),
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (name == null || name.isEmpty) return;

    // 3) حفظ
    final model = HRVacationModel(
      companyCode: _companyCode,
      branchCode: _selectedEmployee!.branchCode,
      employeeCode: _selectedEmployee!.code,
      date: dateStr,
      name: name,
      type: 'official',
    );

    final saveResult = await _hrService.saveVacation(model: model);

    if (!mounted) return;

    if (saveResult['success'] == true) {
      await _invalidateCacheForEmployee();
      _showSnackBar(
        "تم الحفظ",
        AppTheme.successStrongFor(context),
      );
      _loadEmployeeData(showLoader: false);
    } else {
      _showSnackBar(
        "فشل: ${saveResult['error']}",
        AppTheme.dangerStrongFor(context),
      );
    }
  }


  // ============================================================
  // حذف إجازة استثنائية
  // ============================================================

    Future<void> _deleteExceptionalVacation(HRVacationModel v) async {
    if (v.id == null) return;

    // ⭐ فحص
    if (!PermissionsService().canDeleteVacation) {
      _showSnackBar(
        "ليس لديك صلاحية حذف الإجازة",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Text(
          'حذف الإجازة',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'سيتم حذف "${v.name}" بتاريخ ${v.date}.',
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

    final ok = await _hrService.deleteVacation(
      companyCode: _companyCode,
      vacationId: v.id!,
    );

    if (!mounted) return;

    if (ok) {
      await _invalidateCacheForEmployee();
      _showSnackBar(
        "تم الحذف",
        AppTheme.successStrongFor(context),
      );
      _loadEmployeeData(showLoader: false);
    } else {
      _showSnackBar(
        "فشل الحذف",
        AppTheme.dangerStrongFor(context),
      );
    }
  }


  // ============================================================
  // حفظ مواعيد العمل
  // ============================================================

    Future<void> _saveWorkSchedule({
    required String checkIn,
    required String checkOut,
    required bool flexible,
    required bool useFixedMonthDays,
  }) async {
    if (_settings == null || _selectedEmployee == null) return;

    // ⭐ فحص
    if (!PermissionsService().canEditWorkSchedule) {
      _showSnackBar(
        "ليس لديك صلاحية تعديل مواعيد العمل",
        AppTheme.dangerFor(context),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final updated = _settings!.copyWith(
        defaultCheckIn: checkIn,
        defaultCheckOut: checkOut,
        flexibleHours: flexible,
        useFixedMonthDays: useFixedMonthDays, 
      );

      final result = await _hrService.saveEmployeeSettings(model: updated);

      if (!mounted) return;

      if (result['success'] == true) {
        setState(() => _settings = updated);

        // ⭐ تغيير مواعيد العمل → يؤثر على حسابات كل الشهور
        await _invalidateCacheForEmployee();

        _showSnackBar(
          "تم حفظ مواعيد العمل",
          AppTheme.successStrongFor(context),
        );
      } else {
        _showSnackBar(
          "فشل: ${result['error']}",
          AppTheme.dangerStrongFor(context),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          "خطأ: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }


  // ============================================================
  // حفظ إعدادات التأخير
  // ============================================================

    Future<void> _saveDelayRules(Map<String, double> rules) async {
    if (_settings == null || _selectedEmployee == null) return;

    // ⭐ فحص
    if (!PermissionsService().canEditDelayRules) {
      _showSnackBar(
        "ليس لديك صلاحية تعديل إعدادات التأخير",
        AppTheme.dangerFor(context),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final updated = _settings!.copyWith(delayRules: rules);
      final result = await _hrService.saveEmployeeSettings(model: updated);

      if (!mounted) return;

      if (result['success'] == true) {
        setState(() => _settings = updated);

        // ⭐ تغيير قواعد التأخير → يؤثر على حسابات كل الشهور
        await _invalidateCacheForEmployee();

        _showSnackBar(
          "تم حفظ إعدادات التأخير",
          AppTheme.successStrongFor(context),
        );
      } else {
        _showSnackBar(
          "فشل: ${result['error']}",
          AppTheme.dangerStrongFor(context),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          "خطأ: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }


  // ============================================================
  // إضافة مكافأة أو سلفة
  //
  // ⚠️ للسلفة بأقساط:
  // - ننشئ صف منفصل لكل شهر (installments_count صف)
  // - كل صف بيتحفظ بـ saveAdjustment منفصل
  // - بعد ما كلهم يخلصوا → invalidate cache مرة واحدة
  // ============================================================

    Future<void> _addAdjustment() async {
    if (_selectedEmployee == null) return;

    // ⭐ فحص: لازم يكون عنده صلاحية إضافة مكافأة أو سلفة
    final ps = PermissionsService();
    if (!ps.canAddBonus && !ps.canAddLoan) {
      _showSnackBar(
        "ليس لديك صلاحية إضافة مكافأة أو سلفة",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _AddAdjustmentDialog(
        employeeName: _selectedEmployee!.name,
        month: _currentMonth(),
      ),
    );

    if (result == null) return;

    // ⭐ فحص إضافي: نوع العملية لازم يكون مسموح
    final resultType = result['type'] as String;
    if (resultType == 'bonus' && !ps.canAddBonus) {
      _showSnackBar(
        "ليس لديك صلاحية إضافة مكافأة",
        AppTheme.dangerFor(context),
      );
      return;
    }
    if (resultType == 'loan' && !ps.canAddLoan) {
      _showSnackBar(
        "ليس لديك صلاحية إضافة سلفة",
        AppTheme.dangerFor(context),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final type = result['type'] as String;
      final amount = result['amount'] as double;
      final reason = result['reason'] as String? ?? '';
      final installments = result['installments'] as int? ?? 1;

      if (type == 'loan' && installments > 1) {
        // سلفة بأقساط → صف لكل شهر
        final amountPerMonth = amount / installments;

        for (int i = 1; i <= installments; i++) {
          final targetMonth = _addMonths(_currentMonth(), i - 1);

          final adj = HRAdjustmentModel(
            companyCode: _companyCode,
            branchCode: _selectedEmployee!.branchCode,
            employeeCode: _selectedEmployee!.code,
            month: targetMonth,
            type: 'loan',
            amount: amountPerMonth,
            reason: reason,
            installmentRef: '$i/$installments',
          );

          final saveResult = await _hrService.saveAdjustment(model: adj);

          if (saveResult['success'] != true) {
            _showSnackBar(
              "فشل القسط $i: ${saveResult['error']}",
              AppTheme.dangerStrongFor(context),
            );
            return; // نوقف باقي الأقساط
          }
        }

        await _invalidateCacheForEmployee();

        _showSnackBar(
          "تم إنشاء سلفة على $installments قسط",
          AppTheme.successStrongFor(context),
        );
      } else {
        // مكافأة/خصم/سلفة بدون أقساط
        final adj = HRAdjustmentModel(
          companyCode: _companyCode,
          branchCode: _selectedEmployee!.branchCode,
          employeeCode: _selectedEmployee!.code,
          month: _currentMonth(),
          type: type,
          amount: amount,
          reason: reason,
        );

        final saveResult = await _hrService.saveAdjustment(model: adj);

        if (saveResult['success'] != true) {
          _showSnackBar(
            "فشل: ${saveResult['error']}",
            AppTheme.dangerStrongFor(context),
          );
          return;
        }

        await _invalidateCacheForEmployee();

        _showSnackBar(
          "تم الحفظ",
          AppTheme.successStrongFor(context),
        );
      }

      _loadEmployeeData(showLoader: false);
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          "خطأ: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }


  // ============================================================
  // حذف تسوية
  // ============================================================

    Future<void> _deleteAdjustment(HRAdjustmentModel adj) async {
    if (adj.id == null) return;

    // ⭐ فحص
    if (!PermissionsService().canDeleteAdjustment) {
      _showSnackBar(
        "ليس لديك صلاحية حذف التسوية",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Text(
          'حذف التسوية',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'سيتم حذف "${adj.typeLabel}" بقيمة ${adj.amount.toStringAsFixed(2)} ج.م.',
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

    final ok = await _hrService.deleteAdjustment(
      companyCode: _companyCode,
      adjustmentId: adj.id!,
    );

    if (!mounted) return;

    if (ok) {
      await _invalidateCacheForEmployee();
      _showSnackBar(
        "تم الحذف",
        AppTheme.successStrongFor(context),
      );
      _loadEmployeeData(showLoader: false);
    } else {
      _showSnackBar(
        "فشل الحذف",
        AppTheme.dangerStrongFor(context),
      );
    }
  }


  // ============================================================
  // SnackBar
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
  // BUILD
  // ============================================================

    @override
  Widget build(BuildContext context) {
    // ⭐ فحص صلاحية فتح الصفحة
    if (!PermissionsService().canOpenVacationsPage) {
      return _buildNoPermissionScreen('عرض الإجازات');
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "الإعدادات والإجازات",
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
          IconButton(
            icon: Icon(
              Icons.celebration_rounded,
              color: AppTheme.warningFor(context),
            ),
            onPressed: _isSaving ? null : _addGeneralVacation,
            tooltip: 'إجازة عامة',
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
                  : _buildContent(),
        ),
      ),
    );
  }


  // ============================================================
  // Empty state
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
  // المحتوى الرئيسي (Dropdown + Tabs)
  // ============================================================

  Widget _buildContent() {
    return Column(
      children: [
        // Dropdown الموظف
        Padding(
          padding: const EdgeInsets.all(15),
          child: GlassCard(
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
              onChanged: _isSaving
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() {
                        _selectedEmployee = v;
                        _settings = null;
                        _exceptionalVacations = [];
                        _adjustments = [];
                      });
                      _loadEmployeeData();
                    },
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontSize: 14,
              ),
            ),
          ),
        ),

                // ⭐ لو مفيش أي صلاحية داخل الصفحة → رسالة
        if (!_hasAnyTab())
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'ليس لديك صلاحية داخل صفحة الإجازات',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          )
        else ...[
          // TabBar ديناميكي
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: GlassStyle.fill03For(context),
              borderRadius: BorderRadius.circular(10),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              indicatorColor: AppTheme.accentFor(context),
              indicatorWeight: 3,
              labelColor: AppTheme.accentFor(context),
              unselectedLabelColor: AppTheme.textMutedFor(context),
              labelStyle: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
              tabs: _buildTabBarChildren(),
            ),
          ),

          const SizedBox(height: 10),

          // TabBarView ديناميكي
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: _buildTabBarViewChildren(),
            ),
          ),
        ],
      ],
    );
  }

  

  // ============================================================
  // Tab 1: الإجازة الأسبوعية
  //
  // 7 أزرار (أيام الأسبوع) — يختار واحد
  // الـ `HRConstants.weekdayNamesAr` هي مصدر الأسماء
  // ============================================================

  Widget _buildWeeklyTab() {
    if (_settings == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(15),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ============================================
            // Header
            // ============================================
            Row(
              children: [
                Icon(
                  Icons.weekend_rounded,
                  color: AppTheme.extraTealFor(context),
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  'يوم الإجازة الأسبوعي',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'يظهر تلقائيًا كإجازة كل أسبوع',
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 15),

            // ============================================
            // أزرار الأيام (7)
            // ============================================
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: HRConstants.weekdayNamesAr.asMap().entries.map(
                (entry) {
                  final day = entry.key;
                  final label = entry.value;
                  final isSelected = _settings!.weeklyVacationDay == day;

                  return InkWell(
                    onTap: _isSaving
                        ? null
                        : () => _saveWeeklyDay(isSelected ? null : day),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppTheme.extraTealFor(context)
                                .withValues(alpha: 0.2)
                            : GlassStyle.fill05For(context),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? AppTheme.extraTealFor(context)
                              : GlassStyle.line10For(context),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: isSelected
                              ? AppTheme.extraTealFor(context)
                              : AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                },
              ).toList(),
            ),

            const SizedBox(height: 15),

            // ============================================
            // ملخص اليوم المختار
            // ============================================
            if (_settings!.weeklyVacationDay != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.extraTealFor(context)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.extraTealFor(context)
                        .withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      color: AppTheme.extraTealFor(context),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'الإجازة الأسبوعية: ${_settings!.weeklyDayLabel}',
                        style: TextStyle(
                          color: AppTheme.extraTealFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: AppTheme.dangerFor(context),
                        size: 18,
                      ),
                      onPressed:
                          _isSaving ? null : () => _saveWeeklyDay(null),
                      tooltip: 'إلغاء',
                    ),
                  ],
                ),
              ),

            // ============================================
            // مؤشر الحفظ
            // ============================================
            if (_isSaving)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }


  // ============================================================
  // Tab 2: الإجازات الاستثنائية
  //
  // قائمة الإجازات (الموظف ده بس) + زر إضافة
  // ============================================================

  Widget _buildExceptionalTab() {
    return Column(
      children: [
        // ============================================
        // Header + زر إضافة
        // ============================================
        Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'الإجازات الاستثنائية (${_exceptionalVacations.length})',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _addExceptionalVacation,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text(
                  'إضافة',
                  style: TextStyle(fontFamily: 'Cairo'),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentFor(context),
                  foregroundColor: AppTheme.onAccentFor(context),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
        ),

        // ============================================
        // القائمة أو empty state
        // ============================================
        Expanded(
          child: _exceptionalVacations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.beach_access_rounded,
                        size: 64,
                        color: AppTheme.textMutedFor(context),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'لا توجد إجازات استثنائية',
                        style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
                  itemCount: _exceptionalVacations.length,
                  itemBuilder: (context, index) =>
                      _buildExceptionalCard(_exceptionalVacations[index]),
                ),
        ),
      ],
    );
  }


  // ============================================================
  // بطاقة إجازة استثنائية (سطر واحد)
  // ============================================================

  Widget _buildExceptionalCard(HRVacationModel v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            // أيقونة
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.warningOrangeSoftFor(context)
                    .withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.celebration_rounded,
                color: AppTheme.warningOrangeSoftFor(context),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),

            // الاسم + التاريخ
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.name,
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    v.date,
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),

            // زر حذف
            IconButton(
              icon: Icon(
                Icons.delete_rounded,
                color: AppTheme.dangerFor(context),
                size: 18,
              ),
              onPressed: _isSaving
                  ? null
                  : () => _deleteExceptionalVacation(v),
            ),
          ],
        ),
      ),
    );
  }

  

  // ============================================================
  // Tab 3: مواعيد العمل
  //
  // يستخدم _WorkScheduleEditor (widget منفصل في الجزء 4)
  // ============================================================

  Widget _buildWorkScheduleTab() {
    if (_settings == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return _WorkScheduleEditor(
      settings: _settings!,
      onSave: _saveWorkSchedule,
      isSaving: _isSaving,
    );
  }


  // ============================================================
  // Tab 4: السلف والمكافآت
  //
  // - إحصائيات سريعة (إجمالي المكافآت + إجمالي السلف)
  // - زر إضافة
  // - قائمة التسويات
  // ============================================================

  Widget _buildLoansBonusesTab() {
    // فلترة المكافآت والسلف
    final bonuses = _adjustments.where((a) => a.type == 'bonus').toList();
    final loans = _adjustments.where((a) => a.type == 'loan').toList();

    final totalBonuses =
        bonuses.fold<double>(0.0, (sum, a) => sum + a.amount);
    final totalLoans =
        loans.fold<double>(0.0, (sum, a) => sum + a.amount);

    return Column(
      children: [
        // ============================================
        // إحصائيات (إجمالي المكافآت + إجمالي السلف)
        // ============================================
        Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
                            Expanded(
                child: _buildMiniStat(
                  'المكافآت',
                  PermissionsService().canViewSalaryAmounts
                      ? '${totalBonuses.toStringAsFixed(2)} ج.م'
                      : '—',
                  AppTheme.successFor(context),
                  Icons.add_circle_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMiniStat(
                  'السلف',
                  PermissionsService().canViewSalaryAmounts
                      ? '${totalLoans.toStringAsFixed(2)} ج.م'
                      : '—',
                  AppTheme.warningOrangeSoftFor(context),
                  Icons.request_quote_rounded,
                ),
              ),
            ],
          ),
        ),

                // ============================================
        // زر الإضافة (لو عنده صلاحية)
        // ============================================
        if (PermissionsService().canAddBonus ||
            PermissionsService().canAddLoan)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _addAdjustment,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text(
                  'إضافة مكافأة أو سلفة',
                  style: TextStyle(fontFamily: 'Cairo'),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentFor(context),
                  foregroundColor: AppTheme.onAccentFor(context),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),

        const SizedBox(height: 10),

        // ============================================
        // قائمة التسويات أو empty state
        // ============================================
        Expanded(
          child: _adjustments.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.attach_money_rounded,
                        size: 64,
                        color: AppTheme.textMutedFor(context),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'لا توجد سلف أو مكافآت',
                        style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
                  itemCount: _adjustments.length,
                  itemBuilder: (context, index) =>
                      _buildAdjustmentCard(_adjustments[index]),
                ),
        ),
      ],
    );
  }


  // ============================================================
  // بطاقة إحصائية صغيرة (مكافآت / سلف)
  // ============================================================

  Widget _buildMiniStat(
    String label,
    String value,
    Color color,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 10,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    color: color,
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // بطاقة تسوية واحدة (مكافأة أو قسط سلفة)
  // ============================================================

  Widget _buildAdjustmentCard(HRAdjustmentModel adj) {
    // استخدام getters من الـ Model (isBonus)
    final isBonus = adj.isBonus;
    final color = isBonus
        ? AppTheme.successFor(context)
        : AppTheme.warningOrangeSoftFor(context);
    final icon = isBonus
        ? Icons.add_circle_rounded
        : Icons.request_quote_rounded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            // أيقونة
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 10),

            // النوع + السبب + رقم القسط
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    adj.typeLabel,
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (adj.reason.isNotEmpty)
                    Text(
                      adj.reason,
                      style: TextStyle(
                        color: AppTheme.textMutedFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (adj.installmentRef.isNotEmpty)
                    Text(
                      'قسط ${adj.installmentRef}',
                      style: TextStyle(
                        color: AppTheme.infoFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),

                        // المبلغ (يظهر فقط لو عنده صلاحية)
            if (PermissionsService().canViewSalaryAmounts)
              Text(
                '${adj.amount.toStringAsFixed(2)} ج.م',
                style: TextStyle(
                  color: color,
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),

            // زر حذف
            IconButton(
              icon: Icon(
                Icons.delete_outline_rounded,
                color: AppTheme.dangerFor(context),
                size: 18,
              ),
              onPressed:
                  _isSaving ? null : () => _deleteAdjustment(adj),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }


  // ============================================================
  // Tab 5: إعدادات التأخير
  //
  // يستخدم _DelayRulesEditor (widget منفصل في الجزء 5)
  // ============================================================

  Widget _buildDelayRulesTab() {
    if (_settings == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return _DelayRulesEditor(
      settings: _settings!,
      onSave: _saveDelayRules,
      isSaving: _isSaving,
    );
  }
  // ⭐ TabBar children ديناميكي
  List<Widget> _buildTabBarChildren() {
    final ps = PermissionsService();
    final tabs = <Widget>[];

    if (ps.canEditWeeklyDay) {
      tabs.add(const Tab(text: 'أسبوعية'));
    }
    if (ps.canAddVacation || ps.canDeleteVacation || ps.canEditVacation) {
      tabs.add(const Tab(text: 'استثنائية'));
    }
    if (ps.canEditWorkSchedule) {
      tabs.add(const Tab(text: 'مواعيد العمل'));
    }
    if (ps.canViewAdjustments) {
      tabs.add(const Tab(text: 'السلف والمكافآت'));
    }
    if (ps.canEditDelayRules) {
      tabs.add(const Tab(text: 'إعدادات التأخير'));
    }

    return tabs;
  }

  // ⭐ TabBarView children ديناميكي
  List<Widget> _buildTabBarViewChildren() {
    final ps = PermissionsService();
    final views = <Widget>[];

    if (ps.canEditWeeklyDay) {
      views.add(_buildWeeklyTab());
    }
    if (ps.canAddVacation || ps.canDeleteVacation || ps.canEditVacation) {
      views.add(_buildExceptionalTab());
    }
    if (ps.canEditWorkSchedule) {
      views.add(_buildWorkScheduleTab());
    }
    if (ps.canViewAdjustments) {
      views.add(_buildLoansBonusesTab());
    }
    if (ps.canEditDelayRules) {
      views.add(_buildDelayRulesTab());
    }

    return views;
  }

  // ⭐ شاشة "لا صلاحية"
  Widget _buildNoPermissionScreen(String permission) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "الإعدادات والإجازات",
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
// Dialog 1: إضافة إجازة عامة
//
// إجازة لكل الشركة (كل الفروع + كل الموظفين)
// ============================================================

class _AddGeneralVacationDialog extends StatefulWidget {
  const _AddGeneralVacationDialog();

  @override
  State<_AddGeneralVacationDialog> createState() =>
      _AddGeneralVacationDialogState();
}


class _AddGeneralVacationDialogState extends State<_AddGeneralVacationDialog> {
  final _nameCtrl = TextEditingController(text: 'عيد');
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: 'اختر التاريخ',
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Row(
        children: [
          Icon(
            Icons.celebration_rounded,
            color: AppTheme.warningFor(context),
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'إجازة عامة',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ملاحظة "تنطبق على كل الموظفين"
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.infoFor(context).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.infoFor(context).withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: AppTheme.infoFor(context),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تنطبق على كل الموظفين في هذا اليوم',
                      style: TextStyle(
                        color: AppTheme.infoFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // اسم الإجازة
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: 'اسم الإجازة',
                labelStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
                prefixIcon: Icon(
                  Icons.label_rounded,
                  color: AppTheme.accentFor(context),
                  size: 18,
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
            const SizedBox(height: 10),

            // اختيار التاريخ
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: GlassStyle.fill05For(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: GlassStyle.line10For(context)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today_rounded,
                      color: AppTheme.accentFor(context),
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'التاريخ',
                            style: TextStyle(
                              color: AppTheme.textMutedFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 10,
                            ),
                          ),
                          Text(
                            HRConstants.dateToStr(_date),
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
                    Icon(
                      Icons.edit_rounded,
                      color: AppTheme.textMutedFor(context),
                      size: 16,
                    ),
                  ],
                ),
              ),
            ),
          ],
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
          onPressed: () {
            if (_nameCtrl.text.trim().isEmpty) return;
            Navigator.pop(context, {
              'name': _nameCtrl.text.trim(),
              'date': HRConstants.dateToStr(_date),
            });
          },
          child: Text(
            'حفظ',
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
// Widget 2: محرر مواعيد العمل
//
// Widget مستقل بيدير:
// - check_in (وقت الحضور)
// - check_out (وقت الانصراف)
// - flexible_hours (مرونة)
//
// الـ Page بتوفر: settings + onSave callback + isSaving
// ============================================================

class _WorkScheduleEditor extends StatefulWidget {
  final HREmployeeSettingsModel settings;
  final Future<void> Function({
    required String checkIn,
    required String checkOut,
    required bool flexible,
    required bool useFixedMonthDays, 
  }) onSave;
  final bool isSaving;

  const _WorkScheduleEditor({
    required this.settings,
    required this.onSave,
    required this.isSaving,
  });

  @override
  State<_WorkScheduleEditor> createState() => _WorkScheduleEditorState();
}


class _WorkScheduleEditorState extends State<_WorkScheduleEditor> {
  late String _checkIn;
  late String _checkOut;
  late bool _flexible;
  late bool _useFixedMonthDays;   // ⭐ جديد

  @override
  void initState() {
    super.initState();
    _checkIn = widget.settings.defaultCheckIn;
    _checkOut = widget.settings.defaultCheckOut;
    _flexible = widget.settings.flexibleHours;
    _useFixedMonthDays = widget.settings.useFixedMonthDays; 
  }
    @override
  void didUpdateWidget(_WorkScheduleEditor oldWidget) {
    super.didUpdateWidget(oldWidget);

    // ⭐ لو الموظف اتغير (settings جديدة)
    if (oldWidget.settings.employeeCode != widget.settings.employeeCode) {
      setState(() {
        _checkIn = widget.settings.defaultCheckIn;
        _checkOut = widget.settings.defaultCheckOut;
        _flexible = widget.settings.flexibleHours;
      });
    }
  }

  Future<void> _pickTime({required bool isCheckIn}) async {
    final current = isCheckIn ? _checkIn : _checkOut;
    final parts = current.split(':');
    final initH = int.tryParse(parts.isNotEmpty ? parts[0] : '9') ?? 9;
    final initM = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;

    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initH, minute: initM),
      helpText: isCheckIn ? 'وقت الحضور' : 'وقت الانصراف',
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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(15),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ============================================
            // Header
            // ============================================
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  color: AppTheme.accentFor(context),
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  'مواعيد العمل الثابتة',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'تُستخدم لحساب التأخير والإضافي',
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 15),

            // ============================================
            // وقت الحضور
            // ============================================
            InkWell(
              onTap: () => _pickTime(isCheckIn: true),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: GlassStyle.fill05For(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: GlassStyle.line10For(context)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.login_rounded,
                      color: AppTheme.successFor(context),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'من (وقت الحضور)',
                            style: TextStyle(
                              color: AppTheme.textMutedFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            _checkIn,
                            style: TextStyle(
                              color: AppTheme.textMainFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 18,
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

            const SizedBox(height: 10),

            // ============================================
            // وقت الانصراف
            // ============================================
            InkWell(
              onTap: () => _pickTime(isCheckIn: false),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: GlassStyle.fill05For(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: GlassStyle.line10For(context)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.logout_rounded,
                      color: AppTheme.dangerFor(context),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'إلى (وقت الانصراف)',
                            style: TextStyle(
                              color: AppTheme.textMutedFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            _checkOut,
                            style: TextStyle(
                              color: AppTheme.textMainFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 18,
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

            const SizedBox(height: 15),

            // ============================================
            // مرونة المواعيد (switch)
            // ============================================
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _flexible
                    ? AppTheme.warningOrangeSoftFor(context)
                        .withValues(alpha: 0.1)
                    : GlassStyle.fill05For(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _flexible
                      ? AppTheme.warningOrangeSoftFor(context)
                          .withValues(alpha: 0.3)
                      : GlassStyle.line10For(context),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _flexible
                        ? Icons.timer_rounded
                        : Icons.timer_off_rounded,
                    color: _flexible
                        ? AppTheme.warningOrangeSoftFor(context)
                        : AppTheme.textMutedFor(context),
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'مرونة في المواعيد',
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _flexible
                              ? 'يُحسب الحضور بالمدة — بدون خصم تأخير'
                              : 'يُحسب الحضور بالتوقيت الصارم',
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _flexible,
                    activeThumbColor: AppTheme.successFor(context),
                    onChanged: (v) => setState(() => _flexible = v),
                  ),
                  
                ],
              ),
            ),
                        // ⭐ جديد: الشهر ثابت 30 يوم
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _useFixedMonthDays
                    ? AppTheme.infoFor(context).withValues(alpha: 0.1)
                    : AppTheme.warningOrangeSoftFor(context)
                        .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _useFixedMonthDays
                      ? AppTheme.infoFor(context).withValues(alpha: 0.3)
                      : AppTheme.warningOrangeSoftFor(context)
                          .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _useFixedMonthDays
                        ? Icons.calendar_month_rounded
                        : Icons.calendar_today_rounded,
                    color: _useFixedMonthDays
                        ? AppTheme.infoFor(context)
                        : AppTheme.warningOrangeSoftFor(context),
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'الشهر ثابت 30 يوم',
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _useFixedMonthDays
                              ? 'قيمة اليوم = الراتب ÷ 30'
                              : 'قيمة اليوم = الراتب ÷ أيام الشهر الفعلية',
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _useFixedMonthDays,
                    activeThumbColor: AppTheme.infoFor(context),
                    onChanged: (v) =>
                        setState(() => _useFixedMonthDays = v),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ============================================
            // زر الحفظ
            // ============================================
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                                onPressed: widget.isSaving
                    ? null
                    : () => widget.onSave(
                          checkIn: _checkIn,
                          checkOut: _checkOut,
                          flexible: _flexible,
                          useFixedMonthDays: _useFixedMonthDays,   // ⭐
                        ),
                icon: widget.isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_rounded, size: 18),
                label: Text(
                  widget.isSaving ? 'جاري الحفظ...' : 'حفظ',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentFor(context),
                  foregroundColor: AppTheme.onAccentFor(context),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



// ============================================================
// Widget 3: محرر إعدادات التأخير
//
// Widget مستقل بيدير:
// - delay_rules (7 قواعد خصم)
//
// الـ Page بتوفر: settings + onSave callback + isSaving
//
// ⚠️ التسميات بتجي من HRConstants.delayRuleLabels (مش من الـ Model)
// ============================================================

class _DelayRulesEditor extends StatefulWidget {
  final HREmployeeSettingsModel settings;
  final Future<void> Function(Map<String, double>) onSave;
  final bool isSaving;

  const _DelayRulesEditor({
    required this.settings,
    required this.onSave,
    required this.isSaving,
  });

  @override
  State<_DelayRulesEditor> createState() => _DelayRulesEditorState();
}


class _DelayRulesEditorState extends State<_DelayRulesEditor> {
  late Map<String, double> _rules;
  late Map<String, TextEditingController> _controllers;

  /// ترتيب عرض القواعد (مطابق للقديم)
  static const List<String> _order = [
    'delay_10min',
    'delay_15min',
    'delay_30min',
    'delay_60min',
    'delay_120min',
    'absence',
    'absence_with_permission',
  ];

  @override
  void initState() {
    super.initState();
    _rules = Map.from(widget.settings.delayRules);
    _controllers = {
      for (final key in _order)
        key: TextEditingController(
          text: (_rules[key] ?? 0).toStringAsFixed(2),
        ),
    };
  }
    @override
  void didUpdateWidget(_DelayRulesEditor oldWidget) {
    super.didUpdateWidget(oldWidget);

    // ⭐ لو الموظف اتغير
    if (oldWidget.settings.employeeCode != widget.settings.employeeCode) {
      for (final c in _controllers.values) {
        c.dispose();
      }

      setState(() {
        _rules = Map.from(widget.settings.delayRules);
        _controllers = {
          for (final key in _order)
            key: TextEditingController(
              text: (_rules[key] ?? 0).toStringAsFixed(2),
            ),
        };
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(15),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ============================================
            // Header
            // ============================================
            Row(
              children: [
                Icon(
                  Icons.timer_rounded,
                  color: AppTheme.warningOrangeSoftFor(context),
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'إعدادات التأخير والغياب',
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'عدد أيام الخصم لكل حالة',
                        style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),

            // ============================================
            // 7 صفوف للقواعد
            // ============================================
            for (final key in _order) ...[
              _buildRuleRow(key),
              const SizedBox(height: 10),
            ],

            const SizedBox(height: 10),

            // ============================================
            // ملاحظة توضيحية
            // ============================================
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.infoFor(context).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.infoFor(context).withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: AppTheme.infoFor(context),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'مثال: 0.25 = ربع يوم، 0.5 = نصف يوم، 1 = يوم كامل',
                      style: TextStyle(
                        color: AppTheme.infoFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ============================================
            // زر الحفظ
            // ============================================
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: widget.isSaving ? null : _save,
                icon: widget.isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_rounded, size: 18),
                label: Text(
                  widget.isSaving ? 'جاري الحفظ...' : 'حفظ الإعدادات',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentFor(context),
                  foregroundColor: AppTheme.onAccentFor(context),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }


  // ============================================================
  // صف قاعدة واحدة (label + text field)
  // ============================================================

  Widget _buildRuleRow(String key) {
    // ⭐ التسميات من HRConstants (مش من الـ Model)
    final label = HRConstants.delayRuleLabels[key] ?? key;
    final isAbsence = key == 'absence';
    final isPermission = key == 'absence_with_permission';

    final color = isAbsence
        ? AppTheme.dangerFor(context)
        : isPermission
            ? AppTheme.extraTealFor(context)
            : AppTheme.warningOrangeSoftFor(context);

    final icon = isAbsence
        ? Icons.cancel_rounded
        : isPermission
            ? Icons.assignment_turned_in_rounded
            : Icons.timer_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Row(
        children: [
          // أيقونة
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 14),
          ),
          const SizedBox(width: 10),

          // التسمية
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // حقل الإدخال
          SizedBox(
            width: 85,
            child: TextField(
              controller: _controllers[key],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                suffixText: 'يوم',
                suffixStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                  fontSize: 9,
                ),
                filled: true,
                fillColor: GlassStyle.fill03For(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                isDense: true,
              ),
              style: TextStyle(
                fontFamily: 'Cairo',
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // حفظ — بياخد القيم من الـ controllers
  // ============================================================

  void _save() {
    final newRules = <String, double>{};

    for (final key in _order) {
      final val = double.tryParse(_controllers[key]!.text) ?? 0;
      newRules[key] = val < 0 ? 0 : val; // منع السالب
    }

    widget.onSave(newRules);
  }
}


// ============================================================
// Dialog 4: إضافة مكافأة أو سلفة
//
// - bonus: مكافأة (مبلغ + سبب)
// - loan:  سلفة (مبلغ + عدد أقساط + سبب)
//
// الـ Page هي اللي بتقسم السلفة على شهور
// ============================================================

class _AddAdjustmentDialog extends StatefulWidget {
  final String employeeName;
  final String month;

  const _AddAdjustmentDialog({
    required this.employeeName,
    required this.month,
  });

  @override
  State<_AddAdjustmentDialog> createState() => _AddAdjustmentDialogState();
}


class _AddAdjustmentDialogState extends State<_AddAdjustmentDialog> {
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  final _installmentsCtrl = TextEditingController(text: '1');

    String _type = 'bonus';

  @override
  void initState() {
    super.initState();

    // ⭐ Default type حسب الصلاحيات
    final ps = PermissionsService();
    if (!ps.canAddBonus && ps.canAddLoan) {
      _type = 'loan';
    } else if (ps.canAddBonus && !ps.canAddLoan) {
      _type = 'bonus';
    }
    // لو عنده الاتنين → bonus (default)
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    _installmentsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLoan = _type == 'loan';

    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Row(
        children: [
          Icon(
            isLoan ? Icons.request_quote_rounded : Icons.add_circle_rounded,
            color: isLoan
                ? AppTheme.warningOrangeSoftFor(context)
                : AppTheme.successFor(context),
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'إضافة مكافأة أو سلفة',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ============================================
            // معلومات الموظف + الشهر
            // ============================================
            Container(
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
                        Icons.person_rounded,
                        color: AppTheme.accentFor(context),
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.employeeName,
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_month_rounded,
                        color: AppTheme.warningFor(context),
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.month,
                        style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ============================================
            // النوع (مكافأة / سلفة)
            // ============================================
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: InputDecoration(
                labelText: 'النوع',
                labelStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
                prefixIcon: Icon(
                  Icons.category_rounded,
                  color: AppTheme.accentFor(context),
                  size: 18,
                ),
                filled: true,
                fillColor: GlassStyle.fill05For(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
                            items: [
                if (PermissionsService().canAddBonus)
                  const DropdownMenuItem(
                    value: 'bonus',
                    child: Text(
                      'مكافأة',
                      style: TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
                if (PermissionsService().canAddLoan)
                  const DropdownMenuItem(
                    value: 'loan',
                    child: Text(
                      'سلفة',
                      style: TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'bonus'),
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
              ),
            ),
            const SizedBox(height: 10),

            // ============================================
            // المبلغ
            // ============================================
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'المبلغ (ج.م)',
                labelStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
                prefixIcon: Icon(
                  Icons.attach_money_rounded,
                  color: AppTheme.successFor(context),
                  size: 18,
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
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),

            // ============================================
            // عدد الأقساط (لسلفة بس)
            // ============================================
            if (isLoan) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _installmentsCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'عدد الأقساط',
                  hintText: 'مثال: 3',
                  labelStyle: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context),
                  ),
                  prefixIcon: Icon(
                    Icons.splitscreen_rounded,
                    color: AppTheme.warningOrangeSoftFor(context),
                    size: 18,
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
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 4),
                child: Text(
                  'سيتم إنشاء قسط لكل شهر تلقائيًا',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 10,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 10),

            // ============================================
            // السبب (اختياري)
            // ============================================
            TextField(
              controller: _reasonCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'السبب (اختياري)',
                labelStyle: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
                prefixIcon: Icon(
                  Icons.notes_rounded,
                  color: AppTheme.infoFor(context),
                  size: 18,
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
            final amount = double.tryParse(_amountCtrl.text) ?? 0;
            if (amount <= 0) return;

            final installments =
                isLoan ? (int.tryParse(_installmentsCtrl.text) ?? 1) : 1;

            Navigator.pop(context, {
              'type': _type,
              'amount': amount,
              'reason': _reasonCtrl.text.trim(),
              'installments': installments,
            });
          },
          child: Text(
            'حفظ',
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
// نهاية ملف vacations_page.dart
//
// الملف بيستخدم:
// - HRService: عمليات settings + vacations + adjustments
// - HRReportService: إبطال كاش التقرير بعد كل عملية
// - EmployeeService: جلب قائمة الموظفين
// - HRConstants: delayRuleLabels + weekdayNamesAr + dateToStr + monthToStr
// - HRVacationModel, HRAdjustmentModel, HREmployeeSettingsModel: من hr_models.dart
//
// الفروق الرئيسية عن النسخة القديمة:
// 1. 3 services بدل 4 (HRService موحد)
// 2. إبطال كاش التقرير بعد كل حفظ/حذف/تعديل
// 3. استخدام HRConstants بدل defaults محلية
// 4. استخدام getters من Models (isBonus, typeLabel, weeklyDayLabel)
// ============================================================