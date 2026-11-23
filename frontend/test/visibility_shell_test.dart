import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/views/dashboard/commercial/sales_dashboard_page.dart';
import 'package:islam_app/views/widgets/visibility_page_shell.dart';
void main(){
 testWidgets('explicit show opens empty shell with zero HTTP without operation rights',(tester)async{
  PermissionsService().debugSetPermissionsForTest({'صلاحيات عامة':{'إظهار فاتورة مبيعات':true}},role:'employee',loaded:true,companyPolicyActive:true);
  var reads=0;
  await http.runWithClient(()async{
   await tester.pumpWidget(const MaterialApp(home:SalesDashboardPage(companyCode:'C1')));await tester.pumpAndSettle();
   expect(find.text('فاتورة مبيعات'),findsOneWidget);await tester.tap(find.text('فاتورة مبيعات'));await tester.pumpAndSettle();
   expect(find.byType(VisibilityPageShell),findsOneWidget);expect(reads,0);expect(PermissionsService().canAddSale,false);
   await tester.pumpWidget(const SizedBox());
  },()=>MockClient((r)async{reads++;throw StateError('Unauthorized data request');}));
 });
}
