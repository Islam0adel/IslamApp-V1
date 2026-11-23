// Real CommercialService + real local FastAPI routes + SQLite. Fake auth only.
// Opt in with ISLAMAPP_TEST_API=http://127.0.0.1:18765. Never targets a live host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/commercial_service.dart';
import 'package:islam_app/services/stock_balance_service.dart';
import 'package:islam_app/models/inventory_model.dart';
import 'commercial_queue_regression_test.dart' as f;

Map<String, dynamic> sale(String id, int qty) => {
      'id': id,
      'company_code': 'C1',
      'branch_code': 'B1',
      'store_code': 'S1',
      'date': '2026-11-22',
      'serial': 0,
      'items': [
        {'code': 'T1', 'quantity': qty, 'price': 100.0}
      ],
      'subtotal': qty * 100.0,
      'discount': 0.0,
      'total': qty * 100.0,
      'paid': qty * 100.0,
      'due': 0.0,
      'payments': [
        {'treasury': 'TEST', 'amount': qty * 100.0}
      ],
      'employee': 'fixture',
    };
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global =
      null; // Explicit local fixture traffic, no widget network mock.
  final endpoint = Platform.environment['ISLAMAPP_TEST_API'];
  if (endpoint == null) {
    test('local route integration (opt-in)', () {},
        skip:
            'Start validation/local_routes_fixture.py and set ISLAMAPP_TEST_API');
    return;
  }
  final base = Uri.parse(endpoint);
  if (base.host != '127.0.0.1' && base.host != 'localhost')
    throw StateError('Local fixture only');
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory dir;
  final io = HttpClient();
  Future<http.Response> forward(http.Request request) async {
    final req = await io.openUrl(request.method,
        base.replace(path: request.url.path, query: request.url.query));
    request.headers.forEach(req.headers.set);
    req.write(request.body);
    final response = await req.close();
    return http.Response(
        await utf8.decoder.bind(response).join(), response.statusCode);
  }

  Future<List> serverRows() async {
    final req =
        await io.getUrl(base.replace(path: '/commercial/sales/list/C1'));
    final res = await req.close();
    expect(res.statusCode, 200);
    return jsonDecode(await utf8.decoder.bind(res).join()) as List;
  }

  setUp(() async {
    await Hive.close();
    dir = Directory.systemTemp.createTempSync('commercial_integration_');
    Hive.init(dir.path);
    for (final n in [
      ...f.names,
      'inventory_box',
      'supplier_box',
      'coding_box'
    ]) {
      await Hive.openBox(n);
    }
    f.currentUid = 'uid-A';
  });
  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  tearDownAll(() => io.close(force: true));

  test(
      'I1 in-flight edit advances exact version returned by real route, no 409',
      () async {
    final s = CommercialService();
    final entered = Completer<void>();
    final release = Completer<void>();
    final statuses = <int>[];
    final completed = Completer<void>();
    int posts = 0;
    await http.runWithClient(() async {
      await s.save('sales', sale('real-versions', 1));
      // Wait for initial create to finish rather than a fixed sleep.
      for (var n = 0;
          n < 100 && Hive.box('commercial_pending_box').isNotEmpty;
          n++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(Hive.box('commercial_pending_box').isEmpty, true);
      final edit = Map<String, dynamic>.from(f.rec('real-versions')!);
      final next = sale('real-versions', 2)..['serial'] = edit['serial'];
      next['base_updated_at'] = edit['updated_at'];
      await s.save('sales', next);
      await entered.future;
      final latest = sale('real-versions', 5)..['serial'] = edit['serial'];
      latest['base_updated_at'] = f.rec('real-versions')!['updated_at'];
      await s.save('sales', latest);
      release.complete();
      await completed.future;
      for (var n = 0;
          n < 100 && Hive.box('commercial_pending_box').isNotEmpty;
          n++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(statuses, [200, 200, 200]);
      expect(Hive.box('commercial_pending_box').isEmpty, true);
      final row =
          (await serverRows()).singleWhere((r) => r['id'] == 'real-versions');
      expect(row['items'].single['quantity'], 5);
      expect(f.rec('real-versions')!['items'].single['quantity'], 5);
    },
        () => MockClient((request) async {
              final response = await forward(request);
              statuses.add(response.statusCode);
              posts++;
              if (posts == 2) {
                entered.complete();
                await release.future;
              }
              if (posts == 3) completed.complete();
              return response;
            }));
  });

  test('I2 delete after lost create reply reaches real backend', () async {
    final s = CommercialService();
    final committed = Completer<void>();
    bool lose = true;
    await http.runWithClient(() async {
      await s.save('sales', sale('real-lost', 1));
      await committed.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await serverRows()).any((r) => r['id'] == 'real-lost'), true);
      lose = false;
      await s.delete('sales', 'C1', 'real-lost');
      for (var n = 0;
          n < 100 && Hive.box('commercial_pending_box').isNotEmpty;
          n++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(Hive.box('commercial_pending_box').isEmpty, true);
      expect((await serverRows()).any((r) => r['id'] == 'real-lost'), false);
      expect(f.rec('real-lost')!['is_deleted'], true);
    },
        () => MockClient((request) async {
              final response = await forward(request);
              expect(response.statusCode, 200);
              if (lose) {
                committed.complete();
                throw const SocketException('fixture lost reply after commit');
              }
              return response;
            }));
  });
  test(
      'I3 actual stock-event route and local pending version count the record once',
      () async {
    await Hive.box('inventory_box').put('opening', [
      InventoryModel(
        companyCode: 'C1',
        branchCode: 'B1',
        storeCode: 'S1',
        date: '2026-11-20',
        docId: 'opening',
        items: [
          InventoryItem(code: 'OVERLAY', name: 'overlay product', quantity: 10)
        ],
      ).toMap()
    ]);
    final s = CommercialService();
    bool blockEdit = false;
    final rejected = Completer<void>();
    await http.runWithClient(() async {
      final initial = sale('real-stock-overlay', 2);
      initial['items'] = [
        {'code': 'OVERLAY', 'quantity': 2, 'price': 100.0}
      ];
      await s.save('sales', initial);
      for (var n = 0;
          n < 100 && Hive.box('commercial_pending_box').isNotEmpty;
          n++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(Hive.box('commercial_pending_box').isEmpty, true);
      final prior = Map<String, dynamic>.from(f.rec('real-stock-overlay')!);
      blockEdit = true;
      final latest = sale('real-stock-overlay', 3);
      latest['items'] = [
        {'code': 'OVERLAY', 'quantity': 3, 'price': 100.0}
      ];
      latest['serial'] = prior['serial'];
      latest['base_updated_at'] = prior['updated_at'];
      await s.save('sales', latest);
      await rejected.future;
      final stock = await StockBalanceService.calculateBalances(
          companyCode: 'C1',
          branchCode: 'B1',
          storeCode: 'S1',
          toDate: DateTime(2026, 11, 22));
      expect(stock.singleWhere((r) => r['code'] == 'OVERLAY')['quantity'], 7);
      expect(Hive.box('commercial_pending_box').length, 1);
    },
        () => MockClient((r) async {
              if (blockEdit && r.method == 'POST') {
                if (!rejected.isCompleted) rejected.complete();
                return http.Response('injected upload failure', 500);
              }
              return await forward(r);
            }));
  });
}
