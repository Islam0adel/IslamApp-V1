// frontend/lib/pages/hr/hr_dashboard_page.dart
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/sync_read_access.dart';
import '../../services/read_authorization_snapshot.dart';
import '../../views/widgets/visibility_page_shell.dart';
import '../../services/cache_partitions.dart';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/permissions_service.dart'; // ⭐ جديد
import '../../core/theme.dart';
import '../../core/hr_constants.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/employee_service.dart';
import '../../services/hr_service.dart';
import 'attendance_page.dart';
import 'vacations_page.dart';
import 'report_page.dart';
import 'employees/employees_list_page.dart';
import 'branch_salaries_page.dart';

// لوحة تحكم الموارد البشرية
/// لوحة تحكم الموارد البشرية
///
/// - إحصائيات اليوم (حاضر / غائب / متأخر / إجازة)
/// - 3 أزرار تنقّل: الحضور / الإجازات / التقرير
///
/// ⭐ النسخة الجديدة:
/// - HRService (بدل HRAttendanceService)
/// - نفس التصميم 100%
class HRDashboardPage extends StatefulWidget {
  const HRDashboardPage({super.key});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<HRDashboardPage> createState() => _HRDashboardPageState();
}

// حالة الويدجت HRDashboardPage: تدير بيانات الشاشة وتفاعلاتها
class _HRDashboardPageState extends State<HRDashboardPage> {
  // ============================================================
  // Services
  // ============================================================

  final EmployeeService _employeeService = EmployeeService();
  final HRService _hrService = HRService();

  // ============================================================
  // State
  // ============================================================

  bool _isLoading = true;
  String _companyCode = '';

  bool _employeesLoaded = false;
  bool _attendanceLoaded = false;
  int _totalEmployees = 0;
  int _presentToday = 0;
  int _absentToday = 0;
  int _lateToday = 0;
  int _vacationToday = 0;

  // ============================================================
  // Lifecycle
  // ============================================================

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    _statsOwner = FirebaseAuth.instance.currentUser?.uid;
    _statsScope = _currentStatsScope;
    PermissionsService().addListener(_permissionsChanged);
    ReadAuthorizationEpoch.changes.addListener(_permissionsChanged);
    _loadStats();
  }

  // ============================================================
  // Load stats
  //
  // ⭐ الخطوات:
  // 1. جلب عدد الموظفين
  // 2. جلب حضور اليوم
  // 3. عدّ الحالات (حاضر / غائب / متأخر / إجازة)
  // ============================================================

  String? _statsOwner;

  // يحدد هل مالك الإحصائيات هو المستخدم الحالي
  bool get _sameOwner => _statsOwner == FirebaseAuth.instance.currentUser?.uid;
  int _loadGeneration = 0;
  bool _statsRunning = false;
  bool _statsPending = false;
  SharedPreferences? _statsPreferences;
  String? _statsScope;

  // يعيد نطاق الإحصائيات الحالي
  String get _currentStatsScope {
    final user = FirebaseAuth.instance.currentUser;
    final permissions = PermissionsService();
    return jsonEncode([
      user?.uid,
      user?.email,
      _statsPreferences?.getString('company_code'),
      CachePartitions.generation,
      CachePartitions.isReady,
      ReadAuthorizationEpoch.value,
      permissions.isLoaded,
      permissions.hrCoverageScope,
      permissions.currentEmployeeCode,
      permissions.canShowHR,
      _mayReadEmployees,
      _mayReadAttendance,
    ]);
  }

  // يحدد هل يحق للمستخدم قراءة الموظفين
  bool get _mayReadEmployees =>
      _sameOwner && SyncReadAccess.allows('employees');

  // يحدد هل يحق للمستخدم قراءة الحضور
  bool get _mayReadAttendance =>
      _sameOwner && SyncReadAccess.allows('attendance');

  // يستجيب لتغيّر الصلاحيات
  void _permissionsChanged() {
    if (!mounted) return;
    final next = _currentStatsScope;
    if (next == _statsScope) return;
    _statsScope = next;
    _loadGeneration++;
    setState(() {
      _employeesLoaded = false;
      _attendanceLoaded = false;
      _totalEmployees = 0;
      _presentToday = 0;
      _absentToday = 0;
      _lateToday = 0;
      _vacationToday = 0;
      _isLoading = false;
    });
    if (CachePartitions.isReady) _loadStats();
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    _loadGeneration++;
    PermissionsService().removeListener(_permissionsChanged);
    ReadAuthorizationEpoch.changes.removeListener(_permissionsChanged);
    super.dispose();
  }

  // يحمّل إحصائيات اللوحة
  Future<void> _loadStats() async {
    if (!mounted) return;
    _statsPending = true;
    if (_statsRunning) return;
    _statsRunning = true;
    try {
      // Epoch notifications precede synchronous permission-map replacement.
      // Start after that mutation settles, while hiding stale values immediately.
      await Future<void>.value();
      do {
        _statsPending = false;
        await _readStats();
      } while (mounted && _statsPending && CachePartitions.isReady);
    } finally {
      _statsRunning = false;
    }
  }

  // يقرأ الإحصائيات من التخزين المحلي
  Future<void> _readStats() async {
    return CachePartitions.run(() async {
      final generation = ++_loadGeneration;
      final readEmployees = _mayReadEmployees;
      final readAttendance = _mayReadAttendance;
      if (!readEmployees && !readAttendance) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      setState(() {
        _isLoading = true;
        _employeesLoaded = false;
        _attendanceLoaded = false;
      });

      try {
        final scope = await ReadAuthorizationSnapshot.capture();
        final prefs = await SharedPreferences.getInstance();
        scope.check();
        if (!mounted || generation != _loadGeneration) return;
        _statsPreferences = prefs;
        _companyCode = prefs.getString('company_code') ?? '';
        _statsScope = _currentStatsScope;
        if (_companyCode.isEmpty) {
          setState(() => _isLoading = false);
          return;
        }

        var employeeCount = 0;
        var employeesLoaded = false;
        var attendanceLoaded = false;
        if (readEmployees) {
          try {
            final employees = await _employeeService.getEmployeesList(
                companyCode: _companyCode, throwOnError: true);
            scope.check();
            employeeCount = employees.length;
            employeesLoaded = true;
          } catch (e) {
            scope.check();
            debugPrint('Employee statistics unavailable: $e');
          }
        }
        scope.check();
        if (!mounted || generation != _loadGeneration) return;
        var present = 0, absent = 0, late = 0, vacation = 0;
        if (readAttendance) {
          try {
            final rows = await _hrService.getAttendanceForDate(
                companyCode: _companyCode, date: _todayStr());
            scope.check();
            present = rows
                .where((a) => a.status == 'present' || a.status == 'late')
                .length;
            absent = rows.where((a) => a.status == 'absent').length;
            late = rows.where((a) => a.lateMinutes > 0).length;
            vacation = rows.where((a) => a.status == 'vacation').length;
            attendanceLoaded = true;
          } catch (e) {
            scope.check();
            debugPrint('Attendance statistics unavailable: $e');
          }
        }

        // 3) الإحصائيات
        scope.check();
        if (!mounted || generation != _loadGeneration) return;

        setState(() {
          _employeesLoaded = employeesLoaded;
          _attendanceLoaded = attendanceLoaded;
          _totalEmployees = employeeCount;
          _presentToday = present;
          _absentToday = absent;
          _lateToday = late;
          _vacationToday = vacation;

          _isLoading = false;
        });
      } catch (e) {
        print("❌ خطأ في تحميل الإحصائيات: $e");
        if (mounted && generation == _loadGeneration)
          setState(() => _isLoading = false);
      }
    });
  }

  // ============================================================
  // Helper — تاريخ اليوم
  // ============================================================

  // يبني واجهة العنصر ويعيد شجرة العناصر
  String _todayStr() => HRConstants.dateToStr(DateTime.now());

  // ============================================================
  // BUILD
  // ============================================================

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    // ⭐ فحص صلاحية فتح HR Dashboard
    if (!_sameOwner || !PermissionsService().canShowHR) {
      return _buildNoPermissionScreen();
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "الموارد البشرية",
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
            onPressed: _isLoading ? null : _loadStats,
            tooltip: 'تحديث',
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
                    color: AppTheme.infoFor(context),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    children: [
                      if (_mayReadEmployees || _mayReadAttendance) ...[
                        _buildStatsCard(),
                        const SizedBox(height: 20),
                      ],
                      _buildMenuCards(),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  // ============================================================
  // بطاقة الإحصائيات
  // ============================================================

  // يبني بطاقة الإحصائيات
  Widget _buildStatsCard() {
    return GlassCard(
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.today_rounded,
                color: AppTheme.warningFor(context),
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                'إحصائيات اليوم',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (_mayReadEmployees)
                _buildStatCard(
                  'إجمالي الموظفين',
                  _employeesLoaded ? '$_totalEmployees' : 'غير متاح',
                  Icons.people_rounded,
                  AppTheme.infoSoftFor(context),
                ),
              if (_mayReadAttendance)
                _buildStatCard(
                  'حاضر',
                  _attendanceLoaded ? '$_presentToday' : 'غير متاح',
                  Icons.check_circle_rounded,
                  AppTheme.successFor(context),
                ),
              if (_mayReadAttendance)
                _buildStatCard(
                  'غائب',
                  _attendanceLoaded ? '$_absentToday' : 'غير متاح',
                  Icons.cancel_rounded,
                  AppTheme.dangerFor(context),
                ),
              if (_mayReadAttendance)
                _buildStatCard(
                  'متأخر',
                  _attendanceLoaded ? '$_lateToday' : 'غير متاح',
                  Icons.timer_rounded,
                  AppTheme.warningOrangeSoftFor(context),
                ),
              if (_mayReadAttendance)
                _buildStatCard(
                  'إجازة',
                  _attendanceLoaded ? '$_vacationToday' : 'غير متاح',
                  Icons.beach_access_rounded,
                  AppTheme.extraTealFor(context),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // بطاقة إحصائية صغيرة
  // ============================================================

  // يبني بطاقة إحصائية واحدة
  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 11,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // بطاقات التنقل (3 أقسام)
  // ============================================================

  // يبني بطاقات القوائم حسب الصلاحيات
  Widget _buildMenuCards() {
    final ps = PermissionsService();
    final cards = <Widget>[];

    // ⭐ Helper داخلي: إضافة بطاقة + مسافة قبلها (لو مش أول بطاقة)
    void addCard(Widget card) {
      if (cards.isNotEmpty) cards.add(const SizedBox(height: 12));
      cards.add(card);
    }

    // ─────────────────────────────────────────
    // 1) بطاقة الموظفين
    // ─────────────────────────────────────────
    if (ps.pageVisible('إدارة الموظفين',
        fallback: (ps.canViewEmployees || ps.canViewOwnHRData))) {
      addCard(
        _buildMenuCard(
          title: ps.canViewEmployees ? 'إدارة الموظفين' : 'ملفي الشخصي',
          subtitle: ps.canViewEmployees
              ? 'عرض / إضافة / تعديل بيانات الموظفين'
              : 'عرض بياناتي الشخصية',
          icon: Icons.badge_rounded,
          color: AppTheme.infoFor(context),
          onTap: () => _openPage((ps.canViewEmployees || ps.canViewOwnHRData)
              ? const EmployeesListPage()
              : const VisibilityPageShell(title: 'إدارة الموظفين')),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 2) بطاقة الحضور
    // ─────────────────────────────────────────
    if (ps.pageVisible('الحضور والانصراف',
        fallback: (ps.canOpenAttendancePage))) {
      addCard(
        _buildMenuCard(
          title: 'الحضور والانصراف',
          subtitle: 'تسجيل حضور الموظفين اليومي',
          icon: Icons.fingerprint_rounded,
          color: AppTheme.successFor(context),
          onTap: () => _openPage((ps.canOpenAttendancePage)
              ? const AttendancePage()
              : const VisibilityPageShell(title: 'الحضور والانصراف')),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 3) بطاقة الإجازات
    // ─────────────────────────────────────────
    if (ps.pageVisible('الإجازات والإعدادات',
        fallback: (ps.canOpenVacationsPage))) {
      addCard(
        _buildMenuCard(
          title: 'الإجازات والإعدادات',
          subtitle: 'إجازات + سلف + مواعيد + خصومات تأخير',
          icon: Icons.beach_access_rounded,
          color: AppTheme.extraTealFor(context),
          onTap: () => _openPage((ps.canOpenVacationsPage)
              ? const VacationsPage()
              : const VisibilityPageShell(title: 'الإجازات والإعدادات')),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 4) بطاقة التقارير
    // ─────────────────────────────────────────
    if (ps.pageVisible('تقرير الراتب الشهري',
        fallback: (ps.canOpenReportPage))) {
      addCard(
        _buildMenuCard(
          title: 'تقرير الراتب الشهري',
          subtitle: 'حساب الراتب + PDF',
          icon: Icons.receipt_long_rounded,
          color: AppTheme.extraPurpleFor(context),
          onTap: () => _openPage((ps.canOpenReportPage)
              ? const HRReportPage()
              : const VisibilityPageShell(title: 'تقرير الراتب الشهري')),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 5) بطاقة إجمالي الرواتب ⭐ جديد
    // ─────────────────────────────────────────
    if (ps.pageVisible('إجمالي الرواتب',
        fallback: (ps.canViewBranchSalaryReport))) {
      addCard(
        _buildMenuCard(
          title: 'إجمالي الرواتب',
          subtitle: 'تقرير مجمع لكل فرع / الشركة',
          icon: Icons.summarize_rounded,
          color: AppTheme.extraBlueGreyFor(context),
          onTap: () => _openPage((ps.canViewBranchSalaryReport)
              ? const BranchSalariesPage()
              : const VisibilityPageShell(title: 'إجمالي الرواتب')),
        ),
      );
    }

    // ─────────────────────────────────────────
    // مفيش أي صلاحية
    // ─────────────────────────────────────────
    if (cards.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 64,
              color: AppTheme.textMutedFor(context),
            ),
            const SizedBox(height: 12),
            Text(
              'ليس لديك صلاحية لأي قسم داخل الموارد البشرية',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    // ⭐ لازم يكون فيه return في الآخر
    return Column(children: cards);
  }

  // ============================================================
  // بطاقة تنقل واحدة
  // ============================================================

  // يبني بطاقة قائمة واحدة
  Widget _buildMenuCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              // أيقونة
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 14),

              // النص
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppTheme.textMutedFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              // سهم
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: AppTheme.textMutedFor(context),
                size: 14,
              ),
            ],
          ),
        ),
        onTap: onTap,
        opensPage: true);
  }

  // ============================================================
  // فتح صفحة + تحديث الإحصائيات بعد الرجوع
  // ============================================================

  // يفتح صفحة ويعيد تحميل الإحصائيات عند العودة
  Future<void> _openPage(Widget page) async {
    return CachePartitions.run(() async {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => page),
      );

      // لما يرجع من الصفحة → نعيد تحميل الإحصائيات
      // (عشان لو المستخدم سجل حضور/غاب، الأرقام تتحدث)
      _loadStats();
    });
  }

  // ⭐ شاشة "لا صلاحية"
  // يبني شاشة تعذّر الوصول لعدم توفر الصلاحية
  Widget _buildNoPermissionScreen() {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "الموارد البشرية",
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
                  'ليس لديك صلاحية الوصول للموارد البشرية',
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
// نهاية ملف hr_dashboard_page.dart
//
// الملف بيستخدم:
// - HRService: جلب حضور اليوم
// - EmployeeService: جلب عدد الموظفين
// - HRConstants: dateToStr لليوم الحالي
//
// الفروق عن النسخة القديمة:
// 1. HRService بدل HRAttendanceService (service موحد)
// 2. HRConstants.dateToStr بدل formatting يدوي
// 3. reload الإحصائيات بعد الرجوع من أي صفحة
// ============================================================
