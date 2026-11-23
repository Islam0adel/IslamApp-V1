import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:islam_app/services/journal_import_batch.dart';
import 'package:islam_app/services/journal_save_intent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() { directory=Directory.systemTemp.createTempSync('journal_import_');Hive.init(directory.path); });
  tearDown(() async {await Hive.close();directory.deleteSync(recursive:true);});
  List<Map<String,dynamic>> rows()=>List.generate(3,(i)=>{'company_code':'C1','branch_code':'B1','serial':0,'amount':10+i,'statement':'row$i'});
  JournalImportBatch batch({String owner='u1',String branch='B1'})=>JournalImportBatch(ownerUid:owner,companyCode:'C1',branchCode:branch,bytes:[1,2,3],tabId:'tab-A');
  test('uncertain row resumes original operation and frozen payload, skips confirmed rows',() async {
    final calls=<String>[];final committed=<String>{};var fail=true;
    Future<Map<String,dynamic>> submit(JournalSaveIntent intent,JournalIntentStore store) async {
      calls.add(intent.operationId);committed.add(intent.operationId);
      if (calls.length==2 && fail) throw const SocketException('reply lost');
      return {'committed':true};
    }
    await expectLater(batch().run(rows:rows(),stillAuthorized:()=>true,submit:submit),throwsA(isA<SocketException>()));
    final first=calls[0],uncertain=calls[1];
    await Hive.close();Hive.init(directory.path);fail=false;
    await batch().run(rows:[...rows().map((row)=>{...row,'amount':999})],stillAuthorized:()=>true,submit:(intent,store) {
      expect(intent.payload!['amount'],isNot(999));return submit(intent,store);
    });
    expect(calls.where((id)=>id==first).length,1);expect(calls.where((id)=>id==uncertain).length,2);expect(committed.length,3);
    expect(Hive.box(JournalImportBatch.boxName).isEmpty,true);
    await batch().run(rows:rows(),stillAuthorized:()=>true,submit:submit);
    expect(committed.length,6,reason:'a completed file selected again is a new deliberate action');
  });
  test('permission or owner change stops remaining rows and preserves batch',() async {
    var allowed=true,calls=0;
    await expectLater(batch().run(rows:rows(),stillAuthorized:()=>allowed,submit:(intent,store) async {calls++;allowed=false;return {'committed':true};}),throwsStateError);
    expect(calls,1);expect(Hive.box(JournalImportBatch.boxName).isNotEmpty,true);
  });
  test('pending local acknowledgement cannot advance row or erase original IDs',() async {
    final ids=<String>[];
    await expectLater(batch().run(rows:rows(),stillAuthorized:()=>true,submit:(intent,store) async {ids.add(intent.operationId);return {'committed':true,'intent_pending':true};}),throwsStateError);
    await batch().run(rows:rows(),stillAuthorized:()=>true,submit:(intent,store) async {ids.add(intent.operationId);return {'committed':true};});
    expect(ids[0],ids[1]);expect(ids.length,4);
  });
}
