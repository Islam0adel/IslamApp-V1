import 'treasury_protocol_fixture.dart';
// The prior two-journal partial-commit characterization is preserved in the
// review evidence. These tests now exercise the replacement real page.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/treasury_transfer_service.dart';
import 'package:islam_app/views/dashboard/treasury_transfer_page.dart';
import 'package:islam_app/views/dashboard/treasury_transfers_page.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory dir;
  final posts = <Map>[];
  final record = <String, dynamic>{
    'id': 'existing-id',
    'company_code': 'C1',
    'branch_code': 'B1',
    'serial': 7,
    'from_treasury': 'الرئيسية',
    'to_treasury': 'الفرعية',
    'amount': 1250.5,
    'date': '2026-11-22',
    'statement': 'نقل سيولة للفرع',
    'employee': 'أحمد',
    'updated_at': '2026-11-22T10:00:00'
  };
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('treasury_new_ui_');
    Hive.init(dir.path);
    for (final name in [
      'daily_transactions_box',
      'coding_box',
      TreasuryTransferService.recordsBox,
      TreasuryTransferService.effectsBox
    ]) {
      await Hive.openBox(name);
    }
    final loader = FontLoader('Cairo')
      ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    await loader.load();
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await iconLoader.load();
  });
  setUp(() async {
    posts.clear();
    f.currentUid = 'uid-A';
    PermissionsService().debugSetPermissionsForTest(
        {
          'تحويلات الخزائن': {
            'إضافة': true,
            'معاينة': true,
            'تعديل': true,
            'حذف': true
          },
          'حركة الخزينة': {'شاشات الارصدة': true}
        },
        role: 'employee',
        branches: ['all']);
    for (final name in [
      TreasuryTransferService.recordsBox,
      TreasuryTransferService.effectsBox,
      'daily_transactions_box'
    ]) {
      await Hive.box(name).clear();
    }
    await Hive.box('coding_box').put('C1_safes', [
      {'name': 'الرئيسية'},
      {'name': 'الفرعية'}
    ]);
  });
  tearDownAll(() async {
    await Hive.close().timeout(const Duration(seconds: 3));
    dir.deleteSync(recursive: true);
  });
  Widget app(Widget child) => MaterialApp(
      theme: ThemeData(fontFamily: 'Cairo'),
      home: Directionality(textDirection: TextDirection.rtl, child: child));
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
    }
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
  }

  http.Client client({bool fail = false}) => treasuryClient((r) async {
        if (r.method == 'POST') {
          final payload = jsonDecode(r.body) as Map;
          posts.add(payload);
          if (fail) return http.Response('injected failure', 500);
          return http.Response(
              jsonEncode({
                'status': 'success',
                'record': {
                  ...payload,
                  'serial': 1,
                  'updated_at': '2026-11-22T10:00:00'
                }
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('[]', 200);
      });

  testWidgets('real page makes one independent POST and no journal rows',
      (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(app(const TreasuryTransferPage(
          companyCode: 'C1', selectedBranchCode: 'B1')));
      await tester.enterText(find.byType(TextField).first, '100');
      await tester.ensureVisible(find.text('تنفيذ التحويل'));
      await tester.runAsync(() async {
        await tester.tap(find.text('تنفيذ التحويل'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      await drain(tester);
      expect(posts.length, 1);
      expect(posts.single['from_treasury'], 'الرئيسية');
      expect(posts.single['to_treasury'], 'الفرعية');
      expect(posts.single.containsKey('type'), false);
      expect(Hive.box('daily_transactions_box').isEmpty, true);
      expect(find.text('تم حفظ التحويل بنجاح'), findsOneWidget);
      await finish(tester);
    }, () => client());
  });

  testWidgets('uncertain save retries exactly the same ID and payload',
      (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(app(const TreasuryTransferPage(
          companyCode: 'C1', selectedBranchCode: 'B1')));
      await tester.enterText(find.byType(TextField).first, '100');
      await tester.ensureVisible(find.text('تنفيذ التحويل'));
      await tester.runAsync(() async {
        await tester.tap(find.text('تنفيذ التحويل'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('إعادة تأكيد الحفظ'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).first).enabled,
          false);
      await tester.runAsync(() async {
        await tester.tap(find.text('إعادة تأكيد الحفظ'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(posts.length, 2);
      expect(posts[1], posts[0]);
      expect(Hive.box('daily_transactions_box').isEmpty, true);
      await finish(tester);
    }, () => client(fail: true));
  });

  testWidgets('aggregate branch selection cannot create a transfer',
      (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(app(const TreasuryTransferPage(
          companyCode: 'C1', selectedBranchCode: 'all')));
      await tester.enterText(find.byType(TextField).first, '100');
      await tester.ensureVisible(find.text('تنفيذ التحويل'));
      await tester.tap(find.text('تنفيذ التحويل'));
      await tester.pump();
      expect(posts, isEmpty);
      expect(find.textContaining('اختر فرعاً محدداً'), findsOneWidget);
      await finish(tester);
    }, () => client());
  });

  testWidgets('edit form preserves identity and version in the submitted operation', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(app(TreasuryTransferPage(companyCode: 'C1', selectedBranchCode: 'B1', editItem: record)));
      expect(find.widgetWithText(TextField, '1250.5'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '1400');
      await tester.ensureVisible(find.text('حفظ التعديل'));
      await tester.runAsync(() async {
        await tester.tap(find.text('حفظ التعديل'));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pump();
      expect(posts.single['id'], record['id']);
      expect(posts.single['base_updated_at'], record['updated_at']);
      expect(posts.single['amount'], 1400);
      await finish(tester);
    }, () => client());
  });

  testWidgets('revoking edit while the form is open hides its fields without a POST', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(app(TreasuryTransferPage(companyCode: 'C1', selectedBranchCode: 'B1', editItem: record)));
      expect(find.byType(TextField), findsNWidgets(2));
      PermissionsService().debugSetPermissionsForTest({'تحويلات الخزائن': {'إضافة': true, 'معاينة': true}}, role: 'employee', branches: ['all']);
      PermissionsService().setAllowedBranches(['all']); // Permission snapshot notification.
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('لم تعد لديك صلاحية عرض هذه العملية.'), findsOneWidget);
      expect(posts, isEmpty);
      await finish(tester);
    }, () => client());
  });

  testWidgets('cached treasury opens without GET and relevant refresh updates visible row', (tester) async {
    var calls = 0;
    var rows = [record];
    await http.runWithClient(() async {
      await tester.runAsync(() => TreasuryTransferService().sync('C1'));
      expect(calls, 2);
      await tester.pumpWidget(app(const TreasuryTransfersPage(companyCode: 'C1')));
      await drain(tester);
      expect(calls, 2);
      expect(find.textContaining('تحويل 7'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      rows = [{...record, 'serial': 8, 'amount': 300}];
      await tester.runAsync(() => TreasuryTransferService().refreshRecords('C1'));
      await drain(tester);
      expect(calls, 3);
      expect(find.textContaining('تحويل 8'), findsOneWidget);
      expect(find.textContaining('تحويل 7'), findsNothing);
      await finish(tester);
    }, () => treasuryClient((r) async {
      calls++;
      return http.Response(jsonEncode(r.url.path.contains('/records/') ? rows : []), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  });

  testWidgets('treasury form mobile pixels', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(const TreasuryTransferPage(
        companyCode: 'C1', selectedBranchCode: 'B1')));
    await tester.pump();
    await expectLater(find.byType(TreasuryTransferPage),
        matchesGoldenFile('goldens/treasury_form_mobile.png'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new treasury history narrow mobile pixels', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await http.runWithClient(() async {
      await tester.pumpWidget(app(
          const TreasuryTransfersPage(companyCode: 'C1', branchCode: 'B1')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      await drain(tester);
      expect(find.textContaining('تحويل 7'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(TreasuryTransfersPage),
          matchesGoldenFile('goldens/treasury_history_narrow.png'));
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
      // Hive's broadcast done callback was registered by a fake-async widget
      // listener. Pump it while real file-close I/O also gets time to finish.
      var closed = false;
      Object? closeError;
      Hive.close().then((_) {
        closed = true;
      }, onError: (Object error) {
        closeError = error;
        closed = true;
      });
      for (var i = 0; i < 30 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      expect(closeError, isNull);
      expect(closed, true,
          reason: 'All temporary Hive boxes must close cleanly.');
    },
        () => treasuryClient((r) async => http.Response(
            r.url.path.contains('/records/') ? jsonEncode([record]) : '[]', 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
  });
}

http.Client treasuryClient(Future<http.Response> Function(http.Request) handler) =>
    MockClient((request) async => treasuryProtocol(request, await handler(request)));
