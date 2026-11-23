import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/core/theme.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/websocket_sync_service.dart';
import 'package:islam_app/views/dashboard/permissions_page.dart';
import 'package:islam_app/views/widgets/permission_action_switch.dart';
import 'commercial_queue_regression_test.dart' as identity;
import 'effective_profile_refresh_test.dart' as source;
import 'permission_editor_snapshot_test.dart' as fixture;

class PageSource extends source.QuietFirestore {
  @override
  CollectionReferencePlatform collection(String path) =>
      PageCollection(this, path);
}

class PageCollection extends source.QuietCollection {
  PageCollection(super.firestore, super.path) {
    parameters
        .addAll({'where': <List<dynamic>>[], 'orderBy': <List<dynamic>>[]});
  }
  @override
  QueryPlatform where(List<List<dynamic>> conditions) =>
      throw StateError('Raw account collection query is forbidden');
  @override
  Stream<QuerySnapshotPlatform> snapshots(
          {bool includeMetadataChanges = false,
          required ListenSource listenSource}) =>
      throw StateError('Raw account collection stream is forbidden');
}

Map<String, dynamic> directoryJson() => {
      'company_code': 'C1',
      'users': [
        {
          'email': 'target@example.invalid',
          'uid': 'target',
          'name': 'موظف التجربة',
          'company_code': 'C1',
          'job_code': '1',
          'role': 'employee',
          'is_active': true
        }
      ]
    };
http.Response answer(http.Request request, Map<String, dynamic> editor) =>
    http.Response(
        jsonEncode(request.url.path.endsWith('/permission-editor-targets')
            ? directoryJson()
            : editor),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});
void directoryHint() {
  final old = WebSocketSyncService.userDirectoryChanges.value;
  WebSocketSyncService.userDirectoryChanges.value =
      (company: 'C1', revision: old.revision + 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = identity.FakeCore();
  FirebaseAuthPlatform.instance = identity.FakeAuth();
  final fs = PageSource();
  FirebaseFirestorePlatform.instance = fs;
  tearDownAll(() async {
    await fs.events.close();
  });
  const email = 'target@example.invalid';
  setUpAll(() async {
    await (FontLoader('Cairo')
          ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() async {
    // Widget tests use the real Hive API with an in-memory backend. Disk
    // persistence is covered by the plain async save-acknowledgement tests.
    await Hive.openBox('coding_box', bytes: Uint8List(0));
    SharedPreferences.setMockInitialValues(
        {'company_code': 'C1', 'user_email': email, 'job_code': '1'});
    identity.currentUid = 'uid-A';
    PermissionsService()
        .debugSetPermissionsForTest({}, role: 'admin', branches: ['B1']);
    await Hive.box('coding_box').put('permissions_$email', {
      'المبيعات': {'حذف': true}
    });
  });
  tearDown(() async {
    await Hive.close();
  });
  Future<void> open(WidgetTester tester,
      {bool dark = false, bool narrow = true}) async {
    tester.view.physicalSize =
        narrow ? const Size(430, 950) : const Size(1200, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        home: const PermissionsPage()));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(TabBar));
    DefaultTabController.of(context).animateTo(5);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('legacy status uses versioned endpoint not direct Firestore',
      (tester) async {
    var active = true;
    Map? sent;
    await http.runWithClient(() async {
      await open(tester);
      DefaultTabController.of(tester.element(find.byType(TabBar)))
          .animateTo(13);
      await tester.pumpAndSettle();
      final toggle = find.byWidgetPredicate((w) =>
          w is SwitchListTile &&
          w.title is Text &&
          ((w.title as Text).data == 'الحساب نشط'));
      await tester.scrollUntilVisible(toggle, 300,
          scrollable: find
              .descendant(
                  of: find.byType(TabBarView),
                  matching: find.byType(Scrollable))
              .last);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'حظر'));
      await tester.pumpAndSettle();
      expect(sent!['is_active'], false);
      expect(sent!['expected_target_uid'], 'target');
      expect(sent!['expected_profile_version'], 'v1');
      expect(sent!.containsKey('permissions'), false);
      expect(find.text('الحساب محظور'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((r) async {
              if (r.url.path.endsWith('/permission-editor-status')) {
                sent = jsonDecode(r.body) as Map;
                active = false;
                return http.Response('{"status":"success"}', 200);
              }
              final e = fixture.editorJson();
              e['company_policy_active'] = false;
              e['is_active'] = active;
              return answer(r, e);
            }));
  });

  testWidgets('general controls are visible independent page choices', (tester) async {
    PermissionsService().debugSetPermissionsForTest({},role:'super_admin',branches:['all']);
    await http.runWithClient(() async {
      await open(tester);
      DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(13);
      await tester.pumpAndSettle();
      for(final label in ['إظهار تحويلات الخزائن','إظهار المبيعات والعملاء','إظهار رصيد المخزون']) {
        await tester.scrollUntilVisible(find.text(label),150,scrollable:find.descendant(of:find.byType(TabBarView),matching:find.byType(Scrollable)).last);
        expect(find.text(label),findsOneWidget);
      }
      await expectLater(find.byType(Scaffold),matchesGoldenFile('goldens/page_visibility_controls.png'));
      await tester.pumpWidget(const SizedBox());
    },()=>MockClient((r)async{final e=fixture.editorJson();e['company_policy_active']=false;e['platform_admin']=true;return answer(r,e);}));
  });
  testWidgets('root self status disabled with honest explanation',
      (tester) async {
    PermissionsService()
        .debugSetPermissionsForTest({}, role: 'super_admin', branches: ['all']);
    await http.runWithClient(() async {
      await open(tester);
      DefaultTabController.of(tester.element(find.byType(TabBar)))
          .animateTo(13);
      await tester.pumpAndSettle();
      final toggle = find.byWidgetPredicate((w) =>
          w is SwitchListTile &&
          w.title is Text &&
          ((w.title as Text).data == 'الحساب نشط'));
      await tester.scrollUntilVisible(toggle, 300,
          scrollable: find
              .descendant(
                  of: find.byType(TabBarView),
                  matching: find.byType(Scrollable))
              .last);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      expect(find.text('لا يمكن حظر حسابك كصاحب البرنامج'), findsOneWidget);
      await expectLater(find.byType(Scaffold),
          matchesGoldenFile('goldens/permission_root_self_status.png'));
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((r) async {
              final e = fixture.editorJson();
              e['company_policy_active'] = false;
              e['platform_admin'] = true;
              e['role'] = 'super_admin';
              e['is_self'] = true;
              if (r.url.path.endsWith('/permission-editor-targets')) {
                final d = directoryJson();
                d['users'][0]['name'] = 'صاحب البرنامج';
                d['users'][0]['role'] = 'super_admin';
                return http.Response(jsonEncode(d), 200, headers: {
                  'content-type': 'application/json; charset=utf-8'
                });
              }
              return answer(r, e);
            }));
  });

  for (final targetRole in ['super_admin', 'admin']) {
    testWidgets('root opens role target with honest explanation $targetRole',
        (tester) async {
      PermissionsService().debugSetPermissionsForTest({},
          role: 'super_admin', branches: ['all']);
      await http.runWithClient(() async {
        await open(tester, dark: targetRole == 'super_admin');
        expect(
            find.textContaining(targetRole == 'super_admin'
                ? 'هذه العلامات المحفوظة لا تقيد'
                : 'الحفظ يعدل صلاحيات استخدام المدير'),
            findsOneWidget);
        await expectLater(find.byType(Scaffold),
            matchesGoldenFile('goldens/permission_role_$targetRole.png'));
        await tester.pumpWidget(const SizedBox());
      },
          () => MockClient((r) async {
                final e = fixture.editorJson();
                e['role'] = targetRole;
                e['platform_admin'] = true;
                if (r.url.path.endsWith('/permission-editor-targets')) {
                  final d = directoryJson();
                  d['users'][0]['name'] = targetRole == 'super_admin'
                      ? 'صاحب البرنامج'
                      : 'مدير الشركة';
                  d['users'][0]['role'] = targetRole;
                  return http.Response(jsonEncode(d), 200, headers: {
                    'content-type': 'application/json; charset=utf-8'
                  });
                }
                return answer(r, e);
              }));
    });
  }
  testWidgets(
      'actual permission bulk actions retain denied rights and branch scopes',
      (tester) async {
    Map? sent;
    await http.runWithClient(() async {
      await open(tester);
      await tester.tap(find.text('تحديد الكل'));
      await tester.pumpAndSettle();
      final switches = tester
          .widgetList<PermissionActionSwitch>(
              find.byType(PermissionActionSwitch))
          .toList();
      expect(switches.firstWhere((v) => v.label == 'تعديل').value, true);
      expect(switches.firstWhere((v) => v.label == 'حذف').value, false);
      await tester.tap(find.byIcon(Icons.save_rounded));
      await tester.pumpAndSettle();
      expect(sent!['permissions']['المبيعات']['تعديل'], true);
      expect(sent!['permissions']['المبيعات']['حذف'], false);
      expect(sent!['allowed_branches'], isNull);
      expect(sent!['startup_branch_code'], isNull);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async {
              if (request.method == 'POST') {
                sent = jsonDecode(request.body) as Map;
                return http.Response('{"status":"success"}', 200);
              }
              return answer(request, fixture.editorJson());
            }));
  });
  for (final dark in [false, true]) {
    for (final narrow in [false, true]) {
      testWidgets(
          'actual page loads server scope not cached target rights dark=$dark narrow=$narrow',
          (tester) async {
        await http.runWithClient(() async {
          await open(tester, dark: dark, narrow: narrow);
          final switches = tester
              .widgetList<PermissionActionSwitch>(
                  find.byType(PermissionActionSwitch))
              .toList();
          final deletion = switches.firstWhere((v) => v.label == 'حذف');
          expect(deletion.value, false);
          expect(deletion.onChanged, isNull);
          final edit = switches.firstWhere((v) => v.label == 'تعديل');
          expect(edit.onChanged, isNotNull);
          await expectLater(
              find.byType(Scaffold),
              matchesGoldenFile(
                  'goldens/permission_page_${dark ? 'dark' : 'light'}_${narrow ? 'narrow' : 'wide'}.png'));
          await tester.pumpWidget(const SizedBox());
        },
            () => MockClient(
                (request) async => answer(request, fixture.editorJson())));
      });
    }
  }
  for (final status in [403, 409, 503]) {
    testWidgets('actual page does not claim a local save after server $status',
        (tester) async {
      Map? sent;
      await http.runWithClient(() async {
        await open(tester);
        await tester.tap(find.byIcon(Icons.save_rounded));
        await tester.pumpAndSettle();
        expect(find.textContaining('لم يتم تأكيد الحفظ'), findsWidgets);
        expect(find.textContaining('تم الحفظ محلياً'), findsNothing);
        expect(sent!['expected_target_uid'], 'target');
        expect(sent!['expected_profile_version'], 'v1');
        expect(sent!['expected_policy_revision'], 2);
        expect(sent!.containsKey('allowed_branches'), false);
        expect(sent!.containsKey('hr_viewable_employees'), false);
        expect(Hive.box('coding_box').get('permissions_$email'), {
          'المبيعات': {'حذف': true}
        });
        expect(
            tester
                .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.save_rounded))
                .onPressed,
            isNull);
        await tester.pumpWidget(const SizedBox());
      },
          () => MockClient((request) async {
                if (request.method == 'POST') {
                  sent = jsonDecode(request.body) as Map;
                  return http.Response('{"detail":"fixture refusal"}', status);
                }
                return answer(request, fixture.editorJson());
              }));
    });
  }

  testWidgets(
      'source change holds the actual editor without overwriting an unsaved draft',
      (tester) async {
    var changed = false;
    await http.runWithClient(() async {
      await open(tester);
      final editing = find.byWidgetPredicate(
          (v) => v is PermissionActionSwitch && v.label == 'تعديل');
      await tester.tap(editing);
      await tester.pumpAndSettle();
      expect(tester.widget<PermissionActionSwitch>(editing).value, true);
      changed = true;
      directoryHint();
      await tester.pumpAndSettle();
      expect(find.textContaining('تغير نطاق الحساب'), findsOneWidget);
      expect(tester.widget<PermissionActionSwitch>(editing).value, true);
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.save_rounded))
              .onPressed,
          isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async {
              final value = fixture.editorJson();
              if (changed) value['profile_version'] = 'v2';
              return answer(request, value);
            }));
  });
  testWidgets(
      'actual editor acknowledges one successful versioned write and reloads the new source version',
      (tester) async {
    var saved = false;
    var gets = 0;
    Map? sent;
    await http.runWithClient(() async {
      await open(tester);
      await tester.tap(find.byWidgetPredicate(
          (v) => v is PermissionActionSwitch && v.label == 'تعديل'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.save_rounded));
      await tester.pumpAndSettle();
      expect(sent!['permissions']['المبيعات']['تعديل'], true);
      expect(sent!['permissions']['المبيعات']['حذف'], false);
      expect(sent!['expected_profile_version'], 'v1');
      expect(gets, 2);
      expect(find.text('تم حفظ الصلاحيات على الخادم'), findsOneWidget);
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.save_rounded))
              .onPressed,
          isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async {
              if (request.method == 'POST') {
                sent = jsonDecode(request.body) as Map;
                saved = true;
                return http.Response('{}', 200);
              }
              if (!request.url.path.endsWith('/permission-editor-targets'))
                gets++;
              final value = fixture.editorJson();
              if (saved) {
                value['profile_version'] = 'v2';
                value['permissions'] = {
                  'المبيعات': {'تعديل': true}
                };
              }
              return answer(request, value);
            }));
  });
  testWidgets(
      'missing selected target holds draft without silently substituting another account',
      (tester) async {
    var missing = false;
    await http.runWithClient(() async {
      await open(tester);
      final editing = find.byWidgetPredicate(
          (v) => v is PermissionActionSwitch && v.label == 'تعديل');
      await tester.tap(editing);
      await tester.pumpAndSettle();
      missing = true;
      directoryHint();
      await tester.pumpAndSettle();
      expect(
          find.textContaining('الحساب المختار لم يعد متاحاً'), findsOneWidget);
      expect(
          tester
              .widget<DropdownButton<String>>(
                  find.byType(DropdownButton<String>))
              .value,
          isNull);
      expect(tester.widget<PermissionActionSwitch>(editing).value, true);
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.save_rounded))
              .onPressed,
          isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async {
              if (missing &&
                  request.url.path.endsWith('/permission-editor-targets')) {
                final value = directoryJson();
                value['users'] = [
                  {
                    'email': 'other@example.invalid',
                    'uid': 'other',
                    'name': 'Other',
                    'role': 'employee',
                    'company_code': 'C1'
                  }
                ];
                return http.Response(jsonEncode(value), 200, headers: {
                  'content-type': 'application/json; charset=utf-8'
                });
              }
              return answer(request, fixture.editorJson());
            }));
  });
  testWidgets('directory hint bursts coalesce and another company is ignored',
      (tester) async {
    var directoryGets = 0;
    final entered = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      await open(tester);
      expect(directoryGets, 1);
      final old = WebSocketSyncService.userDirectoryChanges.value;
      WebSocketSyncService.userDirectoryChanges.value =
          (company: 'C2', revision: old.revision + 1);
      await tester.pumpAndSettle();
      expect(directoryGets, 1);
      directoryHint();
      await tester.pump();
      await entered.future;
      for (var i = 0; i < 15; i++) directoryHint();
      await tester.pump();
      expect(directoryGets, 2);
      release.complete();
      await tester.pumpAndSettle();
      expect(directoryGets, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/permission-editor-targets')) {
                directoryGets++;
                if (directoryGets == 2) {
                  entered.complete();
                  await release.future;
                }
              }
              return answer(request, fixture.editorJson());
            }));
  });
  testWidgets(
      'company transition clears old selector and reloads new-context choices',
      (tester) async {
    var company = 'C1';
    final requested = <String>[];
    await http.runWithClient(() async {
      await open(tester);
      expect(find.text('موظف التجربة'), findsOneWidget);
      company = 'C2';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('company_code', 'C2');
      await prefs.setString('user_email', 'new@example.invalid');
      PermissionsService().setAllowedBranches(['B2']);
      await tester.pumpAndSettle();
      expect(requested, ['C1', 'C2']);
      expect(find.text('موظف التجربة'), findsNothing);
      expect(find.text('New company user'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/permission-editor-targets')) {
                requested.add(request.url.queryParameters['company_code']!);
                if (company == 'C2')
                  return http.Response(
                      jsonEncode({
                        'company_code': 'C2',
                        'users': [
                          {
                            'email': 'new@example.invalid',
                            'uid': 'new-target',
                            'name': 'New company user',
                            'company_code': 'C2',
                            'role': 'employee'
                          }
                        ]
                      }),
                      200);
              }
              final value = fixture.editorJson();
              if (company == 'C2')
                value.addAll({
                  'email': 'new@example.invalid',
                  'uid': 'new-target',
                  'company_code': 'C2'
                });
              return answer(request, value);
            }));
  });
}
