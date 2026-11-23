import '../../widgets/visibility_page_shell.dart';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/permissions_service.dart';
import 'commercial_shared.dart';
import 'sales_page.dart';
import 'sales_history_page.dart';
import 'sale_return_page.dart';
import 'customer_payments_page.dart';
import 'commercial_history_page.dart';
import 'customer_balances_page.dart';
import 'sales_treasury_balances_page.dart';

class SalesDashboardPage extends StatelessWidget {
  final String companyCode; final String? branchCode; final String? userName;
  const SalesDashboardPage({super.key, required this.companyCode, this.branchCode, this.userName});
  @override Widget build(BuildContext context) {
    final p = PermissionsService();
    final pages = <(String, String, IconData, Widget)>[];
    if (p.pageVisible('فاتورة مبيعات', fallback: p.canAddSale)) pages.add(('فاتورة مبيعات', 'بيع الأصناف وتسجيل الدفع أو الآجل', Icons.point_of_sale, p.canAddSale ? SalesPage(companyCode: companyCode, selectedBranchCode: branchCode, userName: userName) : const VisibilityPageShell(title: 'فاتورة مبيعات')));
    if (p.pageVisible('معاينة المبيعات', fallback: p.canViewSales)) pages.add(('معاينة المبيعات', 'البحث في الفواتير وتعديلها حسب الصلاحيات', Icons.receipt_long, p.canViewSales ? SalesHistoryPage(companyCode: companyCode, branchCode: branchCode, userName: userName) : const VisibilityPageShell(title: 'معاينة المبيعات')));
    if (p.pageVisible('مرتجع مبيعات', fallback: p.canAddSaleReturn)) pages.add(('مرتجع مبيعات', 'إرجاع الأصناف وتسجيل رد قيمتها', Icons.assignment_return, p.canAddSaleReturn ? SaleReturnPage(companyCode: companyCode, selectedBranchCode: branchCode, userName: userName) : const VisibilityPageShell(title: 'مرتجع مبيعات')));
    if (p.pageVisible('معاينة المرتجعات', fallback: p.canViewSaleReturns)) pages.add(('معاينة المرتجعات', 'سجل المرتجعات السابقة', Icons.history, p.canViewSaleReturns ? CommercialHistoryPage(companyCode: companyCode, kind: 'returns', title: 'معاينة المرتجعات', branchCode: branchCode) : const VisibilityPageShell(title: 'معاينة المرتجعات')));
    if (p.pageVisible('تحصيل من عميل', fallback: p.canAddCustomerPayment)) pages.add(('تحصيل من عميل', 'تسجيل دفعة تقلل رصيد العميل', Icons.price_check, p.canAddCustomerPayment ? CustomerPaymentsPage(companyCode: companyCode, branchCode: branchCode, userName: userName) : const VisibilityPageShell(title: 'تحصيل من عميل')));
    if (p.pageVisible('معاينة تحصيلات العملاء', fallback: p.canViewCustomerPayments)) pages.add(('معاينة تحصيلات العملاء', 'سجل التحصيلات وتعديلها أو حذفها حسب الصلاحيات', Icons.history, p.canViewCustomerPayments ? CommercialHistoryPage(companyCode: companyCode, kind: 'customer-payments', title: 'تحصيلات العملاء', branchCode: branchCode) : const VisibilityPageShell(title: 'معاينة تحصيلات العملاء')));
    if (p.pageVisible('أرصدة العملاء', fallback: p.canViewCustomerBalances)) pages.add(('أرصدة العملاء', 'متابعة المبالغ الآجلة والتحصيلات', Icons.people_alt, p.canViewCustomerBalances ? CustomerBalancesPage(companyCode: companyCode, branchCode: branchCode) : const VisibilityPageShell(title: 'أرصدة العملاء')));
    if (p.pageVisible('أرصدة خزائن المبيعات', fallback: p.canViewSalesTreasuries)) pages.add(('أرصدة خزائن المبيعات', 'أرصدة مستقلة عن اليومية الحالية', Icons.account_balance_wallet, p.canViewSalesTreasuries ? SalesTreasuryBalancesPage(companyCode: companyCode, branchCode: branchCode) : const VisibilityPageShell(title: 'أرصدة خزائن المبيعات')));
    return CommercialPageFrame(title: 'المبيعات والعملاء', dashboard: true, child: ListView(padding: const EdgeInsets.all(16), children: pages.map((e) => Card(child: ListTile(leading: Icon(e.$3, color: AppTheme.accentFor(context)), title: Text(e.$1, style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)), subtitle: Text(e.$2, style: const TextStyle(fontFamily: 'Cairo')), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => e.$4))))).toList()));
  }
}
