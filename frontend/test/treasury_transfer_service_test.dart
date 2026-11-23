import 'treasury_protocol_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/treasury_transfer_service.dart';
import 'package:islam_app/services/treasury_cache_scope.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/daily_service.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  final service = TreasuryTransferService();
  final permissions = PermissionsService();
  late Directory dir;
  const boxes = [
    TreasuryTransferService.recordsBox,
    TreasuryTransferService.effectsBox,
    'daily_transactions_box',
    'coding_box'
  ];
  final rights = <String, dynamic>{
    'تحويلات الخزائن': {'معاينة': true},
    'حركة الخزينة': {'شاشات الارصدة': true}
  };
  Map<String, dynamic> effect(String treasury, double amount,
          {String branch = 'B1',
          String company = 'C1',
          String date = '2026-11-22'}) =>
      {
        'company_code': company,
        'branch_code': branch,
        'date': date,
        'treasury': treasury,
        'signed_amount': amount
      };
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('treasury_independent_');
    Hive.init(dir.path);
    for (final box in boxes) {
      await Hive.openBox(box);
    }
  });
  setUp(() async {
    f.currentUid = 'uid-A';
    for (final box in boxes) {
      await Hive.box(box).clear();
    }
    permissions.debugSetPermissionsForTest(rights,
        role: 'employee', branches: ['all']);
  });
  tearDownAll(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('verified empty snapshots prevent repeated page-open requests; refresh stays explicit', () async {
    var calls = 0;
    await http.runWithClient(() async {
      await service.ensureCached('C1');
      expect(calls, 2);
      expect(service.hasSnapshot(TreasuryTransferService.recordsBox, 'C1'), true);
      await service.ensureCached('C1');
      expect(calls, 2);
      await service.sync('C1');
      expect(calls, 4);
      permissions.debugSetPermissionsForTest(rights, role: 'employee', branches: ['B2']);
      await service.ensureCached('C1');
      expect(calls, 6);
      f.currentUid = 'uid-B';
      await service.ensureCached('C1');
      expect(calls, 8);
    }, () => treasuryClient((r) async { calls++; return http.Response('[]', 200); }));
  });

  test('independent effects change balances exactly once, no journal turnover',
      () async {
    final journal = Hive.box('daily_transactions_box');
    await Hive.box('coding_box').put('C1_safes', [
      {'name': 'A'},
      {'name': 'B'}
    ]);
    await journal.put('opening', {
      'company_code': 'C1',
      'branch_code': 'B1',
      'serial': 1,
      'type': 'وارد',
      'treasury': 'A',
      'amount': 200
    });
    await http.runWithClient(() async {
      await service.refreshEffects('C1');
      await service.refreshEffects('C1');
      final result =
          await DailyService().getDailySummaryLocal('C1', branchCode: 'B1');
      expect(result['balances'], {'A': 170.0, 'B': 30.0});
      expect(
          journal.values
              .whereType<Map>()
              .where((r) => r.containsKey('type'))
              .length,
          1);
      expect(journal.get('opening')['amount'], 200);
    },
        () => treasuryClient((_) async => http.Response(
            jsonEncode([effect('A', -30), effect('B', 30)]), 200)));
  });

  test('company, branch and date filters isolate derived effects', () async {
    permissions
        .debugSetPermissionsForTest(rights, role: 'employee', branches: ['B1']);
    await http.runWithClient(() async {
      await service.refreshEffects('C1');
      expect(service.balanceEffects('C1'), {'A': -12.0});
      expect(service.balanceEffects('C2'), isEmpty);
      expect(service.balanceEffects('C1', branchCode: 'B2'), isEmpty);
      expect(service.balanceEffects('C1', fromDate: DateTime(2026, 11, 23)),
          isEmpty);
    },
        () => treasuryClient((_) async => http.Response(
            jsonEncode([
              effect('A', -12),
              effect('A', -80, branch: 'B2'),
              effect('A', -90, company: 'C2')
            ]),
            200)));
  });

  test('balance-only permission never requests or exposes raw records',
      () async {
    permissions.debugSetPermissionsForTest(
        {
          'التقارير': {'تحليل الخزائن النقدية': true}
        },
        role: 'employee',
        branches: ['all']);
    final paths = <String>[];
    await http.runWithClient(() async {
      await service.sync('C1');
      expect(service.localRecords('C1'), isEmpty);
      expect(service.balanceEffects('C1'), {'A': -10.0});
      expect(paths.length, 1);
      expect(paths.single, contains('/effects/'));
    },
        () => treasuryClient((r) async {
              paths.add(r.url.path);
              return http.Response(jsonEncode([effect('A', -10)]), 200);
            }));
  });

  test('auth switch during GET cannot populate another owner cache', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    await http.runWithClient(() async {
      final fetch = service.refreshEffects('C1');
      await started.future;
      f.currentUid = 'uid-B';
      gate.complete();
      expect(await fetch, isEmpty);
      expect(Hive.box(TreasuryTransferService.effectsBox).isEmpty, true);
      expect(service.balanceEffects('C1'), isEmpty);
    },
        () => treasuryClient((r) async {
              started.complete();
              await gate.future;
              return http.Response(jsonEncode([effect('A', -10)]), 200);
            }));
  });

  test('successful save is not reported as failed when refresh fails',
      () async {
    final id = service.newId();
    expect(id.length, 36);
    var writes = 0;
    await http.runWithClient(() async {
      final result = await service.save({'id': id, 'company_code': 'C1'});
      expect(result['status'], 'success');
      expect(result['refresh_pending'], true);
      expect(writes, 1);
    },
        () => treasuryClient((r) async {
              if (r.method == 'POST') {
                writes++;
                return http.Response(
                    jsonEncode({
                      'status': 'success',
                      'record': {'id': id, 'company_code': 'C1'}
                    }),
                    200);
              }
              return http.Response('injected refresh failure', 500);
            }));
  });

  test('permission and branch revocation removes only this owner and company',
      () async {
    final box = Hive.box(TreasuryTransferService.effectsBox);
    for (final owner in ['uid-A', 'uid-B']) {
      await box.put(jsonEncode([owner, 'C1']), {
        'owner_uid': owner,
        'company_code': 'C1',
        'records': [effect('A', -10), effect('A', -20, branch: 'B2')]
      });
    }
    await box.put('other-company', {
      'owner_uid': 'uid-A',
      'company_code': 'C2',
      'records': [effect('A', -70, company: 'C2')]
    });
    expect(
        await TreasuryCacheScope.apply(
            company: 'C1',
            ownerUid: 'uid-A',
            permissions: rights,
            branches: ['B1']),
        true);
    expect((box.get(jsonEncode(['uid-A', 'C1']))['records'] as List).length, 1);
    expect((box.get(jsonEncode(['uid-B', 'C1']))['records'] as List).length, 2);
    await TreasuryCacheScope.apply(
        company: 'C1', ownerUid: 'uid-A', permissions: {}, branches: ['all']);
    expect(box.containsKey(jsonEncode(['uid-A', 'C1'])), false);
    expect(box.containsKey(jsonEncode(['uid-B', 'C1'])), true);
    expect(box.containsKey('other-company'), true);
  });

  test(
      'same-snapshot reads serialize instead of late old reply replacing fresh',
      () async {
    var calls = 0;
    var active = 0;
    var maxActive = 0;
    await http.runWithClient(() async {
      await Future.wait(
          [service.refreshEffects('C1'), service.refreshEffects('C1')]);
      expect(maxActive, 1);
      expect(service.balanceEffects('C1'), {'A': -2.0});
    },
        () => treasuryClient((r) async {
              calls++;
              active++;
              if (active > maxActive) maxActive = active;
              final n = calls;
              await Future<void>.delayed(const Duration(milliseconds: 10));
              active--;
              return http.Response(
                  jsonEncode([effect('A', -n.toDouble())]), 200);
            }));
  });
  test('effect snapshot is projected to the five calculator fields', () async {
    await http.runWithClient(() async {
      await service.refreshEffects('C1');
      final envelope =
          Hive.box(TreasuryTransferService.effectsBox).values.single as Map;
      final row = (envelope['records'] as List).single as Map;
      expect(row.keys.toSet(),
          {'company_code', 'branch_code', 'date', 'treasury', 'signed_amount'});
    },
        () => treasuryClient((_) async => http.Response(
            jsonEncode([
              {
                ...effect('A', -5),
                'employee': 'private',
                'statement': 'private',
                'id': 'raw-id'
              }
            ]),
            200)));
  });
  test('reset replaces only the current account and company snapshots',
      () async {
    final box = Hive.box(TreasuryTransferService.effectsBox);
    for (final pair in [
      ['uid-A', 'C1'],
      ['uid-B', 'C1'],
      ['uid-A', 'C2']
    ]) {
      await box.put(jsonEncode(pair), {
        'owner_uid': pair[0],
        'company_code': pair[1],
        'records': [effect('A', -90, company: pair[1])]
      });
    }
    await http.runWithClient(() async {
      await service.reset('C1');
      expect(service.balanceEffects('C1'), {'A': -5.0});
      expect(
          (box.get(jsonEncode(['uid-B', 'C1']))['records'] as List)
              .single['signed_amount'],
          -90.0);
      expect(
          (box.get(jsonEncode(['uid-A', 'C2']))['records'] as List)
              .single['signed_amount'],
          -90.0);
    },
        () => treasuryClient((r) async => http.Response(
            r.url.path.contains('/effects/')
                ? jsonEncode([effect('A', -5)])
                : '[]',
            200)));
  });
  test('presentation switches alone never grant derived effect access',
      () async {
    await Hive.box(TreasuryTransferService.effectsBox)
        .put(jsonEncode(['uid-A', 'C1']), {
      'owner_uid': 'uid-A',
      'company_code': 'C1',
      'records': [effect('A', -10)]
    });
    permissions.debugSetPermissionsForTest({
      'حركة الخزينة': {'شاشات الارصدة': false},
      'صلاحيات عامة': {'إظهار حركة الخزينة': true}
    }, role: 'employee');
    expect(permissions.canReadTreasuryEffects, false);
    expect(service.balanceEffects('C1'), isEmpty);
    var requests = 0;
    await http.runWithClient(() async {
      await service.refreshEffects('C1');
    },
        () => treasuryClient((r) async {
              requests++;
              return http.Response('[]', 200);
            }));
    expect(requests, 0);
    expect(Hive.box(TreasuryTransferService.effectsBox).isEmpty, true);
  });
  test('a mismatched saved amount is not accepted as confirmed success',
      () async {
    await http.runWithClient(() async {
      await expectLater(
          service.save({'id': 'T1', 'company_code': 'C1', 'amount': 100.0}),
          throwsFormatException);
    },
        () => treasuryClient((r) async => http.Response(
            jsonEncode({
              'status': 'success',
              'record': {'id': 'T1', 'company_code': 'C1', 'amount': 1.0}
            }),
            200)));
  });
}

http.Client treasuryClient(Future<http.Response> Function(http.Request) handler) =>
    MockClient((request) async => treasuryProtocol(request, await handler(request)));
