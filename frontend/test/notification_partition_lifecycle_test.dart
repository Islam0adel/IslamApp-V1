import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/cache_partitions.dart';
import 'package:islam_app/services/notifications_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('production partition wrappers cannot reset socket work on Home mount',() async {
  FirebasePlatform.instance=f.FakeCore();FirebaseAuthPlatform.instance=f.FakeAuth();
  f.currentUid='uid-A';SharedPreferences.setMockInitialValues({'company_code':'C1'});
  final dir=Directory.systemTemp.createTempSync('notification_partition_');Hive.init(dir.path);
  CachePartitions.enable();await CachePartitions.activate('uid-A','C1');
  PermissionsService().debugSetPermissionsForTest({'صلاحيات عامة':{'إظهار الإشعارات':true}},role:'super_admin',loaded:true);
  final service=NotificationsService.instance;
  expect(identical(CachePartitions.box('notification_settings_box'),CachePartitions.box('notification_settings_box')),false);
  expect(identical(CachePartitions.boxIdentity('notification_settings_box'),CachePartitions.boxIdentity('notification_settings_box')),true);
  var settings=0,history=0;final release=Completer<void>();
  await http.runWithClient(() async {
   expect(service.bindCompany('C1'),true);
   final a=service.loadSettingsFromServer();final b=service.refreshFromServer(companyCode:'C1');
   while(settings<1||history<1){await Future<void>.delayed(const Duration(milliseconds:2));}
   service.setCompany('C1');service.setCompany('C1');
   final c=service.loadSettingsFromServer();final d=service.refreshFromServer(companyCode:'C1');
   await Future<void>.delayed(const Duration(milliseconds:20));
   expect(settings,1);expect(history,1);
   release.complete();await Future.wait([a,b,c,d]);
   service.setCompany('C1');await Future<void>.delayed(const Duration(milliseconds:20));
   expect(settings,1);expect(history,1);
   final old=CachePartitions.boxIdentity('notification_settings_box');
   CachePartitions.suspend();await CachePartitions.activate('uid-A','C1');
   // Physical Box may remain, but cache generation still invalidates binding.
   expect(service.bindCompany('C1'),true);
   expect(identical(old,CachePartitions.boxIdentity('notification_settings_box')),false);
   f.currentUid='uid-B';CachePartitions.suspend();await CachePartitions.activate('uid-B','C1');
   expect(service.bindCompany('C1'),true);
  },()=>MockClient((r)async{
   if(r.url.path.endsWith('/settings')){settings++;await release.future;return http.Response('{}',200);}
   history++;await release.future;return http.Response(jsonEncode({'items':[],'next_cursor':1,'has_more':false}),200);
  }));
  await Hive.close();dir.deleteSync(recursive:true);
 });
}
