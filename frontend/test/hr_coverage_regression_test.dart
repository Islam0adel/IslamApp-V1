import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/hr_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 FirebasePlatform.instance=f.FakeCore();FirebaseAuthPlatform.instance=f.FakeAuth();
 late Directory dir;
 setUp(() async {PermissionsService().debugSetPermissionsForTest({},role:'super_admin',loaded:true);f.currentUid='uid-A';dir=Directory.systemTemp.createTempSync('hr_logic_probe');Hive.init(dir.path);await Hive.openBox('coding_box');SharedPreferences.setMockInitialValues({'company_code':'C1'});});
 tearDown(() async {await Hive.close();dir.deleteSync(recursive:true);});
 test('failed adjustments do not acquire cursor or empty-success cache',()async{
  int failures=0;
  final result=await http.runWithClient(()=>HRService().syncAll('C1'),()=>MockClient((r)async{
   if(r.url.path.contains('/adjustments/list/')){failures++;return http.Response('failed',500);}
   return http.Response(jsonEncode([]),200);
  }));
  final p=await SharedPreferences.getInstance();
  expect(failures,6);expect(result['adjustments'].toString(),startsWith('error:'));expect(p.getString('last_sync_hr_adjustments_C1'),isNull);expect(Hive.box('coding_box').get('C1_hr_adjustments'),isNull);

 });
 test('HR reports individual module failures',()async{
  final result=await http.runWithClient(()=>HRService().syncAll('C1'),()=>MockClient((r)async=>http.Response('failed',500)));
  expect(result['attendance'].toString(),startsWith('error:'));expect(result['adjustments'].toString(),startsWith('error:'));
 });
 test('unloaded historic adjustments fetched once including empty result',()async{
  await Hive.box('coding_box').put('C1_hr_adjustments',[]);
  var calls=0;
  final data=await http.runWithClient(()=>HRService().getEmployeeAdjustments(companyCode:'C1',employeeCode:'E1',month:'2020-01'),()=>MockClient((r)async{calls++;return http.Response('[]',200);}));
  expect(data,isEmpty);expect(calls,1);
  await http.runWithClient(()=>HRService().getEmployeeAdjustments(companyCode:'C1',employeeCode:'E1',month:'2020-01'),()=>MockClient((r)async{calls++;return http.Response('[]',200);}));
  expect(calls,1);
 });

 test('successful recent months reused while failed month retried',()async{
  final calls=<String,int>{};String? failed;
  await http.runWithClient(()async{
   final first=await HRService().syncAll('C1');expect(first['adjustments'].toString(),startsWith('error:'));
   final second=await HRService().syncAll('C1');expect(second['adjustments'],'ok');
  },()=>MockClient((r)async{
   if(r.url.path.contains('/adjustments/list/')){
    final m=r.url.queryParameters['month']!;calls[m]=(calls[m]??0)+1;failed??=m;
    if(m==failed && calls[m]==1)return http.Response('failed',500);
   }
   return http.Response('[]',200);
  }));
  expect(calls.length,6);expect(calls[failed],2);expect(calls.values.where((c)=>c==1).length,5);
 });

}
