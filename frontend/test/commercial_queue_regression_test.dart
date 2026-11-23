// Validation B: REAL CommercialService (lib/services/commercial_service.dart, unmodified)
// with: real Hive on a temp dir, fake package:http client (via http.runWithClient),
// fake FirebaseAuth platform (fixed uid, fake token). No network, no Firebase init, no credentials.
// The fake server models ONLY a by-id upsert + modes (ok/500/409/403/lost response/delay);
// it is a stub, NOT the real backend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseApp;
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:islam_app/services/commercial_service.dart';

class FakeApp extends FirebaseAppPlatform {
  FakeApp()
      : super(
            '[DEFAULT]',
            const FirebaseOptions(
                apiKey: 'x',
                appId: 'x',
                messagingSenderId: 'x',
                projectId: 'x'));
}

class FakeCore extends FirebasePlatform with MockPlatformInterfaceMixin {
  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) => FakeApp();
  @override
  Future<FirebaseAppPlatform> initializeApp(
          {String? name, FirebaseOptions? options}) async =>
      FakeApp();
  @override
  List<FirebaseAppPlatform> get apps => [FakeApp()];
}

String currentUid = 'uid-A';

class FakeMF extends MultiFactorPlatform with MockPlatformInterfaceMixin {
  FakeMF(super.auth);
}

class FakeUser extends UserPlatform with MockPlatformInterfaceMixin {
  FakeUser(FirebaseAuthPlatform a, String uid)
      : super(
            a,
            FakeMF(a),
            PigeonUserDetails(
                userInfo: PigeonUserInfo(
                    uid: uid, isAnonymous: false, isEmailVerified: true),
                providerData: []));
  @override
  Future<String?> getIdToken(bool forceRefresh) async => 'fake-token';
}

class FakeAuth extends FirebaseAuthPlatform with MockPlatformInterfaceMixin {
  FakeAuth() : super();
  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;
  @override
  FirebaseAuthPlatform setInitialValues(
          {PigeonUserDetails? currentUser, String? languageCode}) =>
      this;
  @override
  UserPlatform? get currentUser =>
      currentUid.isEmpty ? null : FakeUser(this, currentUid);
}

/// fake server
class Srv {
  Map<String, Map> rows = {};
  List<Map> posts = [];
  String mode = 'ok'; // ok | 500 | 409 | 403 | lost | offline | hold
  Completer<void>? gate;
  int serialCounter = 0;
  int version = 0;
  bool strictVersion = false;
  Future<http.Response> handle(http.Request r) async {
    if (mode == 'offline') throw const SocketException('offline');
    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    posts.add(
        {'path': r.url.path, 'body': body, 'auth': r.headers['Authorization']});
    if (mode == 'hold') await gate!.future;
    if (mode == '500') return http.Response('boom', 500);
    if (mode == '409') return http.Response('conflict', 409);
    if (mode == '403') return http.Response('forbidden', 403);
    if (r.url.path.contains('/delete/')) {
      final id = r.url.pathSegments.last;
      final had = rows.remove(id) != null;
      return http.Response('{}', had ? 200 : 404);
    }
    final id = body['id'].toString();
    final prev = rows[id];
    if (strictVersion &&
        prev != null &&
        body['base_updated_at'] != null &&
        body['base_updated_at'] != prev['updated_at']) {
      return http.Response('stale version', 409);
    }
    final stamp = DateTime.utc(2026, 11, 22)
        .add(Duration(seconds: ++version))
        .toIso8601String();
    final serial = prev?['serial'] ?? ++serialCounter;
    rows[id] = {...body, 'serial': serial, 'updated_at': stamp};
    if (mode == 'lost')
      throw const SocketException('response lost after server commit');
    return http.Response(
        jsonEncode(
            {'status': 'success', 'serial': serial, 'updated_at': stamp}),
        200);
  }
}

Directory? tmp;
late Srv srv;
const names = [
  'commercial_pending_box',
  'sales_box',
  'sales_returns_box',
  'customer_payments_box',
  'stock_transfers_box',
  'commercial_stock_events_box'
];

Future<void> reset() async {
  await Hive.close();
  tmp?.deleteSync(recursive: true);
  tmp = Directory.systemTemp.createTempSync('b_');
  Hive.init(tmp!.path);
  for (final n in names) {
    await Hive.openBox(n);
  }
  srv = Srv();
  currentUid = 'uid-A';
}

Map<String, dynamic> sale(String id, {int qty = 1}) => {
      'id': id,
      'company_code': 'C1',
      'branch_code': 'B1',
      'serial': 0,
      'qty': qty,
      'total': qty * 100.0,
    };

Future<void> settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 80));
}

Map? rec(String id) {
  for (final v in Hive.box('sales_box').values.whereType<List>()) {
    for (final e in v.whereType<Map>()) {
      if (e['id'] == id) return e;
    }
  }
  return null;
}

int qlen() => Hive.box('commercial_pending_box').length;

Future<void> inClient(Future<void> Function() body) =>
    http.runWithClient(body, () => MockClient(srv.handle));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = FakeCore();
  FirebaseAuthPlatform.instance = FakeAuth();

  setUp(reset);

  test('B0 sanity: fake uid visible to service path', () {
    expect(FirebaseAuthPlatformCheck(), 'uid-A');
  });

  test(
      'B1 offline save stays queued with stable id; later sync sends same id once, clears queue, takes server serial',
      () async {
    await inClient(() async {
      srv.mode = 'offline';
      final s = CommercialService();
      await s.save('sales', sale('s1'));
      await settle();
      expect(qlen(), 1);
      expect(rec('s1')!['sync_status'], 'error');
      expect(srv.posts.length, 0);
      srv.mode = 'ok';
      await s.syncPending('C1');
      expect(qlen(), 0);
      expect(srv.posts.length, 1);
      expect(srv.posts.single['body']['id'], 's1');
      expect(srv.posts.single['body']['serial'], 0);
      expect(srv.posts.single['auth'], 'Bearer fake-token');
      expect(rec('s1')!['sync_status'], 'synced');
      expect(rec('s1')!['serial'], 1);
      expect(srv.rows.length, 1);
    });
  });

  test(
      'B2 response lost after server commit: retry resends SAME id; server (stub by-id upsert) ends with 1 row',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'lost';
      await s.save('sales', sale('s2'));
      await settle();
      expect(srv.rows.length, 1);
      expect(qlen(), 1);
      srv.mode = 'ok';
      await s.syncPending('C1');
      expect(srv.posts.where((p) => p['body']['id'] == 's2').length, 2);
      expect(srv.rows.length, 1);
      expect(qlen(), 0);
    });
  });

  test('B3 409 blocks the op; later syncs do not resend it', () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = '409';
      await s.save('sales', sale('s3'));
      await settle();
      final n = srv.posts.length;
      expect(rec('s3')!['sync_status'], 'conflict');
      expect(
          Hive.box('commercial_pending_box')
              .get('sales:s3')['blocked_conflict'],
          true);
      srv.mode = 'ok';
      await s.syncPending('C1');
      expect(srv.posts.length, n);
      expect(qlen(), 1);
    });
  });

  test('B4 403/500 keep op queued as error; retried on each sync (no dropping)',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = '403';
      await s.save('sales', sale('s4'));
      await settle();
      expect(qlen(), 1);
      expect(rec('s4')!['sync_status'], 'error');
      await s.syncPending('C1');
      await s.syncPending('C1');
      expect(srv.posts.length, 3);
      expect(qlen(), 1);
    });
  });

  test(
      'B5 other-account op is not sent; op without user_uid is flagged ownership_unverified and not sent',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'offline';
      currentUid = 'uid-A';
      await s.save('sales', sale('s5'));
      await settle();
      srv.mode = 'ok';
      currentUid = 'uid-B';
      await s.syncPending('C1');
      expect(srv.posts.length, 0);
      expect(qlen(), 1);
      final q = Hive.box('commercial_pending_box');
      final op = Map<String, dynamic>.from(q.get('sales:s5') as Map)
        ..['user_uid'] = '';
      await q.put('sales:s5', op);
      await s.syncPending('C1');
      expect(srv.posts.length, 0);
      expect((q.get('sales:s5') as Map)['ownership_unverified'], true);
    });
  });

  test('B6 concurrent syncPending calls: lock => one POST per op', () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'offline';
      await s.save('sales', sale('s6'));
      await settle();
      srv.mode = 'hold';
      srv.gate = Completer<void>();
      final a = s.syncPending('C1');
      final b = s.syncPending('C1');
      final c = CommercialService().syncPending('C1');
      await settle();
      srv.gate!.complete();
      await Future.wait([a, b, c]);
      expect(srv.posts.where((p) => p['body']['id'] == 's6').length, 1);
      expect(qlen(), 0);
    });
  });

  test(
      'B7 edit of same id WHILE its POST is in flight (assert latest edit survives)',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'hold';
      srv.gate = Completer<void>();
      await s.save('sales', sale('s7', qty: 1)); // starts sync, held at server
      await settle();
      await s.save('sales', sale('s7', qty: 5)); // edit during flight
      srv.mode = 'ok';
      srv.gate!.complete();
      await settle();
      await s.syncPending('C1');
      await settle();
      final sentQtys = srv.posts
          .where((p) => p['body']['id'] == 's7')
          .map((p) => p['body']['qty'])
          .toList();
      expect(sentQtys, [1, 5]);
      expect(srv.rows['s7']?['qty'], 5);
      expect(rec('s7')?['qty'], 5);
      expect(qlen(), 0);
    });
  });

  test(
      'B8 delete after a save whose response was lost (assert server deletion)',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'lost';
      await s.save('sales', sale('s8'));
      await settle();
      final serverHad = srv.rows.containsKey('s8');
      srv.mode = 'ok';
      await s.delete('sales', 'C1', 's8');
      await settle();
      expect(serverHad, true);
      expect(srv.rows.containsKey('s8'), false);
      expect(qlen(), 0);
      expect(srv.posts.where((p) => p['path'].contains('/delete/')).length, 1);
    });
  });

  test(
      'B10 delete during in-flight save follows save, never resurrects local row',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'hold';
      srv.gate = Completer<void>();
      await s.save('sales', sale('flight-delete'));
      await settle();
      await s.delete('sales', 'C1', 'flight-delete');
      expect(rec('flight-delete')!['is_deleted'], true);
      srv.mode = 'ok';
      srv.gate!.complete();
      await settle();
      expect(srv.rows.containsKey('flight-delete'), false);
      expect(rec('flight-delete')!['is_deleted'], true);
      expect(qlen(), 0);
      expect(srv.posts.length, 2);
    });
  });

  test(
      'B11 real edit payload keeps server base then advances only on acknowledged POST',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.strictVersion = true;
      await s.save('sales', sale('versions'));
      await settle();
      final firstVersion = rec('versions')!['updated_at'];
      srv.mode = 'hold';
      srv.gate = Completer<void>();
      final firstEdit = Map<String, dynamic>.from(rec('versions')!);
      firstEdit['base_updated_at'] = firstEdit['updated_at'];
      firstEdit['qty'] = 2;
      await s.save('sales', firstEdit);
      await settle();
      final lastEdit = Map<String, dynamic>.from(rec('versions')!);
      lastEdit['base_updated_at'] =
          lastEdit['updated_at']; // UI uses local row timestamp
      lastEdit['qty'] = 9;
      await s.save('sales', lastEdit);
      expect(
          Hive.box('commercial_pending_box').get('sales:versions')['data']
              ['base_updated_at'],
          firstVersion);
      srv.mode = 'ok';
      srv.gate!.complete();
      await settle();
      expect(srv.rows['versions']!['qty'], 9);
      expect(rec('versions')!['qty'], 9);
      expect(rec('versions')!['sync_status'], 'synced');
      expect(qlen(), 0);
      final saves =
          srv.posts.where((p) => p['body']['id'] == 'versions').toList();
      expect(saves.length, 3);
      expect(saves[2]['body']['base_updated_at'], isNot(firstVersion));
    });
  });

  test('B12 actual external change remains conflict, not silently rebased',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.strictVersion = true;
      await s.save('sales', sale('conflicting'));
      await settle();
      final edit = Map<String, dynamic>.from(rec('conflicting')!);
      edit['base_updated_at'] = edit['updated_at'];
      edit['qty'] = 8;
      srv.rows['conflicting']!['updated_at'] = 'another-device-version';
      await s.save('sales', edit);
      await settle();
      expect(qlen(), 1);
      expect(rec('conflicting')!['qty'], 8);
      expect(rec('conflicting')!['sync_status'], 'conflict');
      expect(srv.rows['conflicting']!['qty'], 1);
    });
  });

  test(
      'B13 rapid local saves are serialized; latest save and single record survive',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'offline';
      await Future.wait(
          List.generate(12, (n) => s.save('sales', sale('rapid', qty: n + 1))));
      await settle();
      expect(rec('rapid')!['qty'], 12);
      expect(qlen(), 1);
      srv.mode = 'ok';
      await s.syncPending('C1');
      expect(srv.rows['rapid']!['qty'], 12);
      expect(qlen(), 0);
    });
  });

  test('B14 legacy attempted=false pending save still receives server delete',
      () async {
    await inClient(() async {
      final s = CommercialService();
      await s.save('sales', sale('legacy'));
      await settle();
      await Hive.box('commercial_pending_box').put('sales:legacy', {
        'kind': 'sales',
        'id': 'legacy',
        'company_code': 'C1',
        'user_uid': 'uid-A',
        'action': 'save',
        'attempted': false,
        'revision': 'legacy',
        'data': sale('legacy'),
      });
      await s.delete('sales', 'C1', 'legacy');
      await settle();
      expect(srv.rows.containsKey('legacy'), false);
      expect(qlen(), 0);
    });
  });

  for (final refreshMode in ['manual', 'full', 'delta']) {
    test(
        'B15 $refreshMode preserves conflict and hidden pending delete, scoped to company',
        () async {
      final box = Hive.box('sales_box');
      final queue = Hive.box('commercial_pending_box');
      await box.put('C1_B1_day', [
        {...sale('conflict-refresh', qty: 7), 'sync_status': 'conflict'},
        {...sale('delete-refresh'), 'is_deleted': true},
      ]);
      await box.put('C2_B1_day', [
        {...sale('other-company'), 'company_code': 'C2'}
      ]);
      await queue.put('sales:conflict-refresh', {
        'kind': 'sales',
        'company_code': 'C1',
        'id': 'conflict-refresh',
        'action': 'save',
        'user_uid': 'uid-A',
        'blocked_conflict': true,
        'data': sale('conflict-refresh', qty: 7),
      });
      await queue.put('sales:delete-refresh', {
        'kind': 'sales',
        'company_code': 'C1',
        'id': 'delete-refresh',
        'action': 'delete',
        'user_uid': 'uid-A',
      });
      await http.runWithClient(() async {
        final service = CommercialService();
        SharedPreferences.setMockInitialValues({});
        if (refreshMode == 'full') {
          await service.fetchAll('sales', 'C1');
        } else if (refreshMode == 'delta') {
          await service.syncChangesFromServer(
              'sales', 'C1', '2026-11-01T00:00:00Z');
        } else {
          await service.fetch('sales', 'C1', forceRefresh: true);
        }
        final result = await service.fetch('sales', 'C1');
        expect(result.where((r) => r['id'] == 'delete-refresh'), isEmpty);
        expect(result.single['qty'], 7);
        expect(result.single['sync_status'], 'conflict');
        expect(box.containsKey('C2_B1_day'), true);
        expect(queue.length, 2);
      },
          () => MockClient((r) async => http.Response(
              jsonEncode([
                sale('conflict-refresh'),
                sale('delete-refresh'),
              ]),
              200)));
    });
  }

  test('B18 delta honors server delete only for clean unqueued records',
      () async {
    final box = Hive.box('sales_box');
    await box.put('C1_B1_day', [
      {...sale('held'), 'sync_status': 'conflict'},
      {...sale('clean'), 'sync_status': 'synced'},
    ]);
    SharedPreferences.setMockInitialValues({});
    await http.runWithClient(() async {
      await CommercialService()
          .syncChangesFromServer('sales', 'C1', '2026-11-01T00:00:00Z');
      final rows = await CommercialService().fetch('sales', 'C1');
      expect(rows.map((r) => r['id']), ['held']);
      expect(rows.single['sync_status'], 'conflict');
    },
        () => MockClient((r) async => http.Response(
            jsonEncode([
              {...sale('held'), 'action': 'delete', 'is_deleted': true},
              {...sale('clean'), 'action': 'delete', 'is_deleted': true},
            ]),
            200)));
  });

  test('B19 scoped manual snapshot does not erase another branch', () async {
    final box = Hive.box('sales_box');
    await box.put('C1_B1_day', [
      {...sale('stale'), 'sync_status': 'synced'}
    ]);
    await box.put('C1_B2_day', [
      {...sale('other-branch'), 'branch_code': 'B2', 'sync_status': 'synced'}
    ]);
    await http.runWithClient(() async {
      await CommercialService()
          .fetch('sales', 'C1', branchCode: 'B1', forceRefresh: true);
      final rows = await CommercialService().fetch('sales', 'C1');
      expect(rows.map((r) => r['id']).toSet(), {'fresh', 'other-branch'});
    },
        () => MockClient(
            (r) async => http.Response(jsonEncode([sale('fresh')]), 200)));
  });

  test('B20 first sync watermark starts before its request, not after response',
      () async {
    SharedPreferences.setMockInitialValues({});
    DateTime? requestAt;
    await http.runWithClient(() async {
      await CommercialService().syncChangesFromServer('sales', 'C1');
      final prefs = await SharedPreferences.getInstance();
      final recorded = DateTime.parse(prefs.getString('last_sync_sales_C1')!);
      expect(recorded.isAfter(requestAt!), false);
    },
        () => MockClient((r) async {
              requestAt = DateTime.now().toUtc();
              await Future<void>.delayed(const Duration(milliseconds: 20));
              return http.Response('[]', 200);
            }));
  });

  test('B16 sync requested for another company during flight is not dropped',
      () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'hold';
      srv.gate = Completer<void>();
      await s.save('sales', sale('company-one'));
      await settle();
      await s.save('sales', {...sale('company-two'), 'company_code': 'C2'});
      srv.mode = 'ok';
      srv.gate!.complete();
      await settle();
      expect(srv.rows.containsKey('company-two'), true);
      expect(qlen(), 0);
    });
  });

  test('B17 hold applied during commercial upload survives response', () async {
    await inClient(() async {
      final s = CommercialService();
      srv.mode = 'hold';
      srv.gate = Completer<void>();
      await s.save('sales', sale('hold-in-flight'));
      await settle();
      final q = Hive.box('commercial_pending_box');
      final op = Map<String, dynamic>.from(q.get('sales:hold-in-flight'));
      op['revoked_hold'] = true;
      await q.put('sales:hold-in-flight', op);
      srv.mode = 'ok';
      srv.gate!.complete();
      await settle();
      expect(qlen(), 1);
      expect(q.get('sales:hold-in-flight')['revoked_hold'], true);
      expect(rec('hold-in-flight')!['sync_status'], 'pending');
    });
  });

  test('B9 delete of synced record queues delete; 404 clears queue', () async {
    await inClient(() async {
      final s = CommercialService();
      await s.save('sales', sale('s9'));
      await settle();
      expect(qlen(), 0);
      await s.delete('sales', 'C1', 's9');
      await settle();
      expect(srv.rows.containsKey('s9'), false);
      expect(qlen(), 0);
      expect(rec('s9')!['is_deleted'], true);
    });
  });
}

String FirebaseAuthPlatformCheck() => FakeAuth().currentUser!.uid;
