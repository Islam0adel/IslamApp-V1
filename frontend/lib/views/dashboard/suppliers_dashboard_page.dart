// lib/views/dashboard/suppliers_dashboard_page.dart
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import 'supplier_page.dart';
import 'supplier_history_page.dart';
import 'supplier_settlement_page.dart';
import 'supplier_settlement_history_page.dart';

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
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ListView(
              children: [
                const SizedBox(height: 16),
                // ✅ زر المشتريات (صفحة الموردين الحالية)
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
                        builder: (c) => SupplierPage(
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
                        builder: (c) => SupplierHistoryPage(
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
                        builder: (c) => SupplierSettlementPage(
                          companyCode: companyCode,
                          selectedBranchCode: selectedBranchCode,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),

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
        builder: (c) => SupplierSettlementHistoryPage(
          companyCode: companyCode,
          selectedBranchCode: selectedBranchCode,
        ),
      ),
    );
  },
),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GlassCard(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: color.withOpacity(0.15),borderRadius: BorderRadius.circular(12),),
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
        ),
      ),
    );
  }

  void _showUnderDevelopment(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '⏳ صفحة "$feature" قيد التطوير وسيتم إضافتها قريباً',
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: AppTheme.warningOrangeFor(context),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}