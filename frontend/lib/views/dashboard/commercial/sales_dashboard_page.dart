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
    if (p.canAddSale) pages.add(('فاتورة مبيعات', 'بيع الأصناف وتسجيل الدفع أو الآجل', Icons.point_of_sale, SalesPage(companyCode: companyCode, selectedBranchCode: branchCode, userName: userName)));
    if (p.canViewSales) pages.add(('معاينة المبيعات', 'البحث في الفواتير وتعديلها حسب الصلاحيات', Icons.receipt_long, SalesHistoryPage(companyCode: companyCode, branchCode: branchCode, userName: userName)));
    if (p.canAddSaleReturn) pages.add(('مرتجع مبيعات', 'إرجاع الأصناف وتسجيل رد قيمتها', Icons.assignment_return, SaleReturnPage(companyCode: companyCode, selectedBranchCode: branchCode, userName: userName)));
    if (p.canViewSaleReturns) pages.add(('معاينة المرتجعات', 'سجل المرتجعات السابقة', Icons.history, CommercialHistoryPage(companyCode: companyCode, kind: 'returns', title: 'معاينة المرتجعات', branchCode: branchCode)));
    if (p.canAddCustomerPayment) pages.add(('تحصيل من عميل', 'تسجيل دفعة تقلل رصيد العميل', Icons.price_check, CustomerPaymentsPage(companyCode: companyCode, branchCode: branchCode, userName: userName)));
    if (p.canViewCustomerPayments) pages.add(('معاينة تحصيلات العملاء', 'سجل التحصيلات وتعديلها أو حذفها حسب الصلاحيات', Icons.history, CommercialHistoryPage(companyCode: companyCode, kind: 'customer-payments', title: 'تحصيلات العملاء', branchCode: branchCode)));
    if (p.canViewCustomerBalances) pages.add(('أرصدة العملاء', 'متابعة المبالغ الآجلة والتحصيلات', Icons.people_alt, CustomerBalancesPage(companyCode: companyCode, branchCode: branchCode)));
    if (p.canViewSalesTreasuries) pages.add(('أرصدة خزائن المبيعات', 'أرصدة مستقلة عن اليومية الحالية', Icons.account_balance_wallet, SalesTreasuryBalancesPage(companyCode: companyCode, branchCode: branchCode)));
    return CommercialPageFrame(title: 'المبيعات والعملاء', child: ListView(padding: const EdgeInsets.all(16), children: pages.map((e) => Card(child: ListTile(leading: Icon(e.$3, color: AppTheme.accentFor(context)), title: Text(e.$1, style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)), subtitle: Text(e.$2, style: const TextStyle(fontFamily: 'Cairo')), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => e.$4))))).toList()));
  }
}
