// lib/pages/hr/employees/employee_profile_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../models/employee_model.dart';
import '../../../models/hr_models.dart';
import '../../../core/theme.dart';
import '../../../core/hr_constants.dart';
import '../../../views/widgets/glass_card.dart';
import '../../../services/employee_service.dart';
import '../../../services/hr_service.dart';
import '../../../services/permissions_service.dart';
import '../../hr/vacations_page.dart';
import 'employee_form_page.dart';


/// صفحة بروفايل الموظف الشامل
///
/// 5 تبويبات:
///   1. البيانات — كل حقول Employee
///   2. الحضور — ملخص + قائمة الشهر
///   3. الإجازات — إجازاته + الأسبوعية
///   4. السلف — مكافآت + سلف + إجماليات
///   5. الإعدادات — مواعيد + delay_rules
///
/// تستخدم endpoint واحد: /employees/profile/{company}/{code}
class EmployeeProfilePage extends StatefulWidget {
  final String companyCode;
  final String employeeCode;

  const EmployeeProfilePage({
    super.key,
    required this.companyCode,
    required this.employeeCode,
  });

  @override
  State<EmployeeProfilePage> createState() => _EmployeeProfilePageState();
}


class _EmployeeProfilePageState extends State<EmployeeProfilePage>
    with TickerProviderStateMixin {
  // ============================================================
  // Services
  // ============================================================

  final EmployeeService _employeeService = EmployeeService();
  final HRService _hrService = HRService();


  // ============================================================
  // State (Models بدل Map)
  // ============================================================

  bool _isLoading = true;
  String? _error;

  EmployeeModel? _employeeModel;
  Map<String, HRAttendanceModel>? _attendanceMap;
  List<HRVacationModel>? _vacationsList;
  List<HRAdjustmentModel>? _adjustmentsList;
  HREmployeeSettingsModel? _settingsModel;

  String _selectedMonth = '';
  late TabController _tabController;

  StreamSubscription? _hiveSubscription;


  // ============================================================
  // Lifecycle
  // ============================================================

    @override
  void initState() {
    super.initState();
    _selectedMonth = _currentMonth();
    _tabController = TabController(length: 5, vsync: this);

    // ⭐ WebSocket auto-update: راقب تغييرات Hive
    _hiveSubscription = Hive.box('coding_box')
        .watch()
        .listen((event) {
      // تحديث فقط لو التغيير متعلق بهذا الموظف أو HR
      if (!mounted || _isLoading) return;
      final key = event.key?.toString() ?? '';
      if (key.contains('hr_') ||
          key.contains('employees') ||
          key.contains(widget.employeeCode)) {
        _loadProfile(showLoader: false);
      }
    });

    _loadProfile();
  }

    @override
  void dispose() {
    _hiveSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }


  String _currentMonth() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }


  // ============================================================
  // Load profile
  // ============================================================

    Future<void> _loadProfile({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      // 1) الموظف (Hive أولاً)
      final employees = await _employeeService.getEmployeesList(
        companyCode: widget.companyCode,
      );

      EmployeeModel? employee;
      for (final e in employees) {
        if (e.code == widget.employeeCode) {
          employee = e;
          break;
        }
      }

      if (employee == null) {
        setState(() {
          _isLoading = false;
          _error = 'الموظف غير موجود';
        });
        return;
      }

      // 2) الحضور (Hive أولاً + server fallback)
      final attendanceMap = await _hrService.getEmployeeMonthAttendance(
        companyCode: widget.companyCode,
        employeeCode: widget.employeeCode,
        month: _selectedMonth,
      );

      // 3) الإجازات (Hive أولاً)
      final vacations = await _hrService.getVacations(
        companyCode: widget.companyCode,
        branchCode: employee.branchCode,
        employeeCode: widget.employeeCode,
      );

      // 4) التسويات (Hive أولاً)
      final adjustments = await _hrService.getEmployeeAdjustments(
        companyCode: widget.companyCode,
        employeeCode: widget.employeeCode,
        month: _selectedMonth,
      );

      // 5) الإعدادات (Hive أولاً)
      final settings = await _hrService.getEmployeeSettings(
        companyCode: widget.companyCode,
        employeeCode: widget.employeeCode,
      );

      if (!mounted) return;

      setState(() {
        _employeeModel = employee;
        _attendanceMap = attendanceMap;
        _vacationsList = vacations;
        _adjustmentsList = adjustments;
        _settingsModel = settings;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'خطأ: $e';
      });
    }
  }


    Future<void> _pickMonth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'اختر الشهر',
    );

    if (picked != null) {
      setState(() {
        _selectedMonth =
            '${picked.year}-${picked.month.toString().padLeft(2, '0')}';
      });
      _loadProfile();
    }
  }



    Future<void> _openEditForm() async {
    if (_employeeModel == null) return;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EmployeeFormPage(
          companyCode: widget.companyCode,
          employee: _employeeModel,
        ),
      ),
    );

    if (result == true) _loadProfile();
  }
  


  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // فحص الصلاحية
    if (!PermissionsService().canViewEmployees) {
      return _buildNoPermissionScreen();
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          _employeeModel?.name ?? 'الموظف',
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
            onPressed: _isLoading ? null : () => _loadProfile(),
            tooltip: 'تحديث',
          ),
          if (PermissionsService().canManageEmployees && _employeeModel != null)
            IconButton(
              icon: Icon(
                Icons.edit_rounded,
                color: AppTheme.accentFor(context),
              ),
              onPressed: _openEditForm,
              tooltip: 'تعديل',
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
              : _error != null
                  ? _buildErrorState()
                  : _buildContent(),
        ),
      ),
    );
  }


  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 64,
            color: AppTheme.dangerFor(context),
          ),
          const SizedBox(height: 12),
          Text(
            _error ?? 'حدث خطأ',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadProfile,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('إعادة المحاولة',
                style: TextStyle(fontFamily: 'Cairo')),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentFor(context),
              foregroundColor: AppTheme.onAccentFor(context),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildContent() {
    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(15),
          child: _buildProfileHeader(),
        ),

        // Stats
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: _buildStatsCard(),
        ),

        const SizedBox(height: 15),

        // TabBar
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
            tabs: const [
              Tab(text: 'البيانات'),
              Tab(text: 'الحضور'),
              Tab(text: 'الإجازات'),
              Tab(text: 'السلف'),
              Tab(text: 'الإعدادات'),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // TabBarView
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildBasicTab(),
              _buildAttendanceTab(),
              _buildVacationsTab(),
              _buildAdjustmentsTab(),
              _buildSettingsTab(),
            ],
          ),
        ),
      ],
    );
  }


  // ============================================================
  // Header
  // ============================================================

  Widget _buildProfileHeader() {
    final emp = _employeeModel;
    final name = emp?.name ?? '—';
    final code = emp?.code ?? '—';
    final jobTitle = emp?.jobTitle ?? '';
    final status = emp?.status.isNotEmpty == true ? emp!.status : 'active';
    final phone = emp?.phone ?? '';
    final email = emp?.email ?? '';

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 64,
            height: 64,
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
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '($code)',
                      style: TextStyle(
                        color: AppTheme.textMutedFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                if (jobTitle.isNotEmpty)
                  Text(
                    jobTitle,
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 13,
                    ),
                  ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _buildStatusBadge(status),
                    if (phone.isNotEmpty)
                      _buildSmallChip(Icons.phone_rounded, phone),
                    if (email.isNotEmpty)
                      _buildSmallChip(Icons.email_rounded, email),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildStatusBadge(String status) {
    final color = _statusColor(status);
    final label = _statusLabel(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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


  Widget _buildSmallChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: AppTheme.textMutedFor(context)),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            fontSize: 10,
          ),
        ),
      ],
    );
  }


  // ============================================================
  // Stats card
  // ============================================================

    Widget _buildStatsCard() {
    final att = _attendanceMap ?? {};

    int present = 0;
    int absent = 0;
    int vacation = 0;
    int lateMin = 0;
    int overtimeMin = 0;

    for (final a in att.values) {
      if (a.status == 'present' || a.status == 'late') present++;
      if (a.status == 'absent') absent++;
      if (a.status == 'vacation') vacation++;
      lateMin += a.lateMinutes;
      overtimeMin += a.overtimeMinutes;
    }

    return GlassCard(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Expanded(child: _buildStatChip('حاضر', '$present', AppTheme.successFor(context))),
          const SizedBox(width: 4),
          Expanded(child: _buildStatChip('غائب', '$absent', AppTheme.dangerFor(context))),
          const SizedBox(width: 4),
          Expanded(child: _buildStatChip('إجازة', '$vacation', AppTheme.extraTealFor(context))),
          const SizedBox(width: 4),
          Expanded(child: _buildStatChip('تأخير', '${lateMin}د', AppTheme.warningOrangeSoftFor(context))),
          const SizedBox(width: 4),
          Expanded(child: _buildStatChip('إضافي', '${overtimeMin}د', AppTheme.accentFor(context))),
        ],
      ),
    );
  }


  Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
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
              fontSize: 14,
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
  // Tab 1: Basic data
  // ============================================================

    Widget _buildBasicTab() {
    final emp = _employeeModel;
    if (emp == null) {
      return const Center(child: Text('لا توجد بيانات'));
    }

    return ListView(
      padding: const EdgeInsets.all(15),
      children: [
        _buildInfoSection(
          icon: Icons.person_rounded,
          title: 'البيانات الأساسية',
          color: AppTheme.successFor(context),
          items: [
            _row('الكود', emp.code),
            _row('الاسم', emp.name),
            _row('الهاتف', emp.phone),
            _row('الإيميل', emp.email),
          ],
        ),
        const SizedBox(height: 12),
        _buildInfoSection(
          icon: Icons.contact_page_rounded,
          title: 'البيانات الشخصية',
          color: AppTheme.infoFor(context),
          items: [
            _row('الرقم القومي', emp.nationalId),
            _row('الجنس', _genderLabel(emp.gender)),
            _row('تاريخ الميلاد', _formatDate(emp.birthDate)),
            _row('العنوان', emp.address),
          ],
        ),
        const SizedBox(height: 12),
        _buildInfoSection(
          icon: Icons.work_rounded,
          title: 'البيانات الوظيفية',
          color: AppTheme.warningFor(context),
          items: [
            _row('المسمى الوظيفي', emp.jobTitle),
            _row('القسم', emp.department),
            _row('الفرع', _branchName(emp.branchCode)),
            // ⭐ الراتب يظهر لو canSeeEmployeeSalary
            if (PermissionsService().canSeeEmployeeSalary(widget.employeeCode))
              _row('الراتب',
                  emp.salary > 0
                      ? '${emp.salary.toStringAsFixed(2)} ج.م'
                      : '—'),
            _row('نوع العقد', _contractLabel(emp.contractType)),
            _row('تاريخ التعيين', _formatDate(emp.hireDate)),
            _row('تاريخ الانتهاء', _formatDate(emp.endDate)),
          ],
        ),
        const SizedBox(height: 12),
        _buildInfoSection(
          icon: Icons.link_rounded,
          title: 'ربط Firebase',
          color: AppTheme.extraPurpleFor(context),
          items: [
            _row('User UID', emp.userUid),
            _row('User Email', emp.userEmail),
          ],
        ),
        const SizedBox(height: 12),
        _buildInfoSection(
          icon: Icons.info_rounded,
          title: 'بيانات إضافية',
          color: AppTheme.extraTealFor(context),
          items: [
            _row('جهة اتصال طارئ', emp.emergencyContact),
            _row('اسم البنك', emp.bankName),
            _row('رقم الحساب', emp.bankAccount),
            _row('ملاحظات', emp.notes),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }


  Widget _buildInfoSection({
    required IconData icon,
    required String title,
    required Color color,
    required List<Widget> items,
  }) {
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const SizedBox(width: 8),
              Text(
                title,
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
          ...items,
        ],
      ),
    );
  }


  Widget _row(String label, dynamic value) {
    final str = value?.toString() ?? '';
    final display = str.isEmpty ? '—' : str;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              display,
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
    );
  }


  // ============================================================
  // Tab 2: Attendance
  // ============================================================

    Widget _buildAttendanceTab() {
    final att = _attendanceMap ?? {};
    final records = att.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    return ListView(
      padding: const EdgeInsets.all(15),
      children: [
        // Month picker
        GlassCard(
          padding: const EdgeInsets.all(12),
          child: InkWell(
            onTap: _pickMonth,
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_month_rounded,
                  color: AppTheme.warningFor(context),
                  size: 20,
                ),
                const SizedBox(width: 10),
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
                  size: 14,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Records
        if (records.isEmpty)
          _buildEmptyCard('لا توجد سجلات حضور لهذا الشهر')
        else
          GlassCard(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'السجلات (${records.length})',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...records.map(_buildAttendanceRow),
              ],
            ),
          ),
      ],
    );
  }


    Widget _buildAttendanceRow(HRAttendanceModel record) {
    final date = record.date;
    final status = record.status;
    final checkIn = record.checkIn;
    final checkOut = record.checkOut;
    final late = record.lateMinutes;
    final overtime = record.overtimeMinutes;

    final color = _attendanceStatusColor(status);
    final label = _attendanceStatusLabel(status);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Text(
              date,
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontFamily: 'Cairo',
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              checkIn.isNotEmpty && checkOut.isNotEmpty
                  ? '$checkIn → $checkOut'
                  : (checkIn.isNotEmpty ? checkIn : '—'),
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                fontSize: 10,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (late > 0)
            Text(
              '+${late}د',
              style: TextStyle(
                color: AppTheme.warningOrangeSoftFor(context),
                fontFamily: 'Cairo',
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          if (overtime > 0) ...[
            const SizedBox(width: 4),
            Text(
              '+${overtime}د',
              style: TextStyle(
                color: AppTheme.accentFor(context),
                fontFamily: 'Cairo',
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ],
      ),
    );
  }


  // ============================================================
  // Tab 3: Vacations
  // ============================================================

    Widget _buildVacationsTab() {
    final vacations = _vacationsList ?? [];

    return ListView(
      padding: const EdgeInsets.all(15),
      children: [
        // Weekly vacation from settings
        if (_settingsModel != null)
          GlassCard(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  Icons.weekend_rounded,
                  color: AppTheme.extraTealFor(context),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'الإجازة الأسبوعية',
                        style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        _weeklyDayLabel(_settingsModel!.weeklyVacationDay),
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
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
          ),
        const SizedBox(height: 12),

        // Vacations list
        if (vacations.isEmpty)
          _buildEmptyCard('لا توجد إجازات مسجلة')
        else
          GlassCard(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'الإجازات (${vacations.length})',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...vacations.map(_buildVacationRow),
              ],
            ),
          ),

        const SizedBox(height: 12),

        // Manage button
        if (PermissionsService().canOpenVacationsPage)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const VacationsPage()),
              ),
              icon: Icon(
                Icons.settings_rounded,
                color: AppTheme.accentFor(context),
                size: 18,
              ),
              label: Text(
                'إدارة الإجازات والإعدادات',
                style: TextStyle(
                  color: AppTheme.accentFor(context),
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.accentFor(context)),
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


    Widget _buildVacationRow(HRVacationModel v) {
    final date = v.date;
    final name = v.name;
    final isWeekly = v.type == 'weekly';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            isWeekly ? Icons.weekend_rounded : Icons.celebration_rounded,
            color: AppTheme.extraTealFor(context),
            size: 14,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(
              date,
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }


  // ============================================================
  // Tab 4: Adjustments
  // ============================================================

    Widget _buildAdjustmentsTab() {
    final records = _adjustmentsList ?? [];

    double bonuses = 0;
    double deductions = 0;
    double loans = 0;

    for (final a in records) {
      if (a.type == 'bonus') bonuses += a.amount;
      if (a.type == 'deduction') deductions += a.amount;
      if (a.type == 'loan') loans += a.amount;
    }

    // ⭐ الراتب يظهر لو canSeeEmployeeSalary (يدعم الموظف نفسه)
    final canSeeAmounts =
        PermissionsService().canSeeEmployeeSalary(widget.employeeCode);

    return ListView(
      padding: const EdgeInsets.all(15),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'إجماليات $_selectedMonth',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildSummaryTile(
                      'مكافآت',
                      canSeeAmounts
                          ? '${_formatAmount(bonuses)} ج.م'
                          : '—',
                      AppTheme.successFor(context),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _buildSummaryTile(
                      'خصومات',
                      canSeeAmounts
                          ? '${_formatAmount(deductions)} ج.م'
                          : '—',
                      AppTheme.dangerFor(context),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _buildSummaryTile(
                      'سلف',
                      canSeeAmounts
                          ? '${_formatAmount(loans)} ج.م'
                          : '—',
                      AppTheme.warningOrangeSoftFor(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (records.isEmpty)
          _buildEmptyCard('لا توجد مكافآت أو سلف لهذا الشهر')
        else
          GlassCard(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'البنود (${records.length})',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...records.map((r) => _buildAdjustmentRow(r, canSeeAmounts)),
              ],
            ),
          ),
      ],
    );
  }


  Widget _buildSummaryTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              fontSize: 9,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
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


    Widget _buildAdjustmentRow(HRAdjustmentModel adj, bool canSeeAmounts) {
    final type = adj.type;
    final reason = adj.reason;
    final amount = adj.amount;
    final installmentRef = adj.installmentRef;

    final color = type == 'bonus'
        ? AppTheme.successFor(context)
        : (type == 'deduction'
            ? AppTheme.dangerFor(context)
            : AppTheme.warningOrangeSoftFor(context));
    final icon = type == 'bonus'
        ? Icons.add_circle_rounded
        : (type == 'deduction'
            ? Icons.remove_circle_rounded
            : Icons.request_quote_rounded);
    final typeLabel = type == 'bonus'
        ? 'مكافأة'
        : (type == 'deduction' ? 'خصم' : 'سلفة');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  typeLabel,
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (reason.isNotEmpty)
                  Text(
                    reason,
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 10,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (installmentRef.isNotEmpty)
                  Text(
                    'قسط $installmentRef',
                    style: TextStyle(
                      color: AppTheme.infoFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 9,
                    ),
                  ),
              ],
            ),
          ),
          if (canSeeAmounts)
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
  // Tab 5: Settings
  // ============================================================

    Widget _buildSettingsTab() {
    final settings = _settingsModel;
    if (settings == null) {
      return const Center(child: Text('لا توجد إعدادات'));
    }

    return ListView(
      padding: const EdgeInsets.all(15),
      children: [
        _buildInfoSection(
          icon: Icons.schedule_rounded,
          title: 'مواعيد العمل',
          color: AppTheme.accentFor(context),
          items: [
            _row('وقت الحضور', settings.defaultCheckIn),
            _row('وقت الانصراف', settings.defaultCheckOut),
            _row('مرونة المواعيد',
                settings.flexibleHours ? 'نعم' : 'لا'),
            _row('الشهر 30 يوم',
                settings.useFixedMonthDays ? 'نعم' : 'لا'),
          ],
        ),
        const SizedBox(height: 12),
        _buildInfoSection(
          icon: Icons.weekend_rounded,
          title: 'الإجازة الأسبوعية',
          color: AppTheme.extraTealFor(context),
          items: [
            _row('اليوم', _weeklyDayLabel(settings.weeklyVacationDay)),
          ],
        ),
        const SizedBox(height: 12),
        _buildDelayRulesCard(),
        const SizedBox(height: 20),
        if (PermissionsService().canOpenVacationsPage)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const VacationsPage()),
              ),
              icon: Icon(
                Icons.settings_rounded,
                color: AppTheme.accentFor(context),
                size: 18,
              ),
              label: Text(
                'تعديل الإعدادات',
                style: TextStyle(
                  color: AppTheme.accentFor(context),
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.accentFor(context)),
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


    Widget _buildDelayRulesCard() {
    final rules = _settingsModel?.delayRules ?? {};

    if (rules.isEmpty) {
      return _buildEmptyCard('لا توجد قواعد تأخير مخصصة (يستخدم الافتراضي)');
    }

    final entries = rules.entries.toList();

    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: AppTheme.warningOrangeSoftFor(context).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.timer_rounded,
                  color: AppTheme.warningOrangeSoftFor(context),
                  size: 16,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'قواعد التأخير',
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
          ...entries.map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        HRConstants.delayRuleLabels[e.key] ?? e.key,
                        style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Text(
                      '${e.value} يوم',
                      style: TextStyle(
                        color: AppTheme.warningOrangeSoftFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }


  // ============================================================
  // Helpers
  // ============================================================

  Widget _buildEmptyCard(String message) {
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            fontSize: 12,
          ),
        ),
      ),
    );
  }


  String _genderLabel(String? g) {
    if (g == 'male') return 'ذكر';
    if (g == 'female') return 'أنثى';
    return '';
  }


  String _contractLabel(String? c) {
    switch (c) {
      case 'permanent':
        return 'دائم';
      case 'temporary':
        return 'مؤقت';
      case 'part-time':
        return 'دوام جزئي';
      default:
        return '';
    }
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


  String _attendanceStatusLabel(String status) {
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
      default:
        return status;
    }
  }


  Color _attendanceStatusColor(String status) {
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
      default:
        return AppTheme.textMutedFor(context);
    }
  }


  String _branchName(String? code) {
    if (code == null || code.isEmpty) return '';

    final box = Hive.box('coding_box');
    final raw = box.get('${widget.companyCode}_branches');

    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        if (item['code']?.toString() == code) {
          return item['name']?.toString() ?? code;
        }
      }
    }
    return code;
  }


  String _weeklyDayLabel(dynamic value) {
    if (value == null) return 'لا يوجد';
    final n = int.tryParse(value.toString());
    if (n == null || n < 0 || n > 6) return 'لا يوجد';
    return HRConstants.weekdayNamesAr[n];
  }


  String _formatDate(dynamic value) {
    if (value == null) return '';
    final s = value.toString();
    if (s.isEmpty) return '';
    try {
      final dt = DateTime.parse(s);
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return s;
    }
  }


  String _formatAmount(dynamic value) {
    if (value == null) return '0.00';
    final n = value is num ? value.toDouble() : double.tryParse(value.toString()) ?? 0.0;
    return n.toStringAsFixed(2);
  }


  Widget _buildNoPermissionScreen() {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "الموظف",
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
}

