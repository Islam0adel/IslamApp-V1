import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/daily_service.dart';
import 'package:islam_app/services/revocation_service.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance=f.FakeCore();
  FirebaseAuthPlatform.instance=f.FakeAuth();
  late Directory dir;
  setUpAll(() async {
    dir=Directory.systemTemp.createTempSync('journal_scope_');
    Hive.init(dir.path);
    await Hive.openBox('coding_box');
    await Hive.openBox('daily_transactions_box');
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    f.currentUid='uid-A';
    await Hive.box('coding_box').clear();
    await Hive.box('daily_transactions_box').clear();
    for(final company in ['C1','C2']) {
      await Hive.box('coding_box').put('${company}_safes',[{'name':'A'}]);
    }
  });
  tearDownAll(() async { await Hive.close();dir.deleteSync(recursive:true); });
  Map<String,dynamic> row(String company,{String branch='B1',double amount=200})=>{
    'company_code':company,'branch_code':branch,'serial':1,'date':'2026-11-22',
    'type':'وارد','treasury':'A','amount':amount,'is_deleted':false,
  };
  test('two companies retain separate journal records with the same branch and serial',() async {
    await http.runWithClient(() async {
      final service=DailyService();
      await service.fetchAllTransactions('C1');
      await service.fetchAllTransactions('C2');
      final first=await service.getDailySummaryLocal('C1',branchCode:'B1');
      final second=await service.getDailySummaryLocal('C2',branchCode:'B1');
      expect(first['balances']['A'],200);
      expect(second['balances']['A'],50);
    },()=>MockClient((request) async {
      final company=request.url.pathSegments.last;
      return http.Response(jsonEncode([row(company,amount:company=='C1'?200:50)]),200,headers:{'content-type':'application/json; charset=utf-8'});
    }));
  });
  test('journal permission revocation removes legacy row keys for that company only',() async {
    final box=Hive.box('daily_transactions_box');
    await box.put('branch_B1_1',row('C1'));
    await box.put('branch_B2_1',row('C2',branch:'B2'));
    await RevocationService.instance.applyTransition(email:'a@example.test',companyCode:'C1',ownerUid:'uid-A',oldPerms:{'حركة الخزينة':{'المعاينة':true}},newPerms:{});
    expect(box.get('branch_B1_1'),isNull);
    expect(box.get('branch_B2_1')['company_code'],'C2');
  });
  test('branch narrowing removes legacy out-of-scope journal rows, not another company',() async {
    final box=Hive.box('daily_transactions_box');
    await box.put('branch_B2_1',row('C1',branch:'B2'));
    await box.put('branch_B1_1',row('C2'));
    const rights={'حركة الخزينة':{'المعاينة':true}};
    await RevocationService.instance.applyTransition(email:'a@example.test',companyCode:'C1',ownerUid:'uid-A',oldPerms:rights,newPerms:rights,oldBranches:['all'],newBranches:['B1']);
    expect(box.get('branch_B2_1'),isNull);
    expect(box.get('branch_B1_1')['company_code'],'C2');
  });
}
