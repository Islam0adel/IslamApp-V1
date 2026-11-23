import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:islam_app/services/journal_cache.dart';

void main(){
  late Directory dir;late Box box;
  Map<String,dynamic> row(String company,{double amount=100})=>{'company_code':company,'branch_code':'B1','serial':1,'amount':amount};
  setUpAll(() async{dir=Directory.systemTemp.createTempSync('journal_identity_');Hive.init(dir.path);box=await Hive.openBox('daily_transactions_box');});
  setUp(() async=>box.clear());
  tearDownAll(() async{await Hive.close();dir.deleteSync(recursive:true);});
  test('legacy replacement never exposes double-counted identity to listeners',()async{
    await box.put('branch_B1_1',row('C1'));
    final observed=<double>[];
    final sub=box.watch().listen((_){
      observed.add(box.values.whereType<Map>().where((r)=>r['company_code']=='C1').fold<double>(0,(sum,r)=>sum+(r['amount'] as num).toDouble()));
    });
    await JournalCache.put(box,row('C1',amount:140),expectedCompany:'C1');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(observed,isNotEmpty);expect(observed.every((n)=>n==140),isTrue);
    expect(box.get('branch_B1_1'),isNull);expect(box.values.whereType<Map>().length,1);
  });
  test('deleting C1 does not delete C2 legacy row with identical branch and serial',()async{
    await box.put('branch_B1_1',row('C2'));
    await JournalCache.put(box,row('C1'));
    await JournalCache.delete(box,company:'C1',branch:'B1',serial:'1');
    expect(box.get('branch_B1_1')['company_code'],'C2');expect(box.length,1);
  });
  test('foreign-company response is rejected before modifying cache',()async{
    await box.put('branch_B1_1',row('C1'));
    await expectLater(JournalCache.put(box,row('C2'),expectedCompany:'C1'),throwsStateError);
    expect(box.length,1);expect(box.get('branch_B1_1')['company_code'],'C1');
  });
  test('company cleanup preserves similarly prefixed companies and their balances',()async{
    await JournalCache.put(box,row('C1'));await JournalCache.put(box,row('C1_other'));
    await box.put('C1_balances_all',{'A':100});await box.put('C1_other_balances_all',{'A':200});
    await JournalCache.deleteCompany(box,'C1');
    expect(box.length,2);expect(box.get('C1_other_balances_all')['A'],200);
    expect(box.values.whereType<Map>().any((r)=>r['company_code']=='C1_other'),isTrue);
  });
}
