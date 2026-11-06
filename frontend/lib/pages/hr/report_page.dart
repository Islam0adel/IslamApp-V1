// lib/pages/hr/report_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/permissions_service.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/employee_service.dart';
import '../../services/hr_report_service.dart';
import '../../services/export_service.dart';
import '../../models/employee_model.dart';
import '../../models/hr_salary_report_model.dart';


/// صفحة تقرير راتب الموظف
///
/// - التقرير يظهر أوتوماتيك لما تختار موظف أو تغير الشهر
/// - Header: اسم + كود + badge المصدر، واختيار الشهر
/// - Cache-first (local-first من HRReportService)
class HRReportPage extends StatefulWidget {
  const HRReportPage({super.key});

  @override
  State<HRReportPage> createState() => _HRReportPageState();
}


class _HRReportPageState extends State<HRReportPage> {
  // ============================================================
  // Services
  // ============================================================

  final EmployeeService _employeeService = EmployeeService();
  final HRReportService _reportService = HRReportService();


  // ============================================================
  // State
  // ============================================================

  String _companyCode = '';
  String _companyName = '';
  bool _isLoading = true;
  bool _isGenerating = false;
  bool _isExporting = false;
  bool _isFetchingFromServer = false;

  List<EmployeeModel> _employees = [];
  EmployeeModel? _selectedEmployee;
  String _selectedMonth = '';

  HRSalaryReportModel? _report;

  bool _wasFromServer = false;


  // ============================================================
  // Lifecycle
  // ============================================================

  @override
  void initState() {
    super.initState();
    _selectedMonth = _currentMonth();
    _loadEmployees();
  }


  // ============================================================
  // Helpers
  // ============================================================

  String _currentMonth() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}";
  }


  // ============================================================
  // Load employees
  // ============================================================

  Future<void> _loadEmployees() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      _companyCode = prefs.getString('company_code') ?? '';
      _companyName = prefs.getString('company_name') ?? 'الشركة';

      if (_companyCode.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      final allEmployees = await _employeeService.getEmployeesList(
        companyCode: _companyCode,
      );

      // فلترة حسب canViewEmployee
      final filtered = allEmployees
          .where((e) =>
              PermissionsService().canViewEmployee(e.code, e.branchCode))
          .toList();

      if (mounted) {
        setState(() {
          _employees = filtered;
          _isLoading = false;

          // ⭐ اختيار أول موظف تلقائيًا + توليد التقرير
          if (filtered.isNotEmpty && _selectedEmployee == null) {
            _selectedEmployee = filtered.first;
            // ⭐ نولّد التقرير بعد ما الـ setState يخلص
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _generateReport();
            });
          }
        });
      }
    } catch (e) {
      print("❌ خطأ: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // ============================================================
  // اختيار الشهر (حوار شهور مخصص — يفتح على الشهور)
  // ============================================================

  Future<void> _pickMonth() async {
    final current = DateTime.parse('$_selectedMonth-01');

    final picked = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => _MonthPickerDialog(
        initialYear: current.year,
        initialMonth: current.month,
      ),
    );

    if (picked != null) {
      setState(() {
        _selectedMonth =
            "${picked.year}-${picked.month.toString().padLeft(2, '0')}";
        _report = null;
        _wasFromServer = false;
      });

      // ⭐ توليد التقرير تلقائيًا بعد تغيير الشهر
      if (_selectedEmployee != null) {
        await _generateReport();
      }
    }
  }


  // ============================================================
  // توليد التقرير (local-first)
  // ============================================================

  Future<void> _generateReport() async {
    if (_selectedEmployee == null) {
      _showSnackBar(
        "اختر موظف أولاً",
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _report = null;
      _wasFromServer = false;
    });

    try {
      final report = await _reportService.getSalaryReport(
        companyCode: _companyCode,
        employeeCode: _selectedEmployee!.code,
        month: _selectedMonth,
      );

      if (mounted) {
        setState(() {
          _report = report;
          _isGenerating = false;
        });

        if (report == null) {
          _showSnackBar(
            "فشل جلب التقرير",
            AppTheme.dangerStrongFor(context),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGenerating = false);
        _showSnackBar(
          "خطأ: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    }
  }


  // ============================================================
  // تحديث من السيرفر (force refresh)
  // ============================================================

  Future<void> _fetchFromServer() async {
    if (_selectedEmployee == null) {
      _showSnackBar(
        "اختر موظف أولاً",
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    setState(() {
      _isFetchingFromServer = true;
      _wasFromServer = false;
    });

    try {
      final report = await _reportService.getSalaryReportFromBackend(
        companyCode: _companyCode,
        employeeCode: _selectedEmployee!.code,
        month: _selectedMonth,
      );

      if (mounted) {
        setState(() {
          _report = report;
          _isFetchingFromServer = false;
          _wasFromServer = report != null;
        });

        if (report == null) {
          _showSnackBar(
            "فشل التحديث من السيرفر",
            AppTheme.dangerStrongFor(context),
          );
        } else {
          _showSnackBar(
            "تم التحديث من السيرفر ✅",
            AppTheme.successStrongFor(context),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isFetchingFromServer = false);
        _showSnackBar(
          "خطأ: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    }
  }


  // ============================================================
  // مسح كاش التقرير
  // ============================================================

  Future<void> _clearCache() async {
    if (_selectedEmployee == null) {
      _showSnackBar(
        "اختر موظف أولاً",
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    await _reportService.invalidateCache(
      companyCode: _companyCode,
      employeeCode: _selectedEmployee!.code,
    );

    if (mounted) {
      setState(() {
        _report = null;
        _wasFromServer = false;
      });
      _showSnackBar(
        "تم مسح الكاش — أعد توليد التقرير",
        AppTheme.successStrongFor(context),
      );
    }
  }


  // ============================================================
  // نسخ النص
  // ============================================================

  Future<void> _copyAsText() async {
    if (_report == null) return;

    final canSeeAmounts =
        PermissionsService().canSeeEmployeeSalary(_report!.employeeCode);

    if (!canSeeAmounts) {
      _showSnackBar(
        "ليس لديك صلاحية نسخ البيانات المالية لهذا الموظف",
        AppTheme.dangerStrongFor(context),
      );
      return;
    }

    final text = _report!.toPlainText();
    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      _showSnackBar(
        "تم النسخ - الصقه في واتساب أو أي تطبيق",
        AppTheme.successStrongFor(context),
      );
    }
  }


  // ============================================================
  // تصدير PDF
  // ============================================================

  Future<void> _exportPDF() async {
    if (_report == null) return;

    setState(() => _isExporting = true);

    try {
      final r = _report!;

      final attendanceData = r.attendanceDetails.map((d) {
        return <String, dynamic>{
          'date': d.date,
          'status': d.statusLabel,
          'check_in': d.checkIn ?? '-',
          'check_out': d.checkOut ?? '-',
          'late': d.lateMinutes > 0 ? d.lateMinutes : '-',
          'overtime': d.overtimeMinutes > 0 ? d.overtimeMinutes : '-',
          'note': d.note.isEmpty ? '-' : d.note,
        };
      }).toList();

      final canSeeAmounts =
          PermissionsService().canSeeEmployeeSalary(r.employeeCode);

      final summary = canSeeAmounts
          ? <String, dynamic>{
              'الراتب الشهري (الأساسي)': r.baseSalary,
              if (r.elapsedDays < r.workDays)
                'المرتب المستحق (${r.elapsedDays}/${r.workDays} يوم)':
                    r.basePay
              else
                'المرتب المستحق': r.basePay,
              if (r.futureDays > 0 && r.baseSalary > r.basePay)
                'غير مستحق (${r.futureDays} يوم لم يأتِ)':
                    -(r.baseSalary - r.basePay),
              if (r.absenceDeduction > 0)
                'خصم غياب (${r.absentDays} يوم)': -r.absenceDeduction,
              if (r.lateDeduction > 0)
                'خصم تأخير (${r.lateMinutesTotal} د)': -r.lateDeduction,
              if (r.earlyLeaveDeduction > 0)
                'خصم انصراف مبكر (${r.earlyLeaveMinutesTotal} د)':
                    -r.earlyLeaveDeduction,
              if (r.overtimeBonus > 0)
                'إضافي (${r.overtimeMinutesTotal} د)': r.overtimeBonus,
              if (r.bonusesTotal > 0) 'إجمالي المكافآت': r.bonusesTotal,
              if (r.deductionsTotal > 0)
                'إجمالي الخصومات': -r.deductionsTotal,
              if (r.loansTotal > 0) 'إجمالي السلف': -r.loansTotal,
              'صافي الراتب': r.netSalary,
            }
          : <String, dynamic>{
              'حاضر': r.presentDays,
              'غائب': r.absentDays,
              'إجازة': r.vacationDays,
              if (r.futureDays > 0) 'قادم': r.futureDays,
              'تأخير (دقيقة)': r.lateMinutesTotal,
              'إضافي (دقيقة)': r.overtimeMinutesTotal,
            };

      final periodLabel = r.futureDays > 0
          ? 'شهر ${r.month} — عدّى ${r.elapsedDays} من ${r.workDays} يوم (متبقي ${r.futureDays})'
          : 'شهر ${r.month} (كامل)';

      await ExportService.exportToPDF(
        data: attendanceData,
        title: 'تقرير راتب - ${r.employeeName} - ${r.month}',
        headers: [
          'التاريخ',
          'الحالة',
          'دخول',
          'خروج',
          'تأخير',
          'إضافي',
          'ملاحظات',
        ],
        keys: [
          'date',
          'status',
          'check_in',
          'check_out',
          'late',
          'overtime',
          'note',
        ],
        companyName: _companyName,
        branchName: r.branchCode,
        employee: r.employeeName,
        period: periodLabel,
        summary: summary,
        totalAmount: canSeeAmounts ? r.netSalary : null,
      );

      if (mounted) {
        _showSnackBar(
          "تم تصدير PDF بنجاح",
          AppTheme.successStrongFor(context),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          "خطأ في PDF: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }


  // ============================================================
  // تصدير Excel
  // ============================================================

  Future<void> _exportExcel() async {
    if (_report == null) return;

    setState(() => _isExporting = true);

    try {
      final r = _report!;

      final attendanceData = r.attendanceDetails.map((d) {
        return <String, dynamic>{
          'date': d.date,
          'status': d.statusLabel,
          'check_in': d.checkIn ?? '',
          'check_out': d.checkOut ?? '',
          'late': d.lateMinutes,
          'overtime': d.overtimeMinutes,
          'note': d.note,
        };
      }).toList();

      final canSeeAmounts =
          PermissionsService().canSeeEmployeeSalary(r.employeeCode);

      final summary = canSeeAmounts
          ? <String, dynamic>{
              'الراتب الشهري (الأساسي)': r.baseSalary,
              if (r.elapsedDays < r.workDays)
                'المرتب المستحق (${r.elapsedDays}/${r.workDays} يوم)':
                    r.basePay
              else
                'المرتب المستحق': r.basePay,
              if (r.futureDays > 0 && r.baseSalary > r.basePay)
                'غير مستحق (${r.futureDays} يوم لم يأتِ)':
                    -(r.baseSalary - r.basePay),
              if (r.absenceDeduction > 0) 'خصم غياب': -r.absenceDeduction,
              if (r.lateDeduction > 0) 'خصم تأخير': -r.lateDeduction,
              if (r.earlyLeaveDeduction > 0)
                'خصم انصراف مبكر': -r.earlyLeaveDeduction,
              if (r.overtimeBonus > 0) 'إضافي': r.overtimeBonus,
              if (r.bonusesTotal > 0) 'إجمالي المكافآت': r.bonusesTotal,
              if (r.deductionsTotal > 0)
                'إجمالي الخصومات': -r.deductionsTotal,
              if (r.loansTotal > 0) 'إجمالي السلف': -r.loansTotal,
              'صافي الراتب': r.netSalary,
            }
          : <String, dynamic>{
              'حاضر': r.presentDays,
              'غائب': r.absentDays,
              'إجازة': r.vacationDays,
              if (r.futureDays > 0) 'قادم': r.futureDays,
              'تأخير (دقيقة)': r.lateMinutesTotal,
              'إضافي (دقيقة)': r.overtimeMinutesTotal,
            };

      final periodLabel = r.futureDays > 0
          ? 'شهر ${r.month} — ${r.elapsedDays}/${r.workDays} يوم'
          : 'شهر ${r.month}';

      await ExportService.exportToExcel(
        attendanceData,
        'راتب ${r.employeeName} - ${r.month}',
        [
          'التاريخ',
          'الحالة',
          'دخول',
          'خروج',
          'تأخير (د)',
          'إضافي (د)',
          'ملاحظات',
        ],
        [
          'date',
          'status',
          'check_in',
          'check_out',
          'late',
          'overtime',
          'note',
        ],
        companyName: _companyName,
        branchName: r.branchCode,
        employee: r.employeeName,
        period: periodLabel,
        summary: summary,
      );

      if (mounted) {
        _showSnackBar(
          "تم تصدير Excel بنجاح",
          AppTheme.successStrongFor(context),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          "خطأ في Excel: $e",
          AppTheme.dangerStrongFor(context),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
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
    if (!PermissionsService().canOpenReportPage) {
      return _buildNoPermissionScreen('عرض التقارير');
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "تقرير الراتب",
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
          if (_report != null)
            IconButton(
              icon: _isFetchingFromServer
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.accentFor(context),
                      ),
                    )
                  : Icon(
                      Icons.cloud_download_rounded,
                      color: AppTheme.accentFor(context),
                    ),
              onPressed: _isFetchingFromServer || _isExporting
                  ? null
                  : _fetchFromServer,
              tooltip: 'تحديث من السيرفر',
            ),

          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert_rounded,
              color: AppTheme.textMainFor(context),
            ),
            onSelected: (value) async {
              if (value == 'clear_cache') {
                await _clearCache();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'clear_cache',
                child: Row(
                  children: [
                    Icon(
                      Icons.cleaning_services_rounded,
                      color: AppTheme.dangerFor(context),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'مسح الكاش',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        color: AppTheme.textMainFor(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    children: [
                      _buildEmployeeDropdown(),
                      const SizedBox(height: 10),
                      _buildHeaderCard(),

                      // ⭐ زر التوليد اتشال — التقرير يظهر تلقائي

                      if (_isGenerating) ...[
                        const SizedBox(height: 30),
                        Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.accentFor(context),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'جاري حساب التقرير...',
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 12,
                          ),
                        ),
                      ] else if (_report != null) ...[
                        const SizedBox(height: 12),
                        _buildReportView(_report!),
                        const SizedBox(height: 20),
                        _buildExportButtons(),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }


  // ============================================================
  // Dropdown الموظف
  // ============================================================

  Widget _buildEmployeeDropdown() {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: DropdownButtonFormField<EmployeeModel>(
          initialValue: _selectedEmployee,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'الموظف',
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
          items: _employees
              .map((e) => DropdownMenuItem(
                    value: e,
                    child: Text(
                      '${e.name} (${e.code})',
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  ))
              .toList(),
          onChanged: _isGenerating || _isFetchingFromServer
              ? null
              : (v) async {
                  setState(() {
                    _selectedEmployee = v;
                    _report = null;
                    _wasFromServer = false;
                  });
                  // ⭐ auto-generate بعد اختيار الموظف
                  if (v != null) {
                    await _generateReport();
                  }
                },
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMainFor(context),
          ),
        ),
      ),
    );
  }


  // ============================================================
  // Header Card (اسم + كود + badge على اليمين، والتاريخ على الشمال)
  // ============================================================

  Widget _buildHeaderCard() {
    final emp = _selectedEmployee;
    final name = emp?.name ?? '—';
    final code = emp?.code ?? '—';

    return GlassCard(
      child: Row(
        children: [
          // ─── الجزء اليمين: اسم + كود + badge ───
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'كود: $code',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 11,
                  ),
                ),
                if (_report != null) ...[
                  const SizedBox(height: 6),
                  _buildSourceBadge(),
                ],
              ],
            ),
          ),

          const SizedBox(width: 10),

          // ─── الجزء الشمال: اختيار الشهر ───
          InkWell(
            onTap:
                _isGenerating || _isFetchingFromServer ? null : _pickMonth,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: GlassStyle.fill05For(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: GlassStyle.line10For(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'الشهر',
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 9,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.calendar_month_rounded,
                        color: AppTheme.accentFor(context),
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _selectedMonth,
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // عرض التقرير
  // ============================================================

  Widget _buildReportView(HRSalaryReportModel r) {
    final canSeeAmounts =
        PermissionsService().canSeeEmployeeSalary(r.employeeCode);

    return Column(
      children: [
        // ============================================
        // ملخص الحضور + إجماليات مالية (كمربعات صغيرة)
        // ============================================
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ملخص الحضور',
                style: TextStyle(
                  color: AppTheme.warningFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _statChip('حاضر', '${r.presentDays}',
                      AppTheme.successFor(context)),
                  _statChip('غائب', '${r.absentDays}',
                      AppTheme.dangerFor(context)),
                  _statChip('إجازة', '${r.vacationDays}',
                      AppTheme.extraTealFor(context)),
                  if (r.futureDays > 0)
                    _statChip('قادم', '${r.futureDays}',
                        AppTheme.textMutedFor(context)),
                  _statChip('تأخير', '${r.lateMinutesTotal} د',
                      AppTheme.warningOrangeSoftFor(context)),
                  _statChip('إضافي', '${r.overtimeMinutesTotal} د',
                      AppTheme.accentFor(context)),
                ],
              ),

              // ⭐ إجماليات مالية كـ chips (زي ملخص الحضور)
              if (r.adjustmentLines.isNotEmpty) ...[
                const SizedBox(height: 10),
                Divider(color: GlassStyle.line10For(context), height: 1),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _statChip(
                      '💰 مكافآت',
                      canSeeAmounts
                          ? '${r.bonusesTotal.toStringAsFixed(2)} ج.م'
                          : '${r.adjustmentLines.where((l) => l.type == 'bonus').length} بند',
                      AppTheme.successFor(context),
                    ),
                    _statChip(
                      '💸 خصومات',
                      canSeeAmounts
                          ? '${r.deductionsTotal.toStringAsFixed(2)} ج.م'
                          : '${r.adjustmentLines.where((l) => l.type == 'deduction').length} بند',
                      AppTheme.dangerFor(context),
                    ),
                    _statChip(
                      '📋 سلف',
                      canSeeAmounts
                          ? '${r.loansTotal.toStringAsFixed(2)} ج.م'
                          : '${r.adjustmentLines.where((l) => l.type == 'loan').length} بند',
                      AppTheme.warningOrangeSoftFor(context),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ============================================
        // كالندر الحضور
        // ============================================
        _buildAttendanceCalendar(r),
        const SizedBox(height: 12),

        // ============================================
        // تفاصيل الراتب
        // ============================================
        if (canSeeAmounts) ...[
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'تفاصيل الراتب',
                  style: TextStyle(
                    color: AppTheme.warningFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                _salaryLine(
                  'الراتب الشهري (الأساسي)',
                  r.baseSalary,
                  AppTheme.textMutedFor(context),
                ),
                _salaryLine(
                  r.elapsedDays < r.workDays
                      ? 'المرتب المستحق (${r.elapsedDays}/${r.workDays} يوم)'
                      : 'المرتب المستحق',
                  r.basePay,
                  AppTheme.textMainFor(context),
                ),
                if (r.futureDays > 0 && r.baseSalary > r.basePay)
                  _salaryLine(
                    'غير مستحق (${r.futureDays} يوم لم يأتِ)',
                    -(r.baseSalary - r.basePay),
                    AppTheme.textMutedFor(context),
                  ),
                if (r.absenceDeduction > 0)
                  _salaryLine(
                    'خصم غياب (${r.absentDays} يوم)',
                    -r.absenceDeduction,
                    AppTheme.dangerFor(context),
                  ),
                if (r.lateDeduction > 0)
                  _salaryLine(
                    'خصم تأخير (${r.lateMinutesTotal} د)',
                    -r.lateDeduction,
                    AppTheme.dangerFor(context),
                  ),
                if (r.earlyLeaveDeduction > 0)
                  _salaryLine(
                    'خصم انصراف مبكر',
                    -r.earlyLeaveDeduction,
                    AppTheme.dangerFor(context),
                  ),
                if (r.overtimeBonus > 0)
                  _salaryLine(
                    'إضافي (${r.overtimeMinutesTotal} د)',
                    r.overtimeBonus,
                    AppTheme.successFor(context),
                  ),
                for (final line in r.adjustmentLines)
                  _salaryLine(
                    line.label,
                    line.amount,
                    line.amount >= 0
                        ? AppTheme.successFor(context)
                        : AppTheme.dangerFor(context),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ============================================
          // صافي الراتب
          // ============================================
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: r.netSalary < 0
                  ? AppTheme.dangerFor(context).withValues(alpha: 0.1)
                  : Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: r.netSalary < 0
                    ? AppTheme.dangerFor(context).withValues(alpha: 0.4)
                    : Colors.green.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '💰 صافي الراتب',
                      style: TextStyle(
                        color: r.netSalary < 0
                            ? AppTheme.dangerFor(context)
                            : Colors.green[800],
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${r.netSalary.toStringAsFixed(2)} ج.م',
                      style: TextStyle(
                        color: r.netSalary < 0
                            ? AppTheme.dangerFor(context)
                            : Colors.green[900],
                        fontFamily: 'Cairo',
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (r.netSalary < 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    '⚠️ مدين للشركة بـ ${r.debtRemaining.toStringAsFixed(2)} ج.م',
                    style: TextStyle(
                      color: AppTheme.dangerFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }


  // ============================================================
  // كالندر الحضور (مُصغّر)
  // ============================================================

  Widget _buildAttendanceCalendar(HRSalaryReportModel r) {
    final firstDay = DateTime.parse('${r.month}-01');
    final daysInMonth = DateTime(firstDay.year, firstDay.month + 1, 0).day;
    final firstWeekday = firstDay.weekday % 7;

    final statusMap = <String, String>{};
    for (final d in r.attendanceDetails) {
      statusMap[d.date] = d.status;
    }

    final dayLabels = ['ح', 'ن', 'ث', 'ر', 'خ', 'ج', 'س'];

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_month_rounded,
                  color: AppTheme.warningFor(context), size: 18),
              const SizedBox(width: 8),
              Text(
                'تقويم الحضور',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Header: أيام الأسبوع
          Row(
            children: dayLabels.map((label) {
              return Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 6),

          // Grid (مُصغّر)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
              mainAxisExtent: 22,
            ),
            itemCount: firstWeekday + daysInMonth,
            itemBuilder: (context, index) {
              if (index < firstWeekday) {
                return const SizedBox.shrink();
              }

              final day = index - firstWeekday + 1;
              final dateStr = '${r.month}-${day.toString().padLeft(2, '0')}';
              final status = statusMap[dateStr];
              final color = _calendarColor(status);

              return Container(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: status != null ? 0.2 : 0.05),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: color.withValues(alpha: status != null ? 0.5 : 0.1),
                    width: status != null ? 1 : 0.5,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$day',
                  style: TextStyle(
                    color: status != null
                        ? color
                        : AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 10),
          Divider(color: GlassStyle.line10For(context), height: 1),
          const SizedBox(height: 8),

          // Legend
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _legendItem(AppTheme.successFor(context), 'حاضر'),
              _legendItem(AppTheme.dangerFor(context), 'غائب'),
              _legendItem(AppTheme.extraTealFor(context), 'إجازة'),
              _legendItem(AppTheme.warningOrangeSoftFor(context), 'متأخر'),
              _legendItem(AppTheme.infoFor(context), 'إذن'),
            ],
          ),
        ],
      ),
    );
  }


  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: color, width: 1),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            fontSize: 9,
          ),
        ),
      ],
    );
  }


  Color _calendarColor(String? status) {
    switch (status) {
      case 'present':
        return AppTheme.successFor(context);
      case 'late':
        return AppTheme.warningOrangeSoftFor(context);
      case 'absent':
        return AppTheme.dangerFor(context);
      case 'vacation':
        return AppTheme.extraTealFor(context);
      case 'permission':
        return AppTheme.infoFor(context);
      case 'future':
        return AppTheme.textMutedFor(context);
      default:
        return AppTheme.textMutedFor(context);
    }
  }


  // ============================================================
  // Badge مصدر التقرير
  // ============================================================

  Widget _buildSourceBadge() {
    final isServer = _wasFromServer;
    final color =
        isServer ? AppTheme.successFor(context) : AppTheme.infoFor(context);
    final icon = isServer
        ? Icons.cloud_done_rounded
        : Icons.phone_android_rounded;
    final label = isServer ? 'من السيرفر (رسمي)' : 'حساب محلي';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontFamily: 'Cairo',
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // أزرار التصدير
  // ============================================================

  Widget _buildExportButtons() {
    if (!PermissionsService().canExportReport) {
      return const SizedBox.shrink();
    }

    return Row(
      children: [
        if (_report != null &&
            PermissionsService()
                .canSeeEmployeeSalary(_report!.employeeCode))
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isExporting ? null : _copyAsText,
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text(
                'نسخ',
                style: TextStyle(fontFamily: 'Cairo'),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        if (_report != null &&
            PermissionsService()
                .canSeeEmployeeSalary(_report!.employeeCode))
          const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isExporting ? null : _exportPDF,
            icon: _isExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: const Text(
              'PDF',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.dangerFor(context),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isExporting ? null : _exportExcel,
            icon: const Icon(Icons.table_chart_rounded, size: 18),
            label: const Text(
              'Excel',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green[700],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }


  // ============================================================
  // Helpers — عرض
  // ============================================================

  Widget _statChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }


  Widget _salaryLine(String label, double amount, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontSize: 13,
              ),
            ),
          ),
          Text(
            '${amount.toStringAsFixed(2)} ج.م',
            style: TextStyle(
              color: color,
              fontFamily: 'Cairo',
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildNoPermissionScreen(String permission) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "تقرير الراتب",
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
// حوار اختيار الشهر (يفتح على الشهور مش السنة)
// ============================================================

class _MonthPickerDialog extends StatefulWidget {
  final int initialYear;
  final int initialMonth;

  const _MonthPickerDialog({
    required this.initialYear,
    required this.initialMonth,
  });

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
    _year = widget.initialYear;
    _month = widget.initialMonth;
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