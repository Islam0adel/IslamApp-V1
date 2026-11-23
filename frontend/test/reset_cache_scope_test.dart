import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/reset_data_service.dart';
import 'commercial_queue_regression_test.dart' as f;

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance=f.FakeCore();FirebaseAuthPlatform.instance=f.FakeAuth();
  const names=['daily_transactions_box','coding_box','inventory_box','supplier_box','supplier_settlement_box','hr_pending_box'];
  late Directory dir;
  setUpAll(()async{dir=Directory.systemTemp.createTempSync('reset_scope_');Hive.init(dir.path);for(final name in names){await Hive.openBox(name);}});
  setUp(()async{SharedPreferences.setMockInitialValues({});f.currentUid='uid-A';for(final name in names){await Hive.box(name).clear();}});
  tearDownAll(()async{await Hive.close();dir.deleteSync(recursive:true);});
  for(final name in ['inventory_box','supplier_box']){
    test('reset $name preserves another company cache',()async{
      final box=Hive.box(name);
      await box.put('C1_B1',[{'company_code':'C1','doc_id':'one'}]);
      await box.put('C2_B1',[{'company_code':'C2','doc_id':'two'}]);
      await http.runWithClient(()async{
        if(name=='inventory_box'){await ResetDataService().resetInventory('C1');}
        else{await ResetDataService().resetSupplier('C1');}
      },()=>MockClient((_)async=>http.Response('[]',200)));
      expect(box.get('C1_B1'),isNull);expect(box.get('C2_B1'),isNotNull);
    });
  }
  test('HR reset removes only current owner company pending operations',()async{
    final pending=Hive.box('hr_pending_box');
    await pending.put('own',{'company_code':'C1','user_uid':'uid-A','action':'save'});
    await pending.put('other-company',{'company_code':'C2','user_uid':'uid-A','action':'save'});
    await pending.put('other-owner',{'company_code':'C1','user_uid':'uid-B','action':'save'});
    await pending.put('unknown-owner',{'company_code':'C1','action':'save'});
    await http.runWithClient(()=>ResetDataService().resetHR('C1'),()=>MockClient((_)async=>http.Response('[]',200)));
    expect(pending.get('own'),isNull);
    expect(pending.get('other-company'),isNotNull);expect(pending.get('other-owner'),isNotNull);expect(pending.get('unknown-owner'),isNotNull);
  });
}
