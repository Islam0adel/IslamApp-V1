// lib/pages/hr/hr_dashboard_page.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/permissions_service.dart';  // ⭐ جديد
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

  @override
  State<HRDashboardPage> createState() => _HRDashboardPageState();
}


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

  int _totalEmployees = 0;
  int _presentToday = 0;
  int _absentToday = 0;
  int _lateToday = 0;
  int _vacationToday = 0;


  // ============================================================
  // Lifecycle
  // ============================================================

  @override
  void initState() {
    super.initState();
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

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      _companyCode = prefs.getString('company_code') ?? '';

      if (_companyCode.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      // 1) الموظفين
      final employees = await _employeeService.getEmployeesList(
        companyCode: _companyCode,
      );

      // 2) حضور اليوم
      final today = _todayStr();
      final todayAttendance = await _hrService.getAttendanceForDate(
        companyCode: _companyCode,
        date: today,
      );

      // 3) الإحصائيات
      if (!mounted) return;

      setState(() {
        _totalEmployees = employees.length;

        _presentToday = todayAttendance
            .where((a) => a.status == 'present' || a.status == 'late')
            .length;

        _absentToday = todayAttendance
            .where((a) => a.status == 'absent')
            .length;

        _lateToday = todayAttendance
            .where((a) => a.lateMinutes > 0)
            .length;

        _vacationToday = todayAttendance
            .where((a) => a.status == 'vacation')
            .length;

        _isLoading = false;
      });
    } catch (e) {
      print("❌ خطأ في تحميل الإحصائيات: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // ============================================================
  // Helper — تاريخ اليوم
  // ============================================================

  String _todayStr() => HRConstants.dateToStr(DateTime.now());


  // ============================================================
  // BUILD
  // ============================================================

    @override
  Widget build(BuildContext context) {
    // ⭐ فحص صلاحية فتح HR Dashboard
    if (!PermissionsService().canShowHR) {
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
                      _buildStatsCard(),
                      const SizedBox(height: 20),
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
              _buildStatCard(
                'إجمالي الموظفين',
                '$_totalEmployees',
                Icons.people_rounded,
                AppTheme.infoSoftFor(context),
              ),
              _buildStatCard(
                'حاضر',
                '$_presentToday',
                Icons.check_circle_rounded,
                AppTheme.successFor(context),
              ),
              _buildStatCard(
                'غائب',
                '$_absentToday',
                Icons.cancel_rounded,
                AppTheme.dangerFor(context),
              ),
              _buildStatCard(
                'متأخر',
                '$_lateToday',
                Icons.timer_rounded,
                AppTheme.warningOrangeSoftFor(context),
              ),
              _buildStatCard(
                'إجازة',
                '$_vacationToday',
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
    if (ps.canViewEmployees || ps.canViewOwnHRData) {
      addCard(
        _buildMenuCard(
          title: ps.canViewEmployees ? 'إدارة الموظفين' : 'ملفي الشخصي',
          subtitle: ps.canViewEmployees
              ? 'عرض / إضافة / تعديل بيانات الموظفين'
              : 'عرض بياناتي الشخصية',
          icon: Icons.badge_rounded,
          color: AppTheme.infoFor(context),
          onTap: () => _openPage(const EmployeesListPage()),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 2) بطاقة الحضور
    // ─────────────────────────────────────────
    if (ps.canOpenAttendancePage) {
      addCard(
        _buildMenuCard(
          title: 'الحضور والانصراف',
          subtitle: 'تسجيل حضور الموظفين اليومي',
          icon: Icons.fingerprint_rounded,
          color: AppTheme.successFor(context),
          onTap: () => _openPage(const AttendancePage()),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 3) بطاقة الإجازات
    // ─────────────────────────────────────────
    if (ps.canOpenVacationsPage) {
      addCard(
        _buildMenuCard(
          title: 'الإجازات والإعدادات',
          subtitle: 'إجازات + سلف + مواعيد + خصومات تأخير',
          icon: Icons.beach_access_rounded,
          color: AppTheme.extraTealFor(context),
          onTap: () => _openPage(const VacationsPage()),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 4) بطاقة التقارير
    // ─────────────────────────────────────────
    if (ps.canOpenReportPage) {
      addCard(
        _buildMenuCard(
          title: 'تقرير الراتب الشهري',
          subtitle: 'حساب الراتب + PDF',
          icon: Icons.receipt_long_rounded,
          color: AppTheme.extraPurpleFor(context),
          onTap: () => _openPage(const HRReportPage()),
        ),
      );
    }

    // ─────────────────────────────────────────
    // 5) بطاقة إجمالي الرواتب ⭐ جديد
    // ─────────────────────────────────────────
    if (ps.canViewBranchSalaryReport) {
      addCard(
        _buildMenuCard(
          title: 'إجمالي الرواتب',
          subtitle: 'تقرير مجمع لكل فرع / الشركة',
          icon: Icons.summarize_rounded,
          color: AppTheme.extraBlueGreyFor(context),
          onTap: () => _openPage(const BranchSalariesPage()),
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

  Widget _buildMenuCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: GlassCard(
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
      ),
    );
  }


  // ============================================================
  // فتح صفحة + تحديث الإحصائيات بعد الرجوع
  // ============================================================

  Future<void> _openPage(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );

    // لما يرجع من الصفحة → نعيد تحميل الإحصائيات
    // (عشان لو المستخدم سجل حضور/غاب، الأرقام تتحدث)
    _loadStats();
  }
    // ⭐ شاشة "لا صلاحية"
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