import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/core/theme.dart';
import 'package:islam_app/views/widgets/permission_bulk_actions.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/views/dashboard/company_policy_review_page.dart';
import 'commercial_queue_regression_test.dart' as identity;

Map<String,dynamic> review() => {'company_code':'C1','revision':1,'status':'legacy_review_required','requires_permission_review':false,
  'active':null,'draft':{'company_permissions':{'المبيعات':{'إضافة':true,'تعديل':true}},'admin_profiles':{'admin-uid':{
    'operating_permissions':{'المبيعات':{'إضافة':true}},'delegable_permissions':{'المبيعات':{'تعديل':true}},'delegable_branches':['B2']}}},
  'source_review_token':'source-1','branches':[{'code':'B1','name':'فرع العمل'},{'code':'B2','name':'فرع الاستخدام'}],
  'accounts':[{'document_id':'admin@example.com','email':'admin@example.com','name':'مدير الشركة','role':'admin','uid':'admin-uid','status':'active','is_active':true,'lifecycle_pending':false,'allowed_branches':['B2'],'permissions':{}}]};
http.Response reply(Object value,[int status=200])=>http.Response(jsonEncode(value),status,headers:{'content-type':'application/json; charset=utf-8'});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance=identity.FakeCore();FirebaseAuthPlatform.instance=identity.FakeAuth();
  setUpAll(() async {
    await (FontLoader('Cairo')..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('bulk operating selection respects ceiling and leaves delegation branches unchanged',(tester) async {
    tester.view.physicalSize=const Size(390,1000);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'company_code':'ROOT'});identity.currentUid='uid-A';
    PermissionsService().debugSetPermissionsForTest({},role:'super_admin',loaded:true,branches:['all']);
    final requests=<http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(theme:AppTheme.lightTheme,home:const Directionality(textDirection:TextDirection.rtl,
        child:CompanyPolicyReviewPage(companyCode:'C1',companyName:'شركة التجربة'))));await tester.pumpAndSettle();
      await tester.tap(find.text('صلاحيات الاستخدام'));await tester.pumpAndSettle();
      final tile=find.ancestor(of:find.text('صلاحيات الاستخدام'),matching:find.byType(ExpansionTile)).first;
      final bulk=find.descendant(of:tile,matching:find.byType(PermissionBulkActions)).first;
      await tester.ensureVisible(bulk);
      await tester.tap(find.descendant(of:bulk,matching:find.text('تحديد الكل')));await tester.pumpAndSettle();
      expect(requests.where((r)=>r.method!='GET'),isEmpty);
      await tester.scrollUntilVisible(find.text('حفظ المسودة فقط'),400);
      await tester.tap(find.text('حفظ المسودة فقط'));await tester.pumpAndSettle();
      final config=jsonDecode(requests.singleWhere((r)=>r.method=='PUT').body)['configuration'];
      final admin=config['admin_profiles']['admin-uid'];
      expect(admin['operating_permissions'],{'المبيعات':{'إضافة':true,'تعديل':true}});
      expect(admin['delegable_permissions'],{'المبيعات':{'تعديل':true}});expect(admin['delegable_branches'],['B2']);
      expect(config['company_permissions'],review()['draft']['company_permissions']);
      await tester.pumpWidget(const SizedBox.shrink());
    },()=>MockClient((request) async {requests.add(request);return reply(review());}));
  });
  testWidgets('retained stale draft needs visible active comparison before save',(tester) async {
    tester.view.physicalSize=const Size(430,950);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'company_code':'ROOT'});identity.currentUid='uid-A';
    PermissionsService().debugSetPermissionsForTest({},role:'super_admin',loaded:true,branches:['all']);
    final value=review();value['revision']=3;value['active_revision']=3;value['draft_base_active_revision']=1;
    value['draft_requires_reconciliation']=true;value['active']=jsonDecode(jsonEncode(value['draft']));
    value['active']['admin_profiles']['admin-uid']['operating_permissions']={'المبيعات':{'تعديل':true}};
    final requests=<http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(theme:AppTheme.lightTheme,home:const Directionality(textDirection:TextDirection.rtl,
        child:CompanyPolicyReviewPage(companyCode:'C1',companyName:'شركة التجربة'))));await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('حفظ المسودة فقط'),400);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,'مراجعة وتفعيل المسودة المحفوظة')).onPressed,isNull);
      await tester.tap(find.text('حفظ المسودة فقط'));await tester.pumpAndSettle();
      expect(requests.where((r)=>r.method=='PUT'),isEmpty);
      expect(find.text('استخدام المديرين المفعل حالياً'),findsOneWidget);
      expect(find.text('استخدام المديرين في المسودة المراد حفظها'),findsOneWidget);
      await expectLater(find.byType(MaterialApp),matchesGoldenFile('goldens/company_policy_reconciliation.png'));
      await tester.tap(find.text('راجعت الاختلافات وأوافق على حفظ اختيارات المسودة'));await tester.pumpAndSettle();
      final body=jsonDecode(requests.singleWhere((r)=>r.method=='PUT').body);
      expect(body['reconciled_active_revision'],3);
      expect(body['configuration'],value['draft']);
      await tester.pumpWidget(const SizedBox.shrink());
    },()=>MockClient((r) async {requests.add(r);return reply(value);}));
  });
  for(final dark in [false,true]) {
    testWidgets('review shows exact assignments and requires saved explicit activation dark=$dark',(tester) async {
      tester.view.physicalSize=const Size(390,1000);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'company_code':'ROOT'});identity.currentUid='uid-A';
      PermissionsService().debugSetPermissionsForTest({},role:'super_admin',loaded:true,branches:['all']);
      final requests=<http.Request>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(theme:dark?AppTheme.darkTheme:AppTheme.lightTheme,builder:(context,child)=>Directionality(textDirection:TextDirection.rtl,child:child!),home:const CompanyPolicyReviewPage(companyCode:'C1',companyName:'شركة التجربة')));
        await tester.pumpAndSettle();
        expect(find.text('مدير الشركة (admin@example.com)'),findsOneWidget);
        expect(find.text('هوية مرتبطة: admin-uid'),findsOneWidget);
        await expectLater(find.byType(Scaffold),matchesGoldenFile('goldens/company_policy_review_${dark?'dark':'light'}.png'));
        await tester.tap(find.text('صلاحيات الاستخدام'));await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('المبيعات').last,250);
        await tester.tap(find.text('المبيعات').last);await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('تعديل').last,250);
        await expectLater(find.byType(Scaffold),matchesGoldenFile('goldens/company_policy_actions_${dark?'dark':'light'}.png'));
        final editRow=find.ancestor(of:find.text('تعديل').last,matching:find.byType(SwitchListTile));
        await tester.tap(editRow);await tester.pumpAndSettle();
        final beforeRefresh=requests.length;
        await tester.tap(find.byTooltip('إعادة تحميل المراجعة'));await tester.pumpAndSettle();
        expect(find.text('تعديلات غير محفوظة'),findsOneWidget);
        await tester.tap(find.text('البقاء في المراجعة'));await tester.pumpAndSettle();
        expect(requests.length,beforeRefresh);
        final activate=find.widgetWithText(OutlinedButton,'مراجعة وتفعيل المسودة المحفوظة');
        await tester.scrollUntilVisible(find.text('حفظ المسودة فقط'),350);
        expect(tester.widget<OutlinedButton>(activate).onPressed,isNull);
        await tester.tap(find.text('حفظ المسودة فقط'));await tester.pumpAndSettle();
        final put=requests.singleWhere((value)=>value.method=='PUT');
        expect(jsonDecode(put.body)['configuration']['admin_profiles']['admin-uid']['operating_permissions']['المبيعات']['تعديل'],true);
        await tester.scrollUntilVisible(find.text('مراجعة وتفعيل المسودة المحفوظة'),300);
        await tester.tap(find.text('مراجعة وتفعيل المسودة المحفوظة'));await tester.pumpAndSettle();
        expect(requests.where((value)=>value.method=='POST'),isEmpty);
        expect(find.textContaining('تنتهي صلاحيات المدير المفتوحة القديمة'),findsOneWidget);
        await tester.tap(find.text('راجعت وأوافق على التفعيل'));await tester.pumpAndSettle();
        final post=requests.singleWhere((value)=>value.method=='POST');
        expect(jsonDecode(post.body),{'expected_revision':1,'source_review_token':'source-1','confirmed_review':true});
        expect(tester.takeException(),isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },()=>MockClient((request) async {requests.add(request);return reply(request.method=='POST'?{'status':'success'}:review());}));
    });
  }
}
