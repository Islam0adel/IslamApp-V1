// frontend/lib/views/dashboard/suppliers_dashboard_page.dart
import '../widgets/visibility_page_shell.dart';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import 'supplier_page.dart';
import 'supplier_history_page.dart';
import 'supplier_settlement_page.dart';
import 'supplier_settlement_history_page.dart';
import 'commercial_pages.dart';
import '../../services/permissions_service.dart';

// لوحة الموردين
class SuppliersDashboardPage extends StatelessWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? userName;

  const SuppliersDashboardPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.userName,
  });

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'المشتريات والموردين',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppTheme.textMainFor(context)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientDeep(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        // تمتد الواجهة خلف شريط المتصفح السفلي، ويُضاف هامش سفلي في نهاية المحتوى ليبقى آخر عنصر ظاهرًا فوق الشريط.
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: ListView(
              padding: EdgeInsets.only(bottom: 16 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                // ✅ زر المشتريات (صفحة الموردين الحالية)
                if (PermissionsService().pageVisible('المشتريات'))
                  _buildDashboardCard(
                    context,
                    icon: Icons.local_shipping_rounded,
                    title: 'المشتريات',
                    subtitle: 'إضافة فواتير المشتريات من الموردين',
                    color: AppTheme.infoSoftFor(context),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (c) => !(PermissionsService()
                                  .canAddSupplierTransaction)
                              ? const VisibilityPageShell(title: 'المشتريات')
                              : SupplierPage(
                                  companyCode: companyCode,
                                  selectedBranchCode: selectedBranchCode,
                                  userName: userName,
                                ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 16),
                // ✅ زر معاينة المشتريات (صفحة الهيستوري)
                if (PermissionsService().pageVisible('معاينة المشتريات'))
                  _buildDashboardCard(
                    context,
                    icon: Icons.history_rounded,
                    title: 'معاينة المشتريات',
                    subtitle: 'عرض فواتير المشتريات السابقة',
                    color: AppTheme.accentFor(context),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (c) =>
                              !(PermissionsService().canViewSupplierHistory)
                                  ? const VisibilityPageShell(
                                      title: 'معاينة المشتريات')
                                  : SupplierHistoryPage(
                                      companyCode: companyCode,
                                      selectedBranchCode: selectedBranchCode,
                                      userName: userName,
                                    ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 16),
                // ✅ زر تسويات الموردين (قيد التطوير)
                if (PermissionsService().pageVisible('تسويات الموردين'))
                  _buildDashboardCard(
                    context,
                    icon: Icons.account_balance_rounded,
                    title: 'تسويات الموردين',
                    subtitle: 'تسوية حسابات الموردين والدفعات',
                    color: AppTheme.warningFor(context),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (c) =>
                              !(PermissionsService().canAddSupplierSettlement)
                                  ? const VisibilityPageShell(
                                      title: 'تسويات الموردين')
                                  : SupplierSettlementPage(
                                      companyCode: companyCode,
                                      selectedBranchCode: selectedBranchCode,
                                    ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 16),

                if (PermissionsService().pageVisible('معاينة التسويات'))
                  _buildDashboardCard(
                    context,
                    icon: Icons.history_rounded,
                    title: 'معاينة التسويات',
                    subtitle: 'عرض دفعات وتسويات الموردين',
                    color: AppTheme.accentFor(context),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (c) =>
                              !(PermissionsService().canViewSupplierSettlements)
                                  ? const VisibilityPageShell(
                                      title: 'معاينة التسويات')
                                  : SupplierSettlementHistoryPage(
                                      companyCode: companyCode,
                                      selectedBranchCode: selectedBranchCode,
                                    ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 20),
                const SizedBox(height: 16),

                if (PermissionsService().pageVisible('التحويلات المخزنية',
                    fallback: PermissionsService().canAddStockTransfer))
                  _buildDashboardCard(
                    context,
                    icon: Icons.swap_horiz_rounded,
                    title: 'التحويلات المخزنية',
                    subtitle: 'نقل أصناف بين فروع ومخازن الشركة',
                    color: AppTheme.extraTealFor(context),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                !(PermissionsService().canAddStockTransfer)
                                    ? const VisibilityPageShell(
                                        title: 'التحويلات المخزنية')
                                    : StockTransfersPage(
                                        companyCode: companyCode,
                                        branchCode: selectedBranchCode,
                                        userName: userName,
                                      ))),
                  ),
                if (PermissionsService().pageVisible(
                    'معاينة التحويلات المخزنية',
                    fallback: PermissionsService().canViewStockTransfers)) ...[
                  const SizedBox(height: 16),
                  _buildDashboardCard(
                    context,
                    icon: Icons.history_rounded,
                    title: 'معاينة التحويلات المخزنية',
                    subtitle: 'عرض حركات النقل بين الفروع والمخازن',
                    color: AppTheme.accentFor(context),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                !(PermissionsService().canViewStockTransfers)
                                    ? const VisibilityPageShell(
                                        title: 'معاينة التحويلات المخزنية')
                                    : TransfersHistoryPage(
                                        companyCode: companyCode,
                                        branchCode: selectedBranchCode,
                                        userName: userName,
                                      ))),
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // يبني بطاقة لوحة
  Widget _buildDashboardCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GlassCard(
        onTap: onTap,
        opensPage: true,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Cairo',
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppTheme.textMutedFor(context),
                        fontSize: 13,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: AppTheme.iconFaint,
                size: 18,
              ),
            ],
          ),
        ));
  }

  // void _showUnderDevelopment(BuildContext context, String feature) {
  //   ScaffoldMessenger.of(context).showSnackBar(
  //     SnackBar(
  //       content: Text(
  //         '⏳ صفحة "$feature" قيد التطوير وسيتم إضافتها قريباً',
  //         textAlign: TextAlign.center,
  //         style: const TextStyle(fontFamily: 'Cairo'),
  //       ),
  //       backgroundColor: AppTheme.warningOrangeFor(context),
  //       duration: const Duration(seconds: 3),
  //     ),
  //   );
  // }
}
