import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/core/theme.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/user_service.dart';
import 'package:islam_app/views/dashboard/company_users_page.dart';
import 'commercial_queue_regression_test.dart' as identity;
import 'account_editor_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = identity.FakeCore();
  FirebaseAuthPlatform.instance = identity.FakeAuth();
  setUpAll(() async {
    await (FontLoader('Cairo')
          ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  testWidgets(
      'actual active page uses independent actions and minimal picker in both themes',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(
        {'company_code': 'C1', 'user_email': 'owner@example.invalid'});
    identity.currentUid = 'uid-A';
    for (final dark in [false, true]) {
      for (final kind in ['edit', 'view', 'status', 'reject']) {
        await Hive.openBox('users_box', bytes: Uint8List(0));
        final right = {
          'edit': 'تعديل',
          'view': 'معاينة',
          'status': 'تغيير حالة الحساب',
          'reject': 'رفض طلب'
        }[kind]!;
        PermissionsService().debugSetPermissionsForTest(
            {
              'إدارة المستخدمين': {right: true}
            },
            role: 'employee',
            loaded: true,
            companyPolicyActive: true,
            branches: ['B1']);
        await UserService().clearCache();
        var requestReads = 0;
        Map<String, dynamic>? saved;
        await http.runWithClient(() async {
          await tester.pumpWidget(MaterialApp(
              builder: (context, child) => Directionality(
                  textDirection: TextDirection.rtl, child: child!),
              theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
              home: const Directionality(
                  textDirection: TextDirection.rtl,
                  child: CompanyUsersPage(
                      companyCode: 'C1', companyName: 'شركة التجربة'))));
          await tester.pumpAndSettle();
          expect(PermissionsService().canManageUsers, false);
          expect(find.text('إضافة مستخدم'),
              kind == 'edit' ? findsOneWidget : findsNothing);
          expect(find.text('حذف'), findsNothing);
          expect(find.text('إعادة تعيين'), findsNothing);
          if (kind == 'reject') {
            expect(requestReads, 1);
            expect(find.text('رفض'), findsOneWidget);
            expect(find.text('موافقة'), findsNothing);
          } else {
            expect(requestReads, 0);
            expect(find.text('كل الفروع (موظف عام)'), findsNothing);
            expect(find.text('تعديل'),
                kind == 'view' ? findsNothing : findsOneWidget);
            expect(find.text('01000000000'),
                kind == 'view' ? findsOneWidget : findsNothing);
            if (kind == 'edit')
              await expectLater(
                  find.byType(CompanyUsersPage),
                  matchesGoldenFile(
                      'goldens/management_picker_${dark ? 'dark' : 'light'}.png'));
            if (kind != 'view') {
              await tester.tap(find.text('تعديل'));
              await tester.pumpAndSettle();
              expect(
                  find.byWidgetPredicate((widget) =>
                      widget is TextField &&
                      widget.controller?.text == 'fresh_name'),
                  kind == 'edit' ? findsOneWidget : findsNothing);
              if (kind == 'status') {
                expect(find.text('محظور'), findsOneWidget);
                await expectLater(
                    find.byType(AlertDialog),
                    matchesGoldenFile(
                        'goldens/management_blocked_status_${dark ? 'dark' : 'light'}.png'));
              }
              await tester.tap(find.text('حفظ'));
              await tester.pumpAndSettle();
              expect(saved?['expected_profile_version'], 'source-version-1');
              expect(saved!.containsKey('username'), kind == 'edit');
              expect(saved!.containsKey('status'), false);
              if (kind == 'status') expect(saved!['is_active'], false);
            }
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await UserService().clearCache();
          await Hive.close();
          await tester.pump();
        },
            () => MockClient((request) async {
                  if (request.url.path.contains('/user-editor/'))
                    return fixture.reply(fixture.response(
                        edit: kind == 'edit', status: kind == 'status')
                      ..['is_active'] = kind != 'status');
                  if (request.method == 'PUT') {
                    saved = Map<String, dynamic>.from(jsonDecode(request.body));
                    return fixture.reply({'status': 'success'});
                  }
                  if (request.url.path.endsWith('/registration-requests')) {
                    requestReads++;
                    return fixture.reply([
                      {
                        'id': 'r1',
                        'name': 'طلب جديد',
                        'company_code': 'C1',
                        'status': 'pending'
                      }
                    ]);
                  }
                  if (request.url.path.endsWith('/company-users'))
                    return fixture.reply(kind == 'reject'
                        ? []
                        : [
                            {
                              'email': fixture.target,
                              'uid': 'target-uid',
                              'company_code': 'C1',
                              'name': 'موظف التجربة',
                              'role': 'employee',
                              'status': 'active',
                              'has_account': true,
                              'is_active': kind != 'status',
                              if (kind != 'view')
                                'directory_summary_only': true,
                              if (kind == 'view') ...{
                                'phone_number': '01000000000',
                                'username': 'private_name',
                                'branch_code': 'B2'
                              },
                            }
                          ]);
                  throw StateError(
                      'Unexpected request in management page test');
                }));
      }
    }
  });
}
