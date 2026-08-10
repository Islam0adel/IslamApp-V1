// lib/views/dashboard/suppliers_dashboard_page.dart
import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import 'supplier_page.dart';
import 'supplier_history_page.dart';

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
        title: const Text(
          'المشتريات والموردين',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Cairo',
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF020617),
              Color.fromARGB(255, 47, 54, 190),
              Color(0xFF020617),
            ],
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
                  color: Colors.lightBlueAccent,
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
                  color: Colors.cyanAccent,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (c) => SupplierHistoryPage(
                          companyCode: companyCode,
                          selectedBranchCode: selectedBranchCode,
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
                  color: Colors.amber,
                  onTap: () {
                    _showUnderDevelopment(context, 'تسويات الموردين');
                  },
                ),
                const SizedBox(height: 16),
                // ✅ زر تحليل الموردين (قيد التطوير)
                _buildDashboardCard(
                  context,
                  icon: Icons.analytics_rounded,
                  title: 'تحليل الموردين',
                  subtitle: 'تحليل أداء الموردين والتقارير',
                  color: Colors.purpleAccent,
                  onTap: () {
                    _showUnderDevelopment(context, 'تحليل الموردين');
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
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Cairo',
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: Colors.white30,
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
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}