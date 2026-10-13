import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../services/permissions_service.dart';
import '../../views/widgets/glass_card.dart';
import 'reports_page.dart';
import 'advanced_reports_page.dart';

class ReportsDashboardPage extends StatelessWidget {
  final String companyCode;
  final String? selectedBranchCode;

  const ReportsDashboardPage({super.key, required this.companyCode, this.selectedBranchCode});

  // تعريف التقارير التحليلية مع معرف كل تقرير واسمه وصلاحيته
  static final List<Map<String, dynamic>> _advancedReports = [
    {'id': 1, 'name': 'بيان التدفق النقدي', 'permission': (PermissionsService p) => p.canViewAdvancedReport1},
    {'id': 14, 'name': 'تحليل المصروفات بالنسبة للمبيعات', 'permission': (PermissionsService p) => p.canViewAdvancedReport14},
    {'id': 2, 'name': 'تحليل هيكل المصروفات', 'permission': (PermissionsService p) => p.canViewAdvancedReport2},
    {'id': 3, 'name': 'الربحية الصافية لكل فرع', 'permission': (PermissionsService p) => p.canViewAdvancedReport3},
    {'id': 15, 'name': 'صافي ربح الفترة', 'permission': (PermissionsService p) => p.canViewAdvancedReport13},
    {'id': 4, 'name': 'تحليل حجم الفاتورة', 'permission': (PermissionsService p) => p.canViewAdvancedReport4},
    {'id': 5, 'name': 'تحليل الخزائن النقدية', 'permission': (PermissionsService p) => p.canViewAdvancedReport5},
    {'id': 6, 'name': 'الأصناف بطيئة الحركة', 'permission': (PermissionsService p) => p.canViewAdvancedReport6},
    {'id': 7, 'name': 'تحليل دقة الجرد', 'permission': (PermissionsService p) => p.canViewAdvancedReport7},
    {'id': 8, 'name': 'تقييم المخزون و ABC', 'permission': (PermissionsService p) => p.canViewAdvancedReport8},
    {'id': 9, 'name': 'تحليل أداء الموردين', 'permission': (PermissionsService p) => p.canViewAdvancedReport9},
    {'id': 10, 'name': 'تحليل العوائد والخصومات', 'permission': (PermissionsService p) => p.canViewAdvancedReport10},
    {'id': 11, 'name': 'تحليل الاتجاهات الموسمية', 'permission': (PermissionsService p) => p.canViewAdvancedReport11},
    {'id': 12, 'name': 'تحليل هامش الربح الفعلي', 'permission': (PermissionsService p) => p.canViewAdvancedReport12},
    {'id': 13, 'name': 'تحليل تجميع المنتجات', 'permission': (PermissionsService p) => p.canViewAdvancedReport13},
  ];

  void _open(BuildContext context, int id) {
    if (id <= 3) {
      // التقارير الأساسية (المبيعات، الفترة، الموسع)
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReportsPage(
            companyCode: companyCode,
            selectedBranchCode: selectedBranchCode,
            initialReportType: id,
          ),
        ),
      );
      return;
    }
    // التقارير التحليلية (يتم تمرير id-3 كـ reportId)
    final now = DateTime.now();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdvancedReportsPage(
          companyCode: companyCode,
          selectedBranchCode: selectedBranchCode,
          reportId: id - 3,
          fromDate: DateTime(now.year, now.month, 1),
          toDate: now,
        ),
      ),
    );
  }

  Widget _card(BuildContext context, String title, IconData icon, Color color, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color.withOpacity(.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color.withOpacity(.3)),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo', fontWeight: FontWeight.bold),
                  ),
                ),
                Icon(Icons.arrow_back_ios_new, color: AppTheme.textFaintFor(context), size: 16),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final perms = PermissionsService();
    final canSales = perms.canViewReportsSales;
    final canPeriod = perms.canViewReportsPeriod;
    final canExtended = perms.canViewExtendedReport; // الصلاحية الجديدة للتقرير الموسع

    // بناء قائمة البطاقات للتقارير الأساسية
    final List<Widget> cards = [];

    if (canSales) {
      cards.add(_card(context, 'تقرير المبيعات', Icons.point_of_sale, AppTheme.successFor(context), () => _open(context, 1)));
    }
    if (canPeriod) {
      cards.add(_card(context, 'تقرير الفترة', Icons.analytics, AppTheme.accentFor(context), () => _open(context, 2)));
    }
    if (canPeriod && canExtended) {
      cards.add(_card(
        context,
        'التقرير المالي الموسع / صافي الجرد الحالي',
        Icons.account_balance_wallet,
        AppTheme.warningFor(context),
        () => _open(context, 3),
      ));
    }

    // إضافة التقارير التحليلية حسب الصلاحيات
    for (final report in _advancedReports) {
      final bool hasPermission = report['permission'](perms);
      if (hasPermission) {
        cards.add(_card(
          context,
          report['name'],
          Icons.insights,
          AppTheme.infoFor(context),
          () => _open(context, report['id'] + 3),
        ));
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('لوحة التقارير', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientMain(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  'التقارير والتحليلات',
                  style: TextStyle(color: AppTheme.accentFor(context), fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView(
                    children: cards,
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