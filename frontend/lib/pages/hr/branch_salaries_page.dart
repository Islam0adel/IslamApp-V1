// lib/pages/hr/branch_salaries_page.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/hr_report_service.dart';
import '../../services/permissions_service.dart';


/// صفحة إجمالي الرواتب لكل فرع
///
/// - Cache: تحميل أول مرة من الباك، بعد كده من Hive
/// - زر تحديث يدوي في الـ AppBar
/// - إخفاء المبالغ لو المستخدم مش عنده canViewSalaryAmounts
class BranchSalariesPage extends StatefulWidget {
  const BranchSalariesPage({super.key});

  @override
  State<BranchSalariesPage> createState() => _BranchSalariesPageState();
}


class _BranchSalariesPageState extends State<BranchSalariesPage> {
  final HRReportService _reportService = HRReportService();

  String _companyCode = '';
  bool _isLoading = false;
  bool _hasLoaded = false;

  String _selectedMonth = '';
  String? _selectedBranch; // null = كل الشركة

  List<Map<String, String>> _branches = [];

  Map<String, dynamic>? _data;


  // ============================================================
  // Lifecycle
  // ============================================================

  @override
  void initState() {
    super.initState();
    _selectedMonth = _currentMonth();
    _loadInitialData();
  }


  String _currentMonth() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }


  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    _companyCode = prefs.getString('company_code') ?? '';

    if (_companyCode.isEmpty) return;

    // تحميل الفروع
    final box = Hive.box('coding_box');
    final raw = box.get('${_companyCode}_branches');

    final allBranches = <Map<String, String>>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final code = item['code']?.toString() ?? '';
        final name = item['name']?.toString() ?? '';
        if (code.isEmpty) continue;
        allBranches.add({'code': code, 'name': name});
      }
    }

    // فلترة حسب صلاحيات المستخدم
    final allowed = PermissionsService().allowedBranches;
    List<Map<String, String>> filteredBranches;

    if (allowed == null || allowed.contains('all')) {
      filteredBranches = allBranches;
    } else {
      filteredBranches = allBranches
          .where((b) => allowed.contains(b['code']))
          .toList();
    }

    if (mounted) {
      setState(() {
        _branches = filteredBranches;
      });
    }

    // تحديد فرع تلقائي (لو مستخدم عنده فرع واحد)
    if (filteredBranches.length == 1) {
      _selectedBranch = filteredBranches.first['code'];
    }

    // تحميل الإجماليات (من الكاش أو السيرفر)
    _loadSalaries();
  }


  // ============================================================
  // Load
  // ============================================================

  Future<void> _loadSalaries({bool forceRefresh = false}) async {
    if (_companyCode.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final data = await _reportService.getBranchSalariesTotals(
        companyCode: _companyCode,
        month: _selectedMonth,
        branchCode: _selectedBranch,
        forceRefresh: forceRefresh,
      );

      if (!mounted) return;

      setState(() {
        _data = data;
        _isLoading = false;
        _hasLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(
        "خطأ في تحميل البيانات: $e",
        AppTheme.dangerStrongFor(context),
      );
    }
  }


  // ============================================================
  // Actions
  // ============================================================

  Future<void> _pickMonth() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => _MonthPickerDialog(
        initialYear: DateTime.parse('$_selectedMonth-01').year,
        initialMonth: DateTime.parse('$_selectedMonth-01').month,
      ),
    );

    if (picked != null) {
      setState(() {
        _selectedMonth =
            '${picked.year}-${picked.month.toString().padLeft(2, '0')}';
        _data = null;
      });
      _loadSalaries();
    }
  }


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
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // فحص الصلاحية
    if (!PermissionsService().canViewBranchSalaryReport) {
      return _buildNoPermissionScreen();
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "إجمالي الرواتب",
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
              Icons.refresh_rounded,
              color: AppTheme.textMainFor(context),
            ),
            onPressed:
                _isLoading ? null : () => _loadSalaries(forceRefresh: true),
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
          child: Column(
            children: [
              // Filters
              Padding(
                padding: const EdgeInsets.all(15),
                child: Column(
                  children: [
                    _buildMonthPicker(),
                    const SizedBox(height: 10),
                    _buildBranchPicker(),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.accentFor(context),
                        ),
                      )
                    : !_hasLoaded
                        ? _buildEmptyState('اضغط تحديث لتحميل البيانات')
                        : _buildContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }


  // ============================================================
  // Filters
  // ============================================================

  Widget _buildMonthPicker() {
    return GlassCard(
      padding: const EdgeInsets.all(4),
      child: InkWell(
        onTap: _isLoading ? null : _pickMonth,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
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
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      _selectedMonth,
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
                size: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }


  Widget _buildBranchPicker() {
    final allowed = PermissionsService().allowedBranches;
    final canChooseAll = allowed == null || allowed.contains('all');

    // لو المستخدم عنده فرع واحد بس، مفيش داعي للاختيار
    if (_branches.length == 1 && !canChooseAll) {
      return GlassCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              Icons.storefront_rounded,
              color: AppTheme.infoFor(context),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'الفرع',
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    _branches.first['name'] ?? '',
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
          ],
        ),
      );
    }

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: _selectedBranch,
            isExpanded: true,
            dropdownColor: AppTheme.dropdownBackground(context),
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: AppTheme.infoFor(context),
            ),
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
              fontSize: 14,
            ),
            items: [
              if (canChooseAll)
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Row(
                    children: [
                      Icon(Icons.business_rounded, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'كل الفروع (الشركة)',
                        style: TextStyle(fontFamily: 'Cairo'),
                      ),
                    ],
                  ),
                ),
              ..._branches.map((b) => DropdownMenuItem<String?>(
                    value: b['code'],
                    child: Row(
                      children: [
                        Icon(Icons.storefront_rounded, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          b['name'] ?? '',
                          style: const TextStyle(fontFamily: 'Cairo'),
                        ),
                      ],
                    ),
                  )),
            ],
            onChanged: _isLoading
                ? null
                : (v) {
                    setState(() {
                      _selectedBranch = v;
                      _data = null;
                    });
                    _loadSalaries();
                  },
          ),
        ),
      ),
    );
  }


  // ============================================================
  // Content
  // ============================================================

  Widget _buildContent() {
    if (_data == null) {
      return _buildEmptyState('لا توجد بيانات');
    }

    final totals = _data!['totals'] as Map<String, dynamic>? ?? {};
    final employees = _data!['employees'] as List<dynamic>? ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
      child: Column(
        children: [
          // Totals card
          _buildTotalsCard(totals),

          const SizedBox(height: 15),

          // Employees list
          if (employees.isEmpty)
            _buildEmptyState('لا يوجد موظفون في هذا الفرع')
          else ...[
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8, right: 4),
                child: Text(
                  'تفاصيل الموظفين (${employees.length})',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            ...employees.map(_buildEmployeeRow),
          ],
        ],
      ),
    );
  }


  // ============================================================
  // Totals card
  //
  // ⭐ لو مش عنده canViewSalaryAmounts → يظهر العدد بس
  // ============================================================

  Widget _buildTotalsCard(Map<String, dynamic> totals) {
    final canSeeAmounts = PermissionsService().canViewSalaryAmounts;

    final count = totals['employees_count'] ?? 0;
    final basePay = totals['total_base_pay'] ?? 0.0;
    final absence = totals['total_absence_deduction'] ?? 0.0;
    final delay = totals['total_delay_deduction'] ?? 0.0;
    final overtime = totals['total_overtime_bonus'] ?? 0.0;
    final bonuses = totals['total_bonuses'] ?? 0.0;
    final deductions = totals['total_deductions'] ?? 0.0;
    final loans = totals['total_loans'] ?? 0.0;
    final net = totals['total_net_salary'] ?? 0.0;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.summarize_rounded,
                color: AppTheme.extraPurpleFor(context),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'إجماليات $_selectedMonth',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Count — دايماً ظاهر
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.infoFor(context).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'عدد الموظفين',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 12,
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    color: AppTheme.infoFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // لو مش عنده صلاحية → قفل ونصيحة
          if (!canSeeAmounts) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.warningOrangeSoftFor(context)
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppTheme.warningOrangeSoftFor(context)
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    color: AppTheme.warningOrangeSoftFor(context),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'المبالغ المالية مخفية — تحتاج صلاحية عرض المبالغ',
                      style: TextStyle(
                        color: AppTheme.warningOrangeSoftFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Divider(color: GlassStyle.line10For(context), height: 1),
            const SizedBox(height: 8),

            // Detailed breakdown
            _totalsRow('الراتب الأساسي', basePay, AppTheme.textMainFor(context)),
            if (absence > 0)
              _totalsRow('خصم غياب', -absence, AppTheme.dangerFor(context)),
            if (delay > 0)
              _totalsRow('خصم تأخير', -delay, AppTheme.dangerFor(context)),
            if (overtime > 0)
              _totalsRow('إضافي', overtime, AppTheme.successFor(context)),
            if (bonuses > 0)
              _totalsRow('مكافآت', bonuses, AppTheme.successFor(context)),
            if (deductions > 0)
              _totalsRow('خصومات', -deductions, AppTheme.dangerFor(context)),
            if (loans > 0)
              _totalsRow('سلف', -loans, AppTheme.warningOrangeSoftFor(context)),

            const SizedBox(height: 10),
            Divider(color: GlassStyle.line10For(context), height: 2),
            const SizedBox(height: 8),

            // Net total
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: net < 0
                    ? AppTheme.dangerFor(context).withValues(alpha: 0.1)
                    : Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: net < 0
                      ? AppTheme.dangerFor(context).withValues(alpha: 0.4)
                      : Colors.green.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '💰 صافي الإجمالي',
                    style: TextStyle(
                      color: net < 0
                          ? AppTheme.dangerFor(context)
                          : Colors.green[800],
                      fontFamily: 'Cairo',
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${_formatAmount(net)} ج.م',
                    style: TextStyle(
                      color: net < 0
                          ? AppTheme.dangerFor(context)
                          : Colors.green[900],
                      fontFamily: 'Cairo',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }


  Widget _totalsRow(String label, dynamic amount, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
              fontSize: 12,
            ),
          ),
          Text(
            '${_formatAmount(amount)} ج.م',
            style: TextStyle(
              color: color,
              fontFamily: 'Cairo',
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // صف موظف
  //
  // ⭐ لو مش عنده canViewSalaryAmounts → يظهر "—" بدل المبلغ
  // ============================================================

  Widget _buildEmployeeRow(dynamic emp) {
    final canSeeAmounts = PermissionsService().canViewSalaryAmounts;

    final code = emp['employee_code']?.toString() ?? '';
    final name = emp['employee_name']?.toString() ?? '';
    final net = emp['net_salary'] ?? 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.accentFor(context).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                  color: AppTheme.accentFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'كود: $code',
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            // المبلغ — يظهر فقط لو عنده صلاحية
            if (canSeeAmounts)
              Text(
                '${_formatAmount(net)} ج.م',
                style: TextStyle(
                  color: (net as num) < 0
                      ? AppTheme.dangerFor(context)
                      : Colors.green[700],
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              )
            else
              Icon(
                Icons.lock_outline_rounded,
                color: AppTheme.textMutedFor(context),
                size: 16,
              ),
          ],
        ),
      ),
    );
  }


  Widget _buildEmptyState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.summarize_outlined,
              size: 64,
              color: AppTheme.textMutedFor(context),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildNoPermissionScreen() {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "إجمالي الرواتب",
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
                  'ليس لديك صلاحية عرض تقرير إجمالي الرواتب',
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


  String _formatAmount(dynamic value) {
    if (value == null) return '0.00';
    final n = value is num
        ? value.toDouble()
        : double.tryParse(value.toString()) ?? 0.0;
    return n.toStringAsFixed(2);
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