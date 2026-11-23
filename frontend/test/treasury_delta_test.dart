import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/treasury_transfer_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  final service = TreasuryTransferService();
  late Directory dir;
  final rights = {
    'تحويلات الخزائن': {'معاينة': true},
    'حركة الخزينة': {'شاشات الارصدة': true}
  };
  Map<String, dynamic> entry(int rev,
          {bool deleted = false, double amount = 20}) =>
      {
        'id': 'key',
        'company_code': 'C1',
        'branch_code': 'B1',
        'revision': rev,
        'is_deleted': deleted,
        'serial': 1,
        'from_treasury': 'A',
        'to_treasury': 'B',
        'amount': amount,
        'date': '2026-11-22'
      };
  http.Response reply(List<Map<String, dynamic>> rows, int cursor,
          {bool reset = false}) =>
      http.Response(
          jsonEncode({
            'protocol': 2,
            'mode': 'records',
            'company_code': 'C1',
            'scope': 'scope',
            'reset': reset,
            'cursor': cursor,
            'items': rows
          }),
          200);
  dynamic cache() => Hive.box(TreasuryTransferService.recordsBox)
      .get(jsonEncode(['uid-A', 'C1']));
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('treasury_delta_');
    Hive.init(dir.path);
    await Hive.openBox(TreasuryTransferService.effectsBox);
    await Hive.openBox(TreasuryTransferService.recordsBox);
    f.currentUid = 'uid-A';
    PermissionsService().debugSetPermissionsForTest(rights,
        role: 'employee', branches: ['all']);
  });
  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  test(
      'record delta, reordered and duplicate events, delete without GET or cursor jump',
      () async {
    var calls = 0;
    await http.runWithClient(() async {
      await service.refreshRecords('C1');
      await service.applyEvent(entry(3, amount: 5), effects: false);
      await service.applyEvent(entry(2), effects: false);
      await service.applyEvent(entry(3, amount: 5), effects: false);
      expect(calls, 1);
      expect(cache()['cursor'], 1);
      expect(service.localRecords('C1').single['amount'], 5);
      await service.refreshRecords('C1');
      expect(service.localRecords('C1').single['amount'], 5);
      await service.applyEvent(entry(4, deleted: true), effects: false);
      await service.applyEvent(entry(3), effects: false);
      expect(service.localRecords('C1'), isEmpty);
    },
        () => MockClient((r) async {
              calls++;
              expect(r.url.path, contains('/changes/records/'));
              if (calls == 1) return reply([entry(1)], 1, reset: true);
              expect(r.url.queryParameters['cursor'], '1');
              return reply([entry(2)], 2);
            }));
  });
  test('HTTP response preserves concurrent newer events and independent IDs',
      () async {
    var calls = 0;
    final started = Completer<void>();
    final release = Completer<void>();
    await http.runWithClient(() async {
      await service.refreshRecords('C1');
      final refresh = service.refreshRecords('C1');
      await started.future;
      await Future.wait([
        service.applyEvent(entry(3, amount: 5), effects: false),
        service.applyEvent({...entry(4), 'id': 'second', 'serial': 2},
            effects: false)
      ]);
      release.complete();
      await refresh;
      expect(cache()['cursor'], 2);
      expect(service.localRecords('C1').length, 2);
      expect(service.localRecords('C1').last['amount'], 5);
    },
        () => MockClient((r) async {
              calls++;
              if (calls == 1) return reply([entry(1)], 1, reset: true);
              started.complete();
              await release.future;
              return reply([entry(2)], 2);
            }));
  });
  test(
      'cross-company/invalid delta fails without checkpoint advance, reset clears future tombstone',
      () async {
    var calls = 0;
    await http.runWithClient(() async {
      await service.refreshRecords('C1');
      await service.applyEvent(entry(8, deleted: true), effects: false);
      await service.refreshRecords('C1');
      expect(service.localRecords('C1').length, 1);
      await expectLater(service.refreshRecords('C1'), throwsFormatException);
      expect(cache()['cursor'], 1);
      expect(service.localRecords('C1').length, 1);
    },
        () => MockClient((r) async {
              calls++;
              if (calls == 3)
                return reply([
                  {...entry(3), 'company_code': 'C2'}
                ], 3);
              return reply([entry(1)], 1, reset: true);
            }));
  });
  test(
      'legacy record snapshot requires baseline and replaces without duplicate',
      () async {
    await Hive.box(TreasuryTransferService.recordsBox)
        .put(jsonEncode(['uid-A', 'C1']), {
      'owner_uid': 'uid-A',
      'company_code': 'C1',
      'records': [entry(0, amount: 99)]
    });
    await http.runWithClient(() async {
      expect(
          service.hasSnapshot(TreasuryTransferService.recordsBox, 'C1'), false);
      await service.refreshRecords('C1');
      expect(service.localRecords('C1').single['amount'], 20);
    },
        () => MockClient((r) async {
              expect(r.url.queryParameters['cursor'], '0');
              return reply([entry(7)], 7, reset: true);
            }));
  });
  test(
      'effects use original full authoritative five-field snapshot and no per-transfer re-sum',
      () async {
    var calls = 0;
    final huge = 100000000000000.02;
    final aggregate = [
      {
        'company_code': 'C1',
        'branch_code': 'B1',
        'date': '2026-11-22',
        'treasury': 'A',
        'signed_amount': -huge
      },
      {
        'company_code': 'C1',
        'branch_code': 'B1',
        'date': '2026-11-22',
        'treasury': 'B',
        'signed_amount': huge
      }
    ];
    await http.runWithClient(() async {
      await service.refreshEffects('C1');
      expect(service.balanceEffects('C1'), {'A': -huge, 'B': huge});
      expect(
          service.hasSnapshot(TreasuryTransferService.effectsBox, 'C1'), true);
      await service.applyEvent({'company_code': 'C1', 'branch_code': 'B1'},
          effects: true);
      expect(calls, 2);
      expect(service.balanceEffects('C1')['B']!.toStringAsFixed(2),
          '100000000000000.02');
      final stored = Hive.box(TreasuryTransferService.effectsBox)
          .get(jsonEncode(['uid-A', 'C1']));
      expect(stored['records'], aggregate);
      expect(stored.containsKey('entries'), false);
    },
        () => MockClient((r) async {
              calls++;
              expect(r.url.path, endsWith('/effects/C1'));
              return http.Response(jsonEncode(aggregate), 200);
            }));
  });
}
