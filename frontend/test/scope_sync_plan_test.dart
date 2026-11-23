import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/scope_sync_plan.dart';
void main(){
 Set<String> plan(Map<String,dynamic> a,Map<String,dynamic> b)=>ScopeSyncPlan.between(before:a,after:b,oldBranches:['B1'],branches:['B1']);
 test('page visibility only never resets business cursors',(){expect(plan({'صلاحيات عامة':{'إظهار المبيعات':true}},{'صلاحيات عامة':{'إظهار المبيعات':false}}),isEmpty);});
 test('single sales right only resets sales and coding dependencies',(){expect(plan({'المبيعات':{'عرض سعر الجملة':true}},{'المبيعات':{'عرض سعر الجملة':false}}),{'sales','coding'});});
 test('branch change conservatively refreshes only named company keys',(){final m=ScopeSyncPlan.between(before:{},after:{},oldBranches:['B1'],branches:['B1','B2']);final keys=ScopeSyncPlan.cursorKeys('C1',m);expect(keys,isNotEmpty);expect(keys.every((k)=>k.endsWith('_C1')),true);expect(keys.contains('last_sync_daily_C2'),false);});
 test('HR employee scope change resets only HR and employees',(){expect(ScopeSyncPlan.between(before:{},after:{},oldBranches:['B1'],branches:['B1'],oldEmployees:['E1'],employees:['E2']),{'employees','hr'});});
 test('pending operation box or cursor is never part of plan',(){expect(ScopeSyncPlan.cursorKeys('C1',ScopeSyncPlan.all).any((k)=>k.contains('pending')),false);});
}
