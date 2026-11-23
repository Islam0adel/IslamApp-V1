import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:islam_app/services/cache_partitions.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;
class Auth extends f.FakeAuth {
  int signouts=0;
  @override Future<void> signOut() async {signouts++;f.currentUid='';}
}
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 final auth=Auth(); late Directory dir; late SharedPreferences prefs;
 late PermissionsService ps;
 setUpAll(() async {
  FirebasePlatform.instance=f.FakeCore();FirebaseAuthPlatform.instance=auth;
  ps=PermissionsService();
  dir=Directory.systemTemp.createTempSync('own_delete_');Hive.init(dir.path);CachePartitions.enable();
 });
 setUp(() async {
  CachePartitions.suspend();f.currentUid='uid-A';auth.signouts=0;
  SharedPreferences.setMockInitialValues({'company_code':'C1','user_email':'a@example.invalid','remember_me':true,'saved_password':'synthetic'});
  prefs=await SharedPreferences.getInstance();await CachePartitions.activate('uid-A','C1');
  for(final n in CachePartitions.boxes){await CachePartitions.box(n).clear();}
  ps.reset();ps.debugSetIdentityForTest(email:'a@example.invalid',prefs:prefs);
  ps.debugSetPermissionsForTest({'المبيعات':{'معاينة':true}},role:'employee',loaded:true,branches:['B1']);
 });
 tearDown(() async {ps.onOwnAccountDeleted=null;ps.reset();CachePartitions.suspend();});
 tearDownAll(() async {await Hive.close();dir.deleteSync(recursive:true);});
 Future<bool> missing({bool cache=false,String uid='uid-A',int? generation})=>ps.handleOwnDocumentAbsence(exists:false,fromCache:cache,uid:uid,email:'a@example.invalid',generation:generation??CachePartitions.generation);
 test('cache-only absence leaves offline scope and saved login alone',() async {
  expect(await missing(cache:true),false);expect(ps.isLoaded,true);expect(auth.signouts,0);expect(prefs.getBool('remember_me'),true);
 });
 test('server-confirmed absence purges clean display, preserves pending and logs out',() async {
  final display=CachePartitions.box('sales_box');final pending=CachePartitions.box('commercial_pending_box');
  await display.put('C1_B1_rows',[{'id':'old-secret','company_code':'C1','branch_code':'B1'}]);
  await pending.put('preserved',{'company_code':'C1','owner_uid':'uid-A','kind':'sales','payload':{'id':'unsent','company_code':'C1'}});
  int routed=0;ps.onOwnAccountDeleted=()=>routed++;
  expect(await missing(),true);expect(ps.isLoaded,false);expect(auth.signouts,1);expect(routed,1);
  expect(CachePartitions.isReady,false);expect(prefs.getBool('remember_me'),null);expect(prefs.getString('saved_password'),null);
  final oldDisplay=Hive.box(CachePartitions.physicalName('sales_box','uid-A','C1'));
  final oldPending=Hive.box(CachePartitions.physicalName('commercial_pending_box','uid-A','C1'));
  expect(oldDisplay.get('C1_B1_rows'),null);expect(oldPending.get('preserved'),isNotNull);
 });
 test('old-owner and superseded A B A deletion cannot log current user out',() async {
  final generation=CachePartitions.generation;
  CachePartitions.suspend();await CachePartitions.activate('uid-A','C1');
  expect(await missing(generation:generation),true);expect(auth.signouts,0);
  expect(await missing(uid:'uid-other'),true);expect(auth.signouts,0);expect(ps.isLoaded,true);
 });
}
