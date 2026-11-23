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
import 'package:islam_app/services/user_service.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/views/dashboard/company_users_page.dart';
import 'commercial_queue_regression_test.dart' as identity;
import 'account_editor_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = identity.FakeCore();
  FirebaseAuthPlatform.instance = identity.FakeAuth();
  setUpAll(() async {
    await (FontLoader('Cairo')
          ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'company_code': 'C1', 'user_email': 'owner@example.invalid'});
    identity.currentUid = 'uid-A';
  });
  tearDown(() async {
    if (Hive.isBoxOpen('users_box')) await Hive.close();
  });
  testWidgets(
      'actual metadata page versions, revocation, and exact-route closure',
      (tester) async {
    for (final action in ['save', 'epoch', 'role', 'new-route']) {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await Hive.openBox('users_box', bytes: Uint8List(0));
      PermissionsService().debugSetPermissionsForTest({},
          role: 'admin', loaded: true, branches: ['B1']);
      await UserService().clearCache();
      Map<String, dynamic>? saved;
      var editorReads = 0;
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
            builder: (context, child) =>
                Directionality(textDirection: TextDirection.rtl, child: child!),
            theme: AppTheme.lightTheme,
            home: const Directionality(
                textDirection: TextDirection.rtl,
                child: CompanyUsersPage(
                    companyCode: 'C1', companyName: 'Test company'))));
        await tester.pumpAndSettle(const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
        expect(find.text('Cached list name'), findsOneWidget);
        await tester.tap(find.text('تعديل'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
        expect(editorReads, 1);
        expect(
            find.byWidgetPredicate((widget) =>
                widget is TextField && widget.controller?.text == 'fresh_name'),
            findsOneWidget);
        expect(
            find.byWidgetPredicate((widget) =>
                widget is TextField &&
                widget.controller?.text == 'Fresh target'),
            findsOneWidget);
        if (action == 'save') {
          await tester.tap(find.text('حفظ'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100),
              EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
          expect(saved?['username'], 'fresh_name');
          expect(saved?['name'], 'Fresh target');
          expect(saved?['expected_target_uid'], 'target-uid');
          expect(saved?['expected_profile_version'], 'source-version-1');
          expect(saved?['expected_policy_revision'], 4);
          expect(saved!.containsKey('branch_code'), false);
          expect(saved!.containsKey('allowed_branches'), false);
          expect(tester.takeException(), isNull);
        } else {
          final controllers = tester
              .widgetList<TextField>(find.byType(TextField))
              .map((field) => field.controller)
              .whereType<TextEditingController>()
              .toList();
          if (action == 'new-route') {
            Navigator.of(tester.element(find.byType(CompanyUserEditDialog)))
                .push(MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: Text('New route stays'))));
            await tester.pumpAndSettle();
          }
          if (action == 'role') {
            PermissionsService().setRole('employee');
          } else {
            ReadAuthorizationEpoch.invalidate();
          }
          await tester.pumpAndSettle();
          expect(find.byType(CompanyUserEditDialog), findsNothing);
          expect(
              controllers.every((controller) => controller.text.isEmpty), true);
          expect(saved, isNull);
          expect(Hive.box('users_box').isEmpty, true);
          if (action == 'new-route')
            expect(find.text('New route stays'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle(const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
        await UserService().clearCache();
        await Hive.close();
        await tester.pump();
      },
          () => MockClient((request) async {
                if (request.url.path.contains('/user-editor/')) {
                  editorReads++;
                  return fixture.reply(fixture.response());
                }
                if (request.method == 'PUT') {
                  saved = Map<String, dynamic>.from(jsonDecode(request.body));
                  return fixture.reply({'status': 'success'});
                }
                if (request.url.path.endsWith('/company-users'))
                  return fixture.reply([
                    {
                      'email': fixture.target,
                      'uid': 'target-uid',
                      'company_code': 'C1',
                      'role': 'employee',
                      'name': 'Cached list name',
                      'status': 'active',
                      'has_account': true,
                    }
                  ]);
                return fixture.reply(<dynamic>[]);
              }));
    }
  });
}
