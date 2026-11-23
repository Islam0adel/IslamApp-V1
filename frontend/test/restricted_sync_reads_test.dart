import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:islam_app/main.dart' as app;
import 'package:islam_app/services/cache_partitions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/sync_read_access.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'package:islam_app/services/hr_service.dart';
import 'package:islam_app/pages/hr/hr_dashboard_page.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  void grants(Map<String, dynamic> map,
          {String role = 'employee', bool policy = true}) =>
      PermissionsService().debugSetPermissionsForTest(map,
          role: role, loaded: true, companyPolicyActive: policy);
  setUpAll(() async {
    await (FontLoader('Cairo')
          ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
    FirebasePlatform.instance = f.FakeCore();
    FirebaseAuthPlatform.instance = f.FakeAuth();
    dir = Directory.systemTemp.createTempSync('restricted_sync_');
    Hive.init(dir.path);
    for (final name in CachePartitions.boxes) {
      await Hive.openBox(name);
    }
  });
  setUp(() async {
    f.currentUid = 'uid-A';
    SharedPreferences.setMockInitialValues({'company_code': 'C1'});
    await TestWidgetsFlutterBinding.instance.runAsync(() async { await Hive.box('coding_box').clear(); });
    grants({});
  });
  tearDownAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async { await Hive.close(); dir.deleteSync(recursive: true); });
  });
  test(
      'read plan denies unloaded, unknown and visibility-only; bypass is explicit',
      () {
    grants({
      'صلاحيات عامة': {
        'إظهار الموارد البشرية': true,
        'إظهار المبيعات والعملاء': true
      }
    });
    for (final module in SyncReadAccess.checks.keys) {
      expect(SyncReadAccess.allows(module), false, reason: module);
    }
    expect(SyncReadAccess.allows('unknown'), false);
    grants({}, role: 'admin', policy: true);
    expect(SyncReadAccess.allows('sales'), false);
    grants({}, role: 'admin', policy: false);
    expect(SyncReadAccess.allows('sales'), true);
    grants({'صلاحيات عامة': {'إظهار الموارد البشرية': true}}, role: 'super_admin');
    expect(SyncReadAccess.allows('attendance'), true);
    PermissionsService()
        .debugSetPermissionsForTest({}, role: 'super_admin', loaded: false);
    expect(SyncReadAccess.allows('sales'), false);
  });
  test(
      'every endpoint grant enables its module; view/add independent and edit implies only declared add',
      () {
    for (final module in SyncReadAccess.checks.entries) {
      for (final check in module.value) {
        grants({
          check[0]: {check[1]: true}
        });
        expect(SyncReadAccess.allows(module.key), true,
            reason: '${module.key}:$check');
      }
    }
    grants({
      'المبيعات': {'إضافة': true}
    });
    expect(SyncReadAccess.allows('sales'), false);
    expect(SyncReadAccess.allows('coding'), true);
    expect(SyncReadAccess.allows('employees'), true);
    grants({
      'حركة الخزينة': {'التعديل': true}
    });
    expect(SyncReadAccess.allows('daily'), true);
    grants({
      'الموارد البشرية': {'canViewOwnHRData': true}
    });
    expect(SyncReadAccess.allows('employees'), true);
    expect(SyncReadAccess.allows('attendance'), false);
    expect(SyncReadAccess.allows('employee_settings'), false);
  });
  test(
      'real startup no read rights makes zero HTTP and leaves cursors unchanged',
      () async {
    final p = await SharedPreferences.getInstance();
    await p.setString('last_sync_daily_C1', 'unchanged');
    var calls = 0;
    await http.runWithClient(
        () => app.syncAllDataIfNeeded('C1'),
        () => MockClient((_) async {
              calls++;
              return http.Response('[]', 200);
            }));
    expect(calls, 0);
    expect(p.getString('last_sync_daily_C1'), 'unchanged');
    expect(p.getKeys().where((k) => k.startsWith('last_sync_')),
        ['last_sync_daily_C1']);
  });
  test(
      'real startup own-data only requests employee references, not HR bulk or commercial',
      () async {
    grants({
      'الموارد البشرية': {'canViewOwnHRData': true}
    });
    final paths = <String>[];
    await http.runWithClient(
        () => app.syncAllDataIfNeeded('C1'),
        () => MockClient((r) async {
              paths.add(r.url.path);
              return http.Response('[]', 200);
            }));
    expect(paths, ['/employees/list/C1']);
  });
  test(
      'HR startup no read rights makes zero requests and does not write cursors',
      () async {
    var calls = 0;
    final result = await http.runWithClient(
        () => HRService().syncAll('C1'),
        () => MockClient((_) async {
              calls++;
              return http.Response('[]', 200);
            }));
    expect(calls, 0);
    expect(result.values, everyElement('skipped'));
    final p = await SharedPreferences.getInstance();
    expect(p.getKeys().where((k) => k.startsWith('last_sync_')), isEmpty);
  });
  test(
      'attendance grant starts only attendance and settings; skips preserve previous cursors',
      () async {
    grants({
      'الموارد البشرية': {'canOpenAttendancePage': true}
    });
    final p = await SharedPreferences.getInstance();
    await p.setString('last_sync_hr_vacations_C1', 'unchanged');
    final paths = <String>[];
    final result = await http.runWithClient(
        () => HRService().syncAll('C1'),
        () => MockClient((r) async {
              paths.add(r.url.path);
              return http.Response('[]', 200);
            }));
    expect(paths.length, 2);
    expect(paths.any((v) => v.contains('vacations')), false);
    expect(paths.any((v) => v.contains('adjustments')), false);
    expect(result['attendance'], 'ok');
    expect(result['vacations'], 'skipped');
    expect(p.getString('last_sync_hr_vacations_C1'), 'unchanged');
  });
  test(
      'allowed request denied by server is still failure not skipped or success',
      () async {
    grants({
      'الموارد البشرية': {'canViewAdjustments': true}
    });
    var calls = 0;
    final result = await http.runWithClient(
        () => HRService().syncAll('C1'),
        () => MockClient((_) async {
              calls++;
              return http.Response('{}', 403);
            }));
    expect(calls, greaterThan(0));
    expect(result['adjustments'], startsWith('error:'));
    expect(
        (await SharedPreferences.getInstance())
            .getString('last_sync_hr_adjustments_C1'),
        isNull);
  });
  testWidgets(
      'visible HR without data rights repeated entries send zero HTTP and show no stats',
      (tester) async {
    grants({
      'صلاحيات عامة': {'إظهار الموارد البشرية': true}
    });
    var calls = 0;
    await http.runWithClient(() async {
      for (var i = 0; i < 2; i++) {
        await tester
            .pumpWidget(MaterialApp(home: HRDashboardPage(key: ValueKey(i))));
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('إحصائيات اليوم'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
        () => MockClient((_) async {
              calls++;
              return http.Response('{}', 403);
            }));
    expect(calls, 0);
  });
  testWidgets(
      'own-data user keeps profile card and employee count but never requests attendance',
      (tester) async {
    grants({
      'صلاحيات عامة': {'إظهار الموارد البشرية': true},
      'الموارد البشرية': {'canViewOwnHRData': true}
    });
    await tester.runAsync(() async {
      await Hive.box('coding_box').put('C1_employees', []);
    });
    var calls = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: HRDashboardPage()));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('ملفي الشخصي'), findsOneWidget);
      expect(find.text('إجمالي الموظفين'), findsOneWidget);
      expect(find.text('حاضر'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((_) async {
              calls++;
              return http.Response('{}', 403);
            }));
    expect(calls, 0);
  });
  testWidgets(
      'revocation while stats await cannot publish attendance or old employee count',
      (tester) async {
    grants({
      'صلاحيات عامة': {'إظهار الموارد البشرية': true},
      'الموارد البشرية': {'canOpenAttendancePage': true}
    });
    final gate = Completer<http.Response>();
    var calls = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: HRDashboardPage()));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(calls, 1);
      grants({
        'صلاحيات عامة': {'إظهار الموارد البشرية': true}
      });
      gate.complete(http.Response('[]', 200));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('حاضر'), findsNothing);
      expect(find.text('إجمالي الموظفين'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((_) async {
              calls++;
              return gate.future;
            }));
  });
  testWidgets('identical scope notifications neither duplicate in-flight reads nor reload settled stats', (tester) async {
    grants({'صلاحيات عامة': {'إظهار الموارد البشرية': true}}, role: 'super_admin');
    await tester.runAsync(() async { PermissionsService().setAllowedBranches(['all']); await Future<void>.delayed(const Duration(milliseconds: 30)); });
    final gate = Completer<http.Response>();
    var employeeCalls = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: HRDashboardPage()));
      Future<void> drain() async {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
      }
      await drain();
      expect(employeeCalls, 1);
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() async { PermissionsService().setAllowedBranches(['all']); await Future<void>.delayed(const Duration(milliseconds: 30)); });
        await drain();
      }
      expect(employeeCalls, 1);
      await tester.runAsync(() async { gate.complete(http.Response('{}', 403)); await Future<void>.delayed(const Duration(milliseconds: 80)); });
      for (var i=0; i<5; i++) { await drain(); } await tester.pumpAndSettle();
      await tester.runAsync(() async { PermissionsService().setAllowedBranches(['all']); await Future<void>.delayed(const Duration(milliseconds: 30)); });
      await drain();
      expect(employeeCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());

    }, () => MockClient((r) async {
      if (r.url.path.contains('/employees/')) { employeeCalls++; return gate.future; }
      return http.Response('{}', 403);
    }));
  });
  testWidgets('real scope changes coalesce behind old read and never publish revoked data', (tester) async {
    grants({'صلاحيات عامة': {'إظهار الموارد البشرية': true}}, role: 'super_admin');
    await tester.runAsync(() async { PermissionsService().setAllowedBranches(['all']); await Future<void>.delayed(const Duration(milliseconds: 30)); });
    final gate = Completer<http.Response>();
    var calls = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: HRDashboardPage()));
      Future<void> drain() async {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
      }
      await drain(); expect(calls, 1);
      await tester.runAsync(() async {
        PermissionsService().setAllowedBranches(['B1']);
        PermissionsService().setAllowedBranches(['B2']);
      });
      await drain(); expect(calls, 1);
      expect(find.text('0'), findsNothing);
      await tester.runAsync(() async { gate.complete(http.Response('{}', 403)); await Future<void>.delayed(const Duration(milliseconds: 80)); });
      for (var i=0; i<5; i++) { await drain(); } await tester.pumpAndSettle();
      expect(calls, 3); // one stale employee read, one current employee + attendance.
      expect(find.text('غير متاح'), findsNWidgets(5));
      await tester.runAsync(() async { grants({'صلاحيات عامة': {'إظهار الموارد البشرية': true}}); });
      await tester.pump();
      expect(find.text('إجمالي الموظفين'), findsNothing);
      expect(find.text('حاضر'), findsNothing);
      await drain(); expect(calls, 3);
      await tester.pumpWidget(const SizedBox());

    }, () => MockClient((r) async {
      calls++;
      if (calls == 1) return gate.future;
      return http.Response('{}', 403);
    }));
  });
  testWidgets('owner epoch invalidation immediately hides settled statistics', (tester) async {
    grants({'صلاحيات عامة': {'إظهار الموارد البشرية': true}}, role: 'super_admin');
    await tester.runAsync(() async {
      await Hive.box('coding_box').put('C1_employees', []);
      await Hive.box('coding_box').put('C1_hr_attendance', []);
      final date = DateTime.now().toIso8601String().substring(0,10);
      await Hive.box('coding_box').put('C1_hr_coverage_attendance_day_*_*_$date', PermissionsService().hrCoverageScope);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: HRDashboardPage()));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 160)));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsNWidgets(5));
      f.currentUid = 'uid-B';
      ReadAuthorizationEpoch.invalidate();
      await tester.pump();
      expect(find.text('0'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    }, () => MockClient((r) async => http.Response('{}', 403)));
  });
  for (final state in ['own', 'allowed', 'partial', 'visible', 'narrow']) {
    testWidgets(
        'dashboard rendered $state preserves allowed cards and statistics',
        (tester) async {
      tester.view.physicalSize =
          state == 'narrow' ? const Size(390, 1000) : const Size(1000, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      grants({
        'صلاحيات عامة': {'إظهار الموارد البشرية': true},
        'الموارد البشرية': {
          if (state == 'own') 'canViewOwnHRData': true,
          if (state == 'allowed' || state == 'partial' || state == 'narrow')
            'canOpenAttendancePage': true,
        }
      });
      await tester.runAsync(() async {
        await Hive.box('coding_box').put('C1_employees', []);
        if (state == 'allowed' || state == 'narrow') {
          final date = DateTime.now().toIso8601String().substring(0, 10);
          await Hive.box('coding_box').put('C1_hr_attendance', []);
          await Hive.box('coding_box').put(
              'C1_hr_coverage_attendance_day_*_*_$date',
              PermissionsService().hrCoverageScope);
        }
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(
            home: Directionality(
                textDirection: TextDirection.rtl, child: HRDashboardPage())));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        if (state == 'partial') {
          expect(find.text('غير متاح'), findsNWidgets(4));
          expect(find.text('0'), findsOneWidget);
        }
        if (state == 'allowed') {
          expect(find.text('0'), findsNWidgets(5));
          expect(find.text('الحضور والانصراف'), findsOneWidget);
        }
        await expectLater(find.byType(Scaffold),
            matchesGoldenFile('goldens/restricted_hr_$state.png'));
        await tester.pumpWidget(const SizedBox());
      },
          () => MockClient((r) async => http.Response(
              state == 'partial' && r.url.path.contains('/attendance/')
                  ? '{}'
                  : '[]',
              state == 'partial' && r.url.path.contains('/attendance/')
                  ? 403
                  : 200)));
    });
  }
}
