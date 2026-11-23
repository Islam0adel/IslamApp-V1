import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/models/inventory_model.dart';
import 'package:islam_app/services/commercial_service.dart';
import 'package:islam_app/services/stock_balance_service.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('stock_overlay_');
    Hive.init(dir.path);
    for (final name in [
      'inventory_box',
      'supplier_box',
      'coding_box',
      'sales_box',
      'sales_returns_box',
      'stock_transfers_box',
      'commercial_stock_events_box',
      'commercial_pending_box'
    ]) {
      await Hive.openBox(name);
    }
  });
  setUp(() async {
    for (final name in [
      'inventory_box',
      'supplier_box',
      'coding_box',
      'sales_box',
      'sales_returns_box',
      'stock_transfers_box',
      'commercial_stock_events_box',
      'commercial_pending_box'
    ]) {
      await Hive.box(name).clear();
    }
    await Hive.box('inventory_box').put('opening', [
      InventoryModel(
        companyCode: 'C1',
        branchCode: 'B1',
        storeCode: 'S1',
        date: '2026-11-20',
        docId: 'opening',
        items: [InventoryItem(code: 'P1', name: 'product', quantity: 10)],
      ).toMap()
    ]);
  });
  tearDownAll(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  for (final kind in ['sales', 'returns']) {
    test('$kind pending edit replaces the same snapshot record exactly once',
        () async {
      final old = {
        'id': 'same-record',
        'company_code': 'C1',
        'branch_code': 'B1',
        'store_code': 'S1',
        'date': '2026-11-21',
        'serial': 1,
        'sync_status': 'synced',
        'items': [
          {'code': 'P1', 'quantity': 2.0}
        ]
      };
      final localBox =
          Hive.box(kind == 'sales' ? 'sales_box' : 'sales_returns_box');
      await localBox.put('C1_B1_day', [old]);
      final requests = <String>[];
      await http.runWithClient(() async {
        await CommercialService().save(kind, {
          ...old,
          'items': [
            {'code': 'P1', 'quantity': 3.0}
          ]
        });
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final result = await StockBalanceService.calculateBalances(
            companyCode: 'C1',
            branchCode: 'B1',
            storeCode: 'S1',
            toDate: DateTime(2026, 11, 22));
        final quantity = result.single['quantity'];
        // One edited record contributes 3 exactly once.
        expect(quantity, kind == 'sales' ? 7.0 : 13.0);
        expect(requests.any((p) => p.endsWith('/stock-events/C1')), true);
        expect(Hive.box('commercial_pending_box').length, 1);
      },
          () => MockClient((r) async {
                requests.add(r.url.path);
                if (r.method == 'POST')
                  return http.Response('injected save failure', 500);
                return http.Response(
                    jsonEncode([
                      {
                        'id': 'same-record',
                        'company_code': 'C1',
                        'branch_code': 'B1',
                        'store_code': 'S1',
                        'date': '2026-11-21',
                        'event_type': kind == 'sales' ? 'sale' : 'return',
                        'positive': kind == 'returns',
                        'items': [
                          {'code': 'P1', 'quantity': 2.0}
                        ],
                      }
                    ]),
                    200);
              }));
    });
  }
  Map<String, dynamic> snapshot(String type,
          {String id = 'same-record', String store = 'S1', double qty = 2}) =>
      {
        'id': id,
        'company_code': 'C1',
        'branch_code': 'B1',
        'store_code': store,
        'date': '2026-11-21',
        'event_type': type,
        'positive': type == 'return' || type == 'transfer_in',
        'items': [
          {'code': 'P1', 'quantity': qty}
        ],
      };
  Map<String, dynamic> local(
          {String id = 'same-record',
          String company = 'C1',
          String store = 'S1',
          String date = '2026-11-21',
          String status = 'pending',
          bool deleted = false}) =>
      {
        'id': id,
        'company_code': company,
        'branch_code': 'B1',
        'store_code': store,
        'date': date,
        'sync_status': status,
        'is_deleted': deleted,
        'items': [
          {'code': 'P1', 'quantity': 3.0}
        ],
      };
  Future<double> calculate(List<Map<String, dynamic>> events,
      {String store = 'S1', DateTime? day, bool offline = false}) async {
    return await http.runWithClient(() async {
      final rows = await StockBalanceService.calculateBalances(
          companyCode: 'C1',
          branchCode: 'B1',
          storeCode: store,
          toDate: day ?? DateTime(2026, 11, 22));
      return rows.isEmpty ? 0 : (rows.single['quantity'] as num).toDouble();
    },
        () => MockClient((r) async => http.Response(
            offline ? 'unavailable' : jsonEncode(events),
            offline ? 500 : 200)));
  }

  test('same id in return and sale is not the same event type', () async {
    await Hive.box('sales_returns_box').put('C1_B1_day', [local()]);
    expect(await calculate([snapshot('sale')]), 11);
  });
  test('same id in another company does not mask this company snapshot',
      () async {
    await Hive.box('sales_box').put('C2_B1_day', [local(company: 'C2')]);
    expect(await calculate([snapshot('sale')]), 8);
  });
  test('pending date move removes the old version before date filtering',
      () async {
    await Hive.box('sales_box').put('C1_B1_day', [local(date: '2026-11-23')]);
    expect(await calculate([snapshot('sale')]), 10);
    expect(await calculate([snapshot('sale')], day: DateTime(2026, 11, 23)), 7);
  });
  test(
      'pending store move removes the old source without affecting unrelated events',
      () async {
    await Hive.box('sales_box').put('C1_B1_day', [local(store: 'S2')]);
    expect(
        await calculate(
            [snapshot('sale'), snapshot('sale', id: 'unrelated', qty: 1)]),
        9);
    expect(await calculate([snapshot('sale')], store: 'S2'), -3);
  });
  test('pending transfer replaces both directional event ids', () async {
    await Hive.box('stock_transfers_box').put('C1_B1_day', [
      {
        ...local(),
        'from_branch_code': 'B1',
        'from_store_code': 'S1',
        'to_branch_code': 'B1',
        'to_store_code': 'S2',
      }
    ]);
    final events = [
      snapshot('transfer_out', id: 'same-record:transfer_out'),
      snapshot('transfer_in', id: 'same-record:transfer_in', store: 'S2')
    ];
    expect(await calculate(events), 7);
    expect(await calculate(events, store: 'S2'), 3);
  });
  for (final status in ['conflict', 'synced']) {
    test('$status policy unchanged: local row does not replace snapshot',
        () async {
      await Hive.box('sales_box').put('C1_B1_day', [local(status: status)]);
      expect(await calculate([snapshot('sale')]), 8);
    });
  }
  test('pending delete policy unchanged: no unapproved stock reversal',
      () async {
    await Hive.box('sales_box').put('C1_B1_day', [local(deleted: true)]);
    expect(await calculate([snapshot('sale')]), 8);
  });
  test('without a snapshot the existing local fallback counts the row once',
      () async {
    await Hive.box('sales_box').put('C1_B1_day', [local()]);
    expect(await calculate([], offline: true), 7);
  });
  test('fresh empty snapshot still includes local pending creation', () async {
    await Hive.box('sales_box').put('C1_B1_day', [local()]);
    expect(await calculate([]), 7);
  });
  test('acknowledged server creation with lost reply is not counted twice',
      () async {
    final row = local();
    row['items'] = [
      {'code': 'P1', 'quantity': 2.0}
    ];
    await Hive.box('sales_box').put('C1_B1_day', [row]);
    expect(await calculate([snapshot('sale')]), 8);
  });
  test('a moved branch removes only the old version in the viewed branch',
      () async {
    await Hive.box('sales_box').put('C1_B2_day', [
      {...local(), 'branch_code': 'B2'}
    ]);
    expect(await calculate([snapshot('sale')]), 10);
  });
  test(
      'general inventory ordering and historical price equations stay unchanged',
      () async {
    await Hive.box('inventory_box').put('later-count', [
      InventoryModel(
        companyCode: 'C1',
        branchCode: 'B1',
        storeCode: 'S1',
        date: '2026-11-22',
        docId: 'later-count',
        items: [
          InventoryItem(
              code: 'P1',
              name: 'product',
              quantity: 4,
              wholesalePrice: 9,
              retailPrice: 12)
        ],
      ).toMap()
    ]);
    await Hive.box('sales_box').put('C1_B1_day', [local(date: '2026-11-22')]);
    final result = await http.runWithClient(
        () => StockBalanceService.calculateBalances(
            companyCode: 'C1',
            branchCode: 'B1',
            storeCode: 'S1',
            toDate: DateTime(2026, 11, 22)),
        () => MockClient((r) async => http.Response(
            jsonEncode([
              {...snapshot('sale'), 'date': '2026-11-22'}
            ]),
            200)));
    expect(result.single['quantity'], 1);
    expect(result.single['wholesalePrice'], 9);
    expect(result.single['sellingPrice'], 12);
    expect(result.single['totalWholesale'], 9);
    expect(result.single['totalRetail'], 12);
  });
}
