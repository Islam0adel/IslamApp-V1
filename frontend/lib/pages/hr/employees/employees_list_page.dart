// lib/pages/hr/employees/employees_list_page.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/theme.dart';
import '../../../views/widgets/glass_card.dart';
import '../../../services/employee_service.dart';
import '../../../services/permissions_service.dart';
import '../../../models/employee_model.dart';
import 'employee_form_page.dart';
import 'employee_profile_page.dart';


/// صفحة قائمة الموظفين
///
/// الميزات:
/// - بحث فوري (اسم/كود/هاتف/إيميل/رقم قومي)
/// - فلترة بالفرع والحالة
/// - ترتيب (كود/اسم/راتب/تاريخ تعيين)
/// - عرض/تعديل/حذف لكل موظف
/// - فلترة تلقائية حسب canViewEmployee
class EmployeesListPage extends StatefulWidget {
  const EmployeesListPage({super.key});

  @override
  State<EmployeesListPage> createState() => _EmployeesListPageState();
}


class _EmployeesListPageState extends State<EmployeesListPage> {
  // ============================================================
  // Services
  // ============================================================

  final EmployeeService _employeeService = EmployeeService();


  // ============================================================
  // State
  // ============================================================

  String _companyCode = '';
  bool _isLoading = true;

  List<EmployeeModel> _allEmployees = [];
  List<EmployeeModel> _filteredEmployees = [];

  // Filters
  String _searchQuery = '';
  String? _selectedBranch;  // null = all
  String? _selectedStatus;  // null = all
  String _sortBy = 'code';

  List<Map<String, String>> _branches = [];

  final TextEditingController _searchController = TextEditingController();


  // ============================================================
  // Lifecycle
  // ============================================================

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }


  // ============================================================
  // Load data
  // ============================================================

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      _companyCode = prefs.getString('company_code') ?? '';

      if (_companyCode.isEmpty) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // تحميل الفروع (للفلترة)
      _loadBranches();

      // تحميل الموظفين
      final all = await _employeeService.getEmployeesList(
        companyCode: _companyCode,
      );

      // فلترة حسب الصلاحيات
      _allEmployees = all
          .where((e) =>
              PermissionsService().canViewEmployee(e.code, e.branchCode))
          .toList();

      _applyFilters();

      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      print("❌ خطأ في تحميل الموظفين: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }


  void _loadBranches() {
    final box = Hive.box('coding_box');
    final key = '${_companyCode}_branches';
    final raw = box.get(key);

    _branches = [];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final code = item['code']?.toString() ?? '';
        final name = item['name']?.toString() ?? '';
        if (code.isEmpty) continue;
        _branches.add({'code': code, 'name': name});
      }
    }
  }


  // ============================================================
  // Filters
  // ============================================================

  void _applyFilters() {
    var filtered = List<EmployeeModel>.from(_allEmployees);

    // Search
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase().trim();
      filtered = filtered.where((e) {
        return e.name.toLowerCase().contains(q) ||
            e.code.toLowerCase().contains(q) ||
            e.phone.toLowerCase().contains(q) ||
            e.email.toLowerCase().contains(q) ||
            e.nationalId.toLowerCase().contains(q);
      }).toList();
    }

    // Branch filter
    if (_selectedBranch != null) {
      filtered =
          filtered.where((e) => e.branchCode == _selectedBranch).toList();
    }

    // Status filter
    if (_selectedStatus != null) {
      filtered =
          filtered.where((e) => e.status == _selectedStatus).toList();
    }

    // Sort
    switch (_sortBy) {
      case 'name':
        filtered.sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'salary':
        filtered.sort((a, b) => b.salary.compareTo(a.salary));
        break;
      case 'hire_date':
        filtered.sort((a, b) => b.hireDate.compareTo(a.hireDate));
        break;
      case 'code':
      default:
        filtered.sort((a, b) {
          final aC = int.tryParse(a.code) ?? 0;
          final bC = int.tryParse(b.code) ?? 0;
          return aC.compareTo(bC);
        });
    }

    setState(() => _filteredEmployees = filtered);
  }


  void _onSearchChanged(String value) {
    _searchQuery = value;
    _applyFilters();
  }


  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _searchQuery = '';
      _selectedBranch = null;
      _selectedStatus = null;
      _sortBy = 'code';
    });
    _applyFilters();
  }


  // ============================================================
  // Actions
  // ============================================================

  Future<void> _openForm({EmployeeModel? employee}) async {
    if (!PermissionsService().canManageEmployees) {
      _showSnackBar(
        "ليس لديك صلاحية إدارة الموظفين",
        AppTheme.dangerFor(context),
      );
      return;
    }

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EmployeeFormPage(
          companyCode: _companyCode,
          employee: employee,
        ),
      ),
    );

    if (result == true) {
      _loadData();
    }
  }


  Future<void> _openProfile(EmployeeModel employee) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmployeeProfilePage(
          companyCode: _companyCode,
          employeeCode: employee.code,
        ),
      ),
    );

    // reload بعد الرجوع (ممكن يكون فيه تعديلات)
    _loadData();
  }


  Future<void> _confirmDelete(EmployeeModel employee) async {
    if (!PermissionsService().canManageEmployees) {
      _showSnackBar(
        "ليس لديك صلاحية حذف الموظفين",
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
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: AppTheme.dangerFor(context),
              size: 24,
            ),
            const SizedBox(width: 8),
            Text(
              'حذف الموظف',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          'سيتم حذف "${employee.name}" (${employee.code}).\n\n'
          'ملاحظة: السجل يبقى محفوظ في قاعدة البيانات (soft delete) '
          'لكن لن يظهر في القوائم.',
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            height: 1.5,
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

    final ok = await _employeeService.deleteEmployee(
      companyCode: _companyCode,
      code: employee.code,
    );

    if (!mounted) return;

    if (ok) {
      _showSnackBar(
        "تم حذف ${employee.name}",
        AppTheme.successStrongFor(context),
      );
      _loadData();
    } else {
      _showSnackBar(
        "فشل الحذف، تحقق من الاتصال",
        AppTheme.dangerStrongFor(context),
      );
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
    // ⭐ فحص الصلاحية (canViewEmployees أو canViewOwnHRData)
    final ps = PermissionsService();
    if (!ps.canViewEmployees && !ps.canViewOwnHRData) {
      return _buildNoPermissionScreen();
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "إدارة الموظفين",
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
          // Refresh
          IconButton(
            icon: Icon(
              Icons.refresh_rounded,
              color: AppTheme.textMainFor(context),
            ),
            onPressed: _isLoading ? null : _loadData,
            tooltip: 'تحديث',
          ),
          // Add
          if (PermissionsService().canManageEmployees)
            IconButton(
              icon: Icon(
                Icons.person_add_rounded,
                color: AppTheme.accentFor(context),
              ),
              onPressed: _isLoading ? null : () => _openForm(),
              tooltip: 'إضافة موظف',
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
              : _buildContent(),
        ),
      ),
    );
  }


  Widget _buildContent() {
    return Column(
      children: [
        // Search
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 15, 15, 8),
          child: _buildSearchBar(),
        ),

        // Filters
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: _buildFiltersRow(),
        ),

        // Stats
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 12, 15, 8),
          child: _buildStatsBar(),
        ),

        // List
        Expanded(
          child: _filteredEmployees.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadData,
                  color: AppTheme.accentFor(context),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(15, 8, 15, 15),
                    itemCount: _filteredEmployees.length,
                    itemBuilder: (context, index) =>
                        _buildEmployeeCard(_filteredEmployees[index]),
                  ),
                ),
        ),
      ],
    );
  }


  // ============================================================
  // Search bar
  // ============================================================

  Widget _buildSearchBar() {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        style: TextStyle(
          color: AppTheme.textMainFor(context),
          fontFamily: 'Cairo',
          fontSize: 14,
        ),
        decoration: InputDecoration(
          hintText: 'بحث بالاسم، الكود، الهاتف، الإيميل...',
          hintStyle: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            fontSize: 13,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            color: AppTheme.accentFor(context),
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.clear_rounded,
                    color: AppTheme.textMutedFor(context),
                    size: 18,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }


  // ============================================================
  // Filters row
  // ============================================================

  Widget _buildFiltersRow() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildDropdownChip<String?>(
          icon: Icons.storefront_rounded,
          label: _selectedBranch == null
              ? 'كل الفروع'
              : _branchName(_selectedBranch),
          value: _selectedBranch,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('كل الفروع',
                  style: TextStyle(fontFamily: 'Cairo')),
            ),
            ..._branches.map((b) => DropdownMenuItem<String?>(
                  value: b['code'],
                  child: Text(
                    b['name'] ?? '',
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                )),
          ],
          onChanged: (v) {
            setState(() => _selectedBranch = v);
            _applyFilters();
          },
        ),
        _buildDropdownChip<String?>(
          icon: Icons.filter_alt_rounded,
          label: _selectedStatus == null
              ? 'كل الحالات'
              : _statusLabel(_selectedStatus!),
          value: _selectedStatus,
          items: const [
            DropdownMenuItem<String?>(
              value: null,
              child: Text('كل الحالات',
                  style: TextStyle(fontFamily: 'Cairo')),
            ),
            DropdownMenuItem<String?>(
              value: 'active',
              child: Text('نشط', style: TextStyle(fontFamily: 'Cairo')),
            ),
            DropdownMenuItem<String?>(
              value: 'on_leave',
              child: Text('إجازة', style: TextStyle(fontFamily: 'Cairo')),
            ),
            DropdownMenuItem<String?>(
              value: 'suspended',
              child: Text('موقوف', style: TextStyle(fontFamily: 'Cairo')),
            ),
            DropdownMenuItem<String?>(
              value: 'terminated',
              child: Text('منتهي', style: TextStyle(fontFamily: 'Cairo')),
            ),
          ],
          onChanged: (v) {
            setState(() => _selectedStatus = v);
            _applyFilters();
          },
        ),
        _buildDropdownChip<String>(
          icon: Icons.sort_rounded,
          label: _sortLabel(_sortBy),
          value: _sortBy,
          items: const [
            DropdownMenuItem<String>(
              value: 'code',
              child: Text('الكود', style: TextStyle(fontFamily: 'Cairo')),
            ),
            DropdownMenuItem<String>(
              value: 'name',
              child: Text('الاسم', style: TextStyle(fontFamily: 'Cairo')),
            ),
            DropdownMenuItem<String>(
              value: 'salary',
              child: Text('الراتب (الأعلى)',
                  style: TextStyle(fontFamily: 'Cairo')),
            ),
            DropdownMenuItem<String>(
              value: 'hire_date',
              child: Text('تاريخ التعيين',
                  style: TextStyle(fontFamily: 'Cairo')),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _sortBy = v);
            _applyFilters();
          },
        ),
        if (_searchQuery.isNotEmpty ||
            _selectedBranch != null ||
            _selectedStatus != null)
          InkWell(
            onTap: _clearFilters,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.dangerFor(context).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.dangerFor(context).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.clear_rounded,
                    size: 14,
                    color: AppTheme.dangerFor(context),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'مسح',
                    style: TextStyle(
                      color: AppTheme.dangerFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }


  Widget _buildDropdownChip<T>({
    required IconData icon,
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          isDense: true,
          icon: Icon(
            Icons.expand_more_rounded,
            size: 16,
            color: AppTheme.textMutedFor(context),
          ),
          dropdownColor: AppTheme.dropdownBackground(context),
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontSize: 12,
          ),
          selectedItemBuilder: (ctx) => items
              .map((_) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon,
                          size: 14, color: AppTheme.accentFor(context)),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ))
              .toList(),
        ),
      ),
    );
  }


  // ============================================================
  // Stats bar
  // ============================================================

  Widget _buildStatsBar() {
    final total = _allEmployees.length;
    final showing = _filteredEmployees.length;
    final active =
        _filteredEmployees.where((e) => e.status == 'active').length;

    return Row(
      children: [
        Icon(
          Icons.people_rounded,
          size: 16,
          color: AppTheme.infoFor(context),
        ),
        const SizedBox(width: 6),
        Text(
          showing == total
              ? 'إجمالي: $total موظف'
              : 'عرض $showing من $total',
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.successFor(context).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'نشط: $active',
            style: TextStyle(
              color: AppTheme.successFor(context),
              fontFamily: 'Cairo',
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }


  // ============================================================
  // Employee card
  // ============================================================

  Widget _buildEmployeeCard(EmployeeModel employee) {
    final canManage = PermissionsService().canManageEmployees;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: Avatar + name/code + status
            Row(
              children: [
                // Avatar
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.accentFor(context).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    employee.name.isNotEmpty
                        ? employee.name[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      color: AppTheme.accentFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Name + Code
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              employee.name,
                              style: TextStyle(
                                color: AppTheme.textMainFor(context),
                                fontFamily: 'Cairo',
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '(${employee.code})',
                            style: TextStyle(
                              color: AppTheme.textMutedFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      if (employee.jobTitle.isNotEmpty)
                        Text(
                          employee.jobTitle,
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),

                // Status badge
                _buildStatusBadge(employee.status),
              ],
            ),

            // Row 2: Branch + Phone + Email
            if (employee.branchCode.isNotEmpty ||
                employee.phone.isNotEmpty ||
                employee.email.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  if (employee.branchCode.isNotEmpty)
                    _buildInfoChip(
                      Icons.storefront_rounded,
                      _branchName(employee.branchCode),
                      AppTheme.infoFor(context),
                    ),
                  if (employee.phone.isNotEmpty)
                    _buildInfoChip(
                      Icons.phone_rounded,
                      employee.phone,
                      AppTheme.successFor(context),
                    ),
                  if (employee.email.isNotEmpty)
                    _buildInfoChip(
                      Icons.email_rounded,
                      employee.email,
                      AppTheme.warningFor(context),
                    ),
                ],
              ),
            ],

            // Row 3: Actions
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildActionButton(
                    icon: Icons.visibility_rounded,
                    label: 'عرض',
                    color: AppTheme.infoFor(context),
                    onTap: () => _openProfile(employee),
                  ),
                ),
                if (canManage) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildActionButton(
                      icon: Icons.edit_rounded,
                      label: 'تعديل',
                      color: AppTheme.accentFor(context),
                      onTap: () => _openForm(employee: employee),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildActionButton(
                      icon: Icons.delete_outline_rounded,
                      label: 'حذف',
                      color: AppTheme.dangerFor(context),
                      onTap: () => _confirmDelete(employee),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildInfoChip(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            fontSize: 11,
          ),
        ),
      ],
    );
  }


  Widget _buildStatusBadge(String status) {
    final color = _statusColor(status);
    final label = _statusLabel(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontFamily: 'Cairo',
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }


  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontFamily: 'Cairo',
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }


  // ============================================================
  // Empty state
  // ============================================================

    Widget _buildEmptyState() {
    final hasFilter = _searchQuery.isNotEmpty ||
        _selectedBranch != null ||
        _selectedStatus != null;

    final ps = PermissionsService();
    final onlySelfMode = !ps.canViewEmployees && ps.canViewOwnHRData;

    String emptyTitle;
    String emptySubtitle;

    if (hasFilter) {
      emptyTitle = 'لا توجد نتائج مطابقة';
      emptySubtitle = 'جرّب تعديل البحث أو مسح الفلاتر';
    } else if (onlySelfMode) {
      emptyTitle = 'لم يتم ربط حسابك بموظف';
      emptySubtitle =
          'اطلب من المسؤول ربط حسابك (user_email) بملفك الوظيفي';
    } else if (ps.canManageEmployees) {
      emptyTitle = 'لا يوجد موظفون مسجلون';
      emptySubtitle = 'اضغط زر الإضافة لبدء تسجيل موظفين';
    } else {
      emptyTitle = 'لا يوجد موظفون مسجلون';
      emptySubtitle = 'اطلب من المسؤول إضافة موظفين';
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasFilter
                ? Icons.search_off_rounded
                : (onlySelfMode
                    ? Icons.link_off_rounded
                    : Icons.people_outline_rounded),
            size: 72,
            color: AppTheme.textMutedFor(context),
          ),
          const SizedBox(height: 12),
          Text(
            emptyTitle,
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            emptySubtitle,
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
          if (hasFilter) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _clearFilters,
              icon: Icon(
                Icons.clear_rounded,
                size: 16,
                color: AppTheme.accentFor(context),
              ),
              label: Text(
                'مسح الفلاتر',
                style: TextStyle(
                  color: AppTheme.accentFor(context),
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }


  // ============================================================
  // No permission screen
  // ============================================================

  Widget _buildNoPermissionScreen() {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "إدارة الموظفين",
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
                  'ليس لديك صلاحية عرض الموظفين',
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


  // ============================================================
  // Helpers
  // ============================================================

  String _branchName(String? code) {
    if (code == null || code.isEmpty) return 'بدون فرع';
    for (final b in _branches) {
      if (b['code'] == code) return b['name'] ?? code;
    }
    return code;
  }


  String _statusLabel(String status) {
    switch (status) {
      case 'active':
        return 'نشط';
      case 'on_leave':
        return 'إجازة';
      case 'suspended':
        return 'موقوف';
      case 'terminated':
        return 'منتهي';
      default:
        return status;
    }
  }


  Color _statusColor(String status) {
    switch (status) {
      case 'active':
        return AppTheme.successFor(context);
      case 'on_leave':
        return AppTheme.warningFor(context);
      case 'suspended':
        return AppTheme.dangerFor(context);
      case 'terminated':
        return AppTheme.textMutedFor(context);
      default:
        return AppTheme.textMutedFor(context);
    }
  }


  String _sortLabel(String sort) {
    switch (sort) {
      case 'name':
        return 'الاسم';
      case 'salary':
        return 'الراتب';
      case 'hire_date':
        return 'تاريخ التعيين';
      case 'code':
      default:
        return 'الكود';
    }
  }
}

// ============================================================
// نهاية ملف employees_list_page.dart
//
// الصفحة دي بتستورد:
// - employee_form_page.dart (هيتم إنشاؤه في الرسالة 3)
// - employee_profile_page.dart (هيتم إنشاؤه في الرسالة 4)
//
// ⚠️ لحد ما الملفات دي تتعمل، flutter analyze هيظهر أخطاء import
// ده متوقع — هيختفي بعد الرسالتين
// ============================================================