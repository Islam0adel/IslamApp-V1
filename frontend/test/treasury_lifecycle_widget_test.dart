import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/treasury_transfer_service.dart';
import 'package:islam_app/views/dashboard/daily_page.dart';
import 'package:islam_app/views/dashboard/advanced_reports_page.dart';
import 'package:islam_app/views/dashboard/reports_page.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory dir;
  const names = [
    'daily_transactions_box',
    'journal_save_intents_box',
    'coding_box',
    'supplier_settlement_box',
    TreasuryTransferService.recordsBox,
    TreasuryTransferService.effectsBox
  ];
  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('treasury_lifecycle_');
    Hive.init(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    f.currentUid = 'uid-A';
    for (final name in names) {
      await Hive.openBox(name);
      await Hive.box(name).clear();
    }
    PermissionsService().debugSetPermissionsForTest(
        {
          'حركة الخزينة': {'شاشات الارصدة': true, 'المعاينة': true},
          'التقارير': {'تحليل الخزائن النقدية': true, 'تقرير فترة': true},
        },
        role: 'employee',
        branches: ['all']);
    final coding = Hive.box('coding_box');
    await coding.put('C1_safes', [
      {'code': '1', 'name': 'A'},
      {'code': '2', 'name': 'B'}
    ]);
    await coding.put('C1_types', [
      {'code': '1', 'name': 'Income', 'type': 'وارد'}
    ]);
    await coding.put('C1_suppliers', [
      {'name': 'Supplier'}
    ]);
    await Hive.box('daily_transactions_box').put('opening', {
      'company_code': 'C1',
      'branch_code': 'B1',
      'serial': 1,
      'type': 'وارد',
      'category': 'Income',
      'treasury': 'A',
      'amount': 200.0,
      'date': '2026-11-22',
      'statement': 'opening'
    });
  });
  tearDownAll(() {
    dir.deleteSync(recursive: true);
  });
  Future<void> effects(WidgetTester tester, double amount) async {
    await tester.runAsync(() async {
      await Hive.box(TreasuryTransferService.effectsBox)
          .put(jsonEncode(['uid-A', 'C1']), {
        'owner_uid': 'uid-A',
        'company_code': 'C1',
        'records': [
          {
            'company_code': 'C1',
            'branch_code': 'B1',
            'date': '2026-11-22',
            'treasury': 'A',
            'signed_amount': -amount
          },
          {
            'company_code': 'C1',
            'branch_code': 'B1',
            'date': '2026-11-22',
            'treasury': 'B',
            'signed_amount': amount
          },
        ]
      });
    });
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await drain(tester);
    var done = false;
    Object? error;
    Hive.close().then((_) {
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    });
    for (var i = 0; i < 30 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(error, isNull);
    expect(done, true);
  }

  testWidgets(
      'active daily balance screen updates on independent effect snapshot',
      (tester) async {
    await effects(tester, 10);
    await tester.pumpWidget(const MaterialApp(
        home: DailyPage(companyCode: 'C1', selectedBranchCode: 'B1')));
    await drain(tester);
    expect(find.text('190.00'), findsOneWidget);
    expect(find.text('10.00'), findsOneWidget);
    await effects(tester, 30);
    await drain(tester);
    expect(find.text('170.00'), findsOneWidget);
    expect(find.text('30.00'), findsOneWidget);
    expect(find.text('190.00'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets(
      'active treasury analysis updates effects but preserves net total',
      (tester) async {
    await effects(tester, 10);
    await tester.pumpWidget(MaterialApp(
        home: AdvancedReportsPage(
            companyCode: 'C1',
            selectedBranchCode: 'B1',
            reportId: 5,
            fromDate: DateTime(2026, 11, 1),
            toDate: DateTime(2026, 11, 30))));
    await drain(tester);
    expect(find.text('190.00'), findsWidgets);
    await effects(tester, 30);
    await drain(tester);
    expect(find.text('170.00'), findsWidgets);
    expect(find.text('30.00'), findsWidgets);
    expect(find.text('190.00'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets('period gross totals do not include independent transfers',
      (tester) async {
    await effects(tester, 30);
    await tester.pumpWidget(const MaterialApp(
        home: ReportsPage(
            companyCode: 'C1',
            selectedBranchCode: 'B1',
            initialReportType: 2)));
    await drain(tester);
    expect(find.textContaining('200.00'), findsWidgets);
    expect(find.textContaining('230.00'), findsNothing);
    expect(find.text('30.00'), findsNothing);
    expect(
        Hive.box('daily_transactions_box')
            .values
            .whereType<Map>()
            .where((r) => r.containsKey('type'))
            .length,
        1);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
