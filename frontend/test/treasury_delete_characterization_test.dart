import 'treasury_protocol_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/views/dashboard/daily_history_page.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('treasury_delete_');
    Hive.init(dir.path);
    await Hive.openBox('daily_transactions_box');
    await Hive.openBox('coding_box');
    PermissionsService().debugSetPermissionsForTest(
        {
          'حركة الخزينة': {'المعاينة': true, 'الحذف': true, 'التعديل': false}
        },
        role: 'admin',
        branches: ['all']);
  });
  tearDownAll(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  testWidgets(
      'legacy transfer cannot invoke guessed counterpart deletion',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    final box = Hive.box('daily_transactions_box');
    final date = DateTime.now().toIso8601String().substring(0, 10);
    Map<String, dynamic> tx(int serial, String branch, String type,
            String treasury, String statement) =>
        {
          'company_code': 'C1',
          'branch_code': branch,
          'serial': serial,
          'date': date,
          'amount': 100.0,
          'type': type,
          'treasury': treasury,
          'statement': statement,
          'category': 'تحويل خزائن',
          'employee': 'test',
          'is_deleted': false,
        };
    await tester.runAsync(() async {
      await box.put(
          'branch_B1_1', tx(1, 'B1', 'صادر', 'A', 'intended transfer (إلى B)'));
      await box.put('branch_B0_50',
          tx(50, 'B0', 'وارد', 'Y', 'unrelated transfer (من X)'));
      await box.put(
          'branch_B1_2', tx(2, 'B1', 'وارد', 'B', 'intended transfer (من A)'));
    });
    final deletes = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: DailyHistoryPage(companyCode: 'C1', selectedBranchCode: 'B1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اذن: 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف الإذن'));
      await tester.pumpAndSettle();
      expect(deletes,isEmpty);
      expect(box.containsKey('branch_B1_1'),true);
      expect(box.containsKey('branch_B1_2'),true);
      expect(box.containsKey('branch_B0_50'),true);
      expect(find.textContaining('ولا تُحذف كأذون يومية'),findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => treasuryClient((r) async {
              if (r.method == 'DELETE') {
                deletes.add(r.url.path);
                return http.Response(jsonEncode({'status': 'success'}), 200);
              }
              return http.Response('[]', 200);
            }));
    await tester.binding.setSurfaceSize(null);
  });
}

http.Client treasuryClient(Future<http.Response> Function(http.Request) handler) =>
    MockClient((request) async => treasuryProtocol(request, await handler(request)));
