// Real HRService and local FastAPI/SQLite. No live host is accepted.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/hr_service.dart';
import 'package:islam_app/models/hr_models.dart';
import 'commercial_queue_regression_test.dart' as f;

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global=null;
  final endpoint=Platform.environment['ISLAMAPP_TEST_API'];
  if(endpoint==null){test('HR local route integration (opt-in)',(){},skip:'Local fixture required');return;}
  final base=Uri.parse(endpoint);
  if(!{'127.0.0.1','localhost'}.contains(base.host))throw StateError('Local fixture only');
  FirebasePlatform.instance=f.FakeCore();FirebaseAuthPlatform.instance=f.FakeAuth();
  final io=HttpClient();late Directory dir;
  var dropNextSave=false;
  Future<http.Response> forward(http.Request request)async{
    final outgoing=await io.openUrl(request.method,base.replace(path:request.url.path,query:request.url.query));
    request.headers.forEach(outgoing.headers.set);
    outgoing.headers.set('x-fixture-hr-add-only','1');
    outgoing.add(utf8.encode(request.body));
    final response=await outgoing.close();
    final body=await utf8.decoder.bind(response).join();
    if(request.method=='POST' && dropNextSave){dropNextSave=false;expect(response.statusCode,200);throw const SocketException('simulated lost reply after commit');}
    return http.Response(body,response.statusCode,headers:{'content-type':'application/json; charset=utf-8'});
  }
  Future<List> rows(String kind)async{
    final request=http.Request('GET',base.replace(path:'/hr/$kind/list/C1'));
    final response=await forward(request);
    expect(response.statusCode,200);
    return jsonDecode(response.body) as List;
  }
  setUpAll(()async{
    dir=Directory.systemTemp.createTempSync('hr_routes_');Hive.init(dir.path);
    await Hive.openBox('coding_box');await Hive.openBox('hr_pending_box');f.currentUid='uid-A';
  });
  tearDownAll(()async{await Hive.close();dir.deleteSync(recursive:true);io.close(force:true);});
  test('HR1 add-only reconnect acknowledges committed create without editing it',()async{
    final service=HRService();
    HRAttendanceModel model(String notes)=>HRAttendanceModel(companyCode:'C1',branchCode:'B1',employeeCode:'E1',date:'2026-11-22',status:'present',notes:notes);
    await service.addPendingSave(model('حضور تجريبي'));
    dropNextSave=true;
    await http.runWithClient(()async{
      final first=await service.commitPending(companyCode:'C1',employeeCode:'E1');
      expect(first['success'],false);expect(Hive.box('hr_pending_box').length,1);
      final before=await rows('attendance');expect(before.length,1);expect(before.single['created_by'],isNull);
      final retry=await service.commitPending(companyCode:'C1',employeeCode:'E1');
      expect(retry['success'],true);expect(Hive.box('hr_pending_box').isEmpty,true);
      final after=await rows('attendance');expect(after,before);
      final cached=Hive.box('coding_box').get('C1_hr_attendance') as List;
      expect(cached.single['id'],before.single['id']);expect(cached.single['notes'],'حضور تجريبي');
      await service.addPendingSave(model('تعديل غير مسموح'));
      final change=await service.commitPending(companyCode:'C1',employeeCode:'E1');
      expect(change['success'],false);expect(change['errors'].toString(),contains('403'));
      expect(Hive.box('hr_pending_box').length,1);expect(await rows('attendance'),before);
    },()=>MockClient(forward));
  });
  test('HR2 add-only vacation retry succeeds but changed content remains forbidden',()async{
    final service=HRService();
    HRVacationModel model(String name)=>HRVacationModel(companyCode:'C1',branchCode:'B1',date:'2026-11-23',name:name);
    dropNextSave=true;
    await http.runWithClient(()async{
      expect((await service.saveVacation(model:model('إجازة تجريبية')))['success'],false);
      final before=await rows('vacations');expect(before.length,1);expect(before.single['created_by'],isNull);
      final retry=await service.saveVacation(model:model('إجازة تجريبية'));
      expect(retry['success'],true);expect(retry['action'],'unchanged');expect(await rows('vacations'),before);
      final changed=await service.saveVacation(model:model('اسم مختلف'));
      expect(changed['success'],false);expect(changed['error'],contains('403'));expect(await rows('vacations'),before);
    },()=>MockClient(forward));
  });
}
