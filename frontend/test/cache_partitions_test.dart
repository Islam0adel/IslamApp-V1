import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/cache_partitions.dart';
import 'package:islam_app/services/commercial_service.dart';
import 'package:islam_app/services/company_service.dart';
import 'package:islam_app/services/hr_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/revocation_service.dart';
import 'package:islam_app/services/journal_save_intent.dart';
import 'package:islam_app/services/journal_import_batch.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'commercial_queue_regression_test.dart' as fake;
import 'hr_notification_audience_test.dart' as socket;
import 'package:islam_app/services/websocket_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  Future<void> enter(String uid, [String company = 'C1']) async {
    CachePartitions.suspend();
    fake.currentUid = uid;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('company_code', company);
    await CachePartitions.activate(uid, company);
  }

  setUpAll(() async {
    FirebasePlatform.instance = fake.FakeCore();
    FirebaseAuthPlatform.instance = fake.FakeAuth();
    dir = Directory.systemTemp.createTempSync('partition_');
    Hive.init(dir.path);
    SharedPreferences.setMockInitialValues({'company_code': 'C1'});
    CachePartitions.enable();
  });
  tearDownAll(() async {
    CachePartitions.suspend();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  setUp(() async {
    await enter('uid-A');
    for (final name in CachePartitions.boxes) {
      await CachePartitions.box(name).clear();
    }
  });
  test('A B A actual local commercial read never sees another owner', () async {
    final service = CommercialService();
    await CachePartitions.box('sales_box').put('C1_B2_2026-11-23', [
      {
        'id': 'a-secret',
        'company_code': 'C1',
        'branch_code': 'B2',
        'sync_status': 'synced'
      }
    ]);
    expect((await service.fetch('sales', 'C1')).single['id'], 'a-secret');
    await enter('uid-B');
    await CachePartitions.box('sales_box').clear();
    expect(await service.fetch('sales', 'C1'), isEmpty);
    await CachePartitions.box('sales_box').put('C1_B1_2026-11-23', [
      {
        'id': 'b-only',
        'company_code': 'C1',
        'branch_code': 'B1',
        'sync_status': 'synced'
      }
    ]);
    await enter('uid-A');
    expect((await service.fetch('sales', 'C1')).single['id'], 'a-secret');
    await enter('uid-B');
    expect((await service.fetch('sales', 'C1')).single['id'], 'b-only');
  });
  test(
      'company partitions and cursor metadata return warm, no global cursor reuse',
      () async {
    final raw = await SharedPreferences.getInstance();
    await raw.setString('last_sync_daily_C1', 'unsafe-legacy');
    var prefs = await CachePartitions.preferences();
    expect(prefs.getString('last_sync_daily_C1'), isNull);
    await prefs.setString('last_sync_daily_C1', 'A1');
    await CachePartitions.box('coding_box').put('C1_branches', [
      {'code': 'A1'}
    ]);
    await enter('uid-A', 'C2');
    expect(CachePartitions.box('coding_box').isEmpty, isTrue);
    await (await CachePartitions.preferences())
        .setString('last_sync_daily_C1', 'A2');
    await enter('uid-A');
    expect(
        (await CachePartitions.preferences()).getString('last_sync_daily_C1'),
        'A1');
    expect(CachePartitions.box('coding_box').get('C1_branches'), isNotNull);
    expect(raw.getString('last_sync_daily_C1'), 'unsafe-legacy');
  });
  test(
      'retained Box and async zone cannot write or read after switch, including ABA',
      () async {
    final box = CachePartitions.box('coding_box');
    final prefs = await CachePartitions.preferences();
    final gate = Completer<void>();
    final future = CachePartitions.run(() async {
      await gate.future;
      await CachePartitions.box('coding_box').put('late', 'bad');
    });
    final expected = expectLater(future, throwsStateError);
    await enter('uid-B');
    await enter('uid-A');
    gate.complete();
    await expected;
    expect(() => box.get('anything'), throwsStateError);
    expect(() => prefs.getString('last_sync_daily_C1'), throwsStateError);
    expect(CachePartitions.box('coding_box').get('late'), isNull);
  });
  test(
      'logout and unexpected auth changes fail closed before preference cleanup',
      () async {
    final box = CachePartitions.box('coding_box');
    fake.currentUid = 'uid-B';
    expect(() => box.values.toList(), throwsStateError);
    expect(() => CachePartitions.box('coding_box'), throwsStateError);
    await enter('uid-A');
    CachePartitions.suspend();
    expect(() => CachePartitions.box('coding_box'), throwsStateError);
  });
  test('late actual commercial GET never merges into B, nor restored A',
      () async {
    final gate = Completer<void>(), started = Completer<void>();
    await http.runWithClient(() async {
      final work = CommercialService().fetch('sales', 'C1', forceRefresh: true);
      final caught = expectLater(work, throwsStateError);
      await started.future;
      await enter('uid-B');
      await enter('uid-A');
      gate.complete();
      await caught;
      expect(await CommercialService().fetch('sales', 'C1'), isEmpty);
    },
        () => MockClient((_) async {
              started.complete();
              await gate.future;
              return http.Response(
                  jsonEncode([
                    {'id': 'late', 'company_code': 'C1', 'branch_code': 'B1'}
                  ]),
                  200);
            }));
  });
  test('late actual singleton company fetch cannot poison the next account',
      () async {
    final gate = Completer<void>(), started = Completer<void>();
    await http.runWithClient(() async {
      PermissionsService().debugSetPermissionsForTest({}, role: 'super_admin', loaded: true);
      final work = CompanyService().fetchAllCompanies();
      final caught = expectLater(work, throwsStateError);
      await started.future;
      await enter('uid-B');
      gate.complete();
      await caught;
      expect(CompanyService().getCompaniesFromHive(), isEmpty);
    },
        () => MockClient((_) async {
              started.complete();
              await gate.future;
              return http.Response('[{"code":"secret"}]', 200);
            }));
  });
  test('old listeners stop and do not revive after A B A', () async {
    var events = 0;
    final sub =
        CachePartitions.box('coding_box').watch().listen((_) => events++);
    await CachePartitions.box('coding_box').put('before', 1);
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    await enter('uid-B');
    await enter('uid-A');
    await CachePartitions.box('coding_box').put('after', 2);
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    await sub.cancel();
  });
  test(
      'legacy clean stays archived, explicit pending copies only to owner/company exactly once',
      () async {
    final legacy = await Hive.openBox('sales_box');
    await legacy.put('C1_B1', [
      {'id': 'clean-secret', 'company_code': 'C1'}
    ]);
    final pending = await Hive.openBox('commercial_pending_box');
    await pending.put('sales:mine', {
      'user_uid': 'uid-migrate',
      'company_code': 'C1',
      'id': 'mine',
      'kind': 'sales',
      'action': 'save',
      'data': {
        'id': 'mine',
        'company_code': 'C1',
        'branch_code': 'B1',
        'date': '2026-11-23'
      }
    });
    await pending.put('sales:unknown', {
      'company_code': 'C1',
      'id': 'unknown',
      'kind': 'sales',
      'action': 'save'
    });
    await enter('uid-migrate');
    expect(CachePartitions.box('commercial_pending_box').keys, ['sales:mine']);
    expect(
        (await CommercialService().fetch('sales', 'C1')).single['id'], 'mine');
    expect(legacy.get('C1_B1'), isNotNull);
    expect(pending.length, 2);
    await CachePartitions.box('commercial_pending_box').delete('sales:mine');
    await enter('uid-A');
    await enter('uid-migrate');
    expect(CachePartitions.box('commercial_pending_box').get('sales:mine'),
        isNull);
    await enter('uid-other');
    expect(CachePartitions.box('commercial_pending_box').isEmpty, isTrue);
  });
  test(
      'actual permission narrowing purges A only and never restores old A data',
      () async {
    await enter('uid-B');
    await CachePartitions.box('coding_box').put('C1_employees', [
      {'code': 'B', 'salary': 222}
    ]);
    await enter('uid-A');
    await CachePartitions.box('coding_box').put('C1_employees', [
      {'code': 'A', 'salary': 111}
    ]);
    final old = {
      'الموارد البشرية': {
        'canViewEmployees': true,
        'canViewSalaryAmounts': true
      }
    };
    final next = {
      'الموارد البشرية': {
        'canViewEmployees': true,
        'canViewSalaryAmounts': false
      }
    };
    PermissionsService().debugSetPermissionsForTest(next,
        loaded: true, role: 'employee', branches: ['all']);
    await RevocationService.instance.applyTransition(
        email: 'test@example.invalid',
        companyCode: 'C1',
        ownerUid: 'uid-A',
        oldPerms: old,
        newPerms: next,
        oldBranches: ['all'],
        newBranches: ['all']);
    expect(
        (CachePartitions.box('coding_box').get('C1_employees') as List)
            .single['salary'],
        isNull);
    await enter('uid-B');
    expect(
        (CachePartitions.box('coding_box').get('C1_employees') as List)
            .single['salary'],
        222);
    await enter('uid-A');
    expect(
        (CachePartitions.box('coding_box').get('C1_employees') as List)
            .single['salary'],
        isNull);
  });
  test(
      'actual HR pending reader retained service returns only current owner queue',
      () async {
    final hr = HRService();
    await CachePartitions.box('hr_pending_box').put('C1_E1_2026-11-23', {
      'company_code': 'C1',
      'user_uid': 'uid-A',
      'action': 'save',
      'data': {}
    });
    expect(hr.getAllPendingForCompany('C1').single['user_uid'], 'uid-A');
    await enter('uid-B');
    await CachePartitions.box('hr_pending_box').clear();
    expect(hr.getAllPendingForCompany('C1'), isEmpty);
    await enter('uid-A');
    expect(hr.getAllPendingForCompany('C1').single['user_uid'], 'uid-A');
  });
  test('read authorization snapshots fail on ABA cache sessions', () async {
    final scope = await ReadAuthorizationSnapshot.capture();
    await enter('uid-B');
    await enter('uid-A');
    expect(scope.sameContext, isFalse);
    expect(scope.check, throwsA(isA<ReadAuthorizationChanged>()));
  });
  test(
      'explicit journal intentions and import batch keep original operation IDs',
      () async {
    final intent = JournalSaveIntent(
        ownerUid: 'uid-journal',
        companyCode: 'C1',
        branchCode: 'B1',
        serial: 0);
    intent.capture({'company_code': 'C1', 'branch_code': 'B1', 'serial': 0});
    final legacy = await Hive.openBox(JournalIntentStore.boxName);
    await legacy.put(jsonEncode(['test-tab', 'uid-journal', 'C1', 'B1', 0]),
        intent.envelope());
    final batch = await Hive.openBox(JournalImportBatch.boxName);
    await batch
        .put(jsonEncode(['test-tab', 'uid-journal', 'C1', 'B1', 'hash']), {
      'version': 1,
      'batch_id': 'old-batch',
      'next': 0,
      'intents': [intent.envelope()]
    });
    await enter('uid-journal');
    final restored = await JournalIntentStore(tabId: 'test-tab').load(
        ownerUid: 'uid-journal',
        companyCode: 'C1',
        branchCode: 'B1',
        serial: 0);
    expect(restored!.operationId, intent.operationId);
    expect(
        (CachePartitions.box(JournalImportBatch.boxName).values.single
            as Map)['batch_id'],
        'old-batch');
    await enter('uid-B');
    expect(CachePartitions.box(JournalIntentStore.boxName).isEmpty, isTrue);
  });
  test('actual old socket cannot write after same owner logs out and returns',
      () async {
    final channel = socket.Channel();
    final ws = WebSocketSyncService(channelFactory: (_) => channel);
    await ws.connect('C1');
    await enter('uid-B');
    await enter('uid-A');
    channel.emit({
      'type': 'coding',
      'action': 'update',
      'data': {
        'company_code': 'C1',
        'category': 'branches',
        'code': 'late',
        'name': 'old-session'
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(CachePartitions.box('coding_box').get('C1_branches'), isNull);
    ws.disconnect();
    await channel.incoming.close();
  });
  test(
      'pending save acknowledgement after switch keeps original queue, never sends as B',
      () async {
    final started = Completer<void>(), gate = Completer<void>();
    final requests = <String>[];
    await http.runWithClient(() async {
      await CommercialService().save('sales', {
        'id': 'switch-op',
        'company_code': 'C1',
        'branch_code': 'B1',
        'date': '2026-11-23',
        'serial': 1
      });
      await started.future;
      await enter('uid-B');
      await CachePartitions.box('commercial_pending_box').clear();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(CachePartitions.box('commercial_pending_box').isEmpty, isTrue);
      await enter('uid-A');
      expect(
          (CachePartitions.box('commercial_pending_box').get('sales:switch-op')
              as Map)['user_uid'],
          'uid-A');
      expect(requests.length, 1);
    },
        () => MockClient((r) async {
              requests.add(r.url.path);
              if (!started.isCompleted) started.complete();
              await gate.future;
              return http.Response(
                  '{"serial":1,"updated_at":"2026-11-23T00:00:00Z"}', 200);
            }));
  });
  for (final flag in ['revoked_hold', 'discarded']) {
    test(
        'legacy $flag pending stays durable without becoming visible financial data',
        () async {
      final source = await Hive.openBox('commercial_pending_box');
      final uid = 'uid-migrate-$flag';
      await source.put('sales:held-$flag', {
        'user_uid': uid,
        'company_code': 'C1',
        'kind': 'sales',
        'id': 'held-$flag',
        'action': 'save',
        flag: true,
        'data': {
          'id': 'held-$flag',
          'company_code': 'C1',
          'branch_code': 'B1',
          'date': '2026-11-23',
          'serial': 1,
          'total': 900
        }
      });
      await enter(uid);
      expect(
          (CachePartitions.box('commercial_pending_box').get('sales:held-$flag')
              as Map)[flag],
          isTrue);
      expect(await CommercialService().fetch('sales', 'C1'), isEmpty,
          reason:
              'An archived hold/discard must not be turned into a visible invoice on migration');
      expect(source.get('sales:held-$flag'), isNotNull);
    });
  }

  test(
      'already migrated v2 held row is removed on return, queue and other rows survive',
      () async {
    final queue = CachePartitions.box('commercial_pending_box');
    await queue.put('sales:old-held', {
      'user_uid': 'uid-A',
      'company_code': 'C1',
      'kind': 'sales',
      'id': 'old-held',
      'action': 'save',
      'revoked_hold': true,
      'data': {'id': 'old-held', 'company_code': 'C1', 'total': 900}
    });
    await CachePartitions.box('sales_box').put('C1_B1', [
      {
        'id': 'old-held',
        'company_code': 'C1',
        'total': 900,
        'sync_status': 'pending'
      },
      {'id': 'allowed', 'company_code': 'C1', 'total': 20}
    ]);
    await enter('uid-B');
    await enter('uid-A');
    expect((await CommercialService().fetch('sales', 'C1')).single['id'],
        'allowed');
    expect(
        (CachePartitions.box('commercial_pending_box').get('sales:old-held')
            as Map)['revoked_hold'],
        isTrue);
  });
  test(
      'repair never deletes same-ID newer/different cache data or other company',
      () async {
    await CachePartitions.box('commercial_pending_box').put('sales:hold', {
      'user_uid': 'uid-A',
      'company_code': 'C1',
      'kind': 'sales',
      'id': 'hold',
      'revoked_hold': true,
      'data': {'id': 'hold', 'company_code': 'C1', 'total': 900}
    });
    await CachePartitions.box('sales_box').put('mixed', [
      {
        'id': 'hold',
        'company_code': 'C1',
        'total': 901,
        'sync_status': 'pending'
      },
      {
        'id': 'hold',
        'company_code': 'C2',
        'total': 900,
        'sync_status': 'pending'
      }
    ]);
    await enter('uid-B');
    await enter('uid-A');
    expect(CachePartitions.box('sales_box').get('mixed'), hasLength(2));
  });
}
