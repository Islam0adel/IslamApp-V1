import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/page_visibility.dart';
import 'package:islam_app/services/company_permission_policy.dart';
import 'package:islam_app/services/permission_catalog.dart';
import 'package:islam_app/services/permissions_service.dart';
void main(){
 test('shared page catalog and false projection',(){
  expect(PageVisibility.keys,(jsonDecode(File('../contracts/page_visibility.json').readAsStringSync())['keys'] as List).toSet());
  for(final k in PageVisibility.keys){
   expect(emptyPermissionCatalog()['صلاحيات عامة']![k],false);
   expect(CompanyPermissionPolicy.effectivePermissions({}, {'صلاحيات عامة':{k:false}})['صلاحيات عامة']![k],false);
  }
 });
 test('untouched missing controls do not become assignments on save',(){
  final view={'صلاحيات عامة':{for(final k in PageVisibility.keys)k:true}};
  expect(PageVisibility.forSave(view,{},view)['صلاحيات عامة'],isEmpty);
  final changed=view.map((c,v)=>MapEntry(c,Map<String,bool>.from(v)));changed['صلاحيات عامة']!['إظهار تحويلات الخزائن']=false;
  expect(PageVisibility.forSave(changed,{},view)['صلاحيات عامة'],{'إظهار تحويلات الخزائن':false});
 });
 test('every new page can show without operation authority',(){
  final ps=PermissionsService();ps.debugSetPermissionsForTest({'صلاحيات عامة':{for(final k in PageVisibility.keys)k:true}},role:'employee',loaded:true,companyPolicyActive:true);
  expect(ps.canShowTreasuryTransfers,true);expect(ps.canShowSales,true);expect(ps.canShowStockPage,true);
  expect(ps.canViewTreasuryTransfers,false);expect(ps.canAddTreasuryTransfer,false);expect(ps.canViewSales,false);expect(ps.canAddSale,false);expect(ps.canShowStock,false);
  ps.reset();
 });
}
