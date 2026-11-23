// Actual DailyService/JournalSaveClient with real temporary Hive and fake auth.
// HTTP is a bounded receipt-server double, not the production or ASGI backend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/daily_service.dart';
import 'package:islam_app/services/journal_cache.dart';
import 'package:islam_app/services/journal_save_client.dart';
import 'package:islam_app/services/journal_save_intent.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;

http.Response respond(String body, int status) => http.Response(body, status,
    headers: {'content-type': 'application/json; charset=utf-8'});

class JournalServer {
  final receipts = <String, Map<String, dynamic>>{};
  final rows = <int, Map<String, dynamic>>{};
  final posts = <Map<String, dynamic>>[];
  var statusReads = 0;
  var mode = 'ok';
  Completer<void>? gate;
  Completer<void>? started;
  bool link = false;
  Map<String, dynamic> snapshot(String op) {
    final serial = receipts[op]!['serial'] as int;
    final row = rows[serial];
    return {
      'status': 'success',
      'committed': true,
      'available': row != null,
      'serial': serial,
      'record': row,
      'linked_settlement': link
          ? {
              'doc_id': 'd1',
              'company_code': 'C1',
              'branch_code': 'B1',
              'date': '2026-11-22',
              'amount': 10.0,
              'updated_at': '2026-11-22T10:00:00',
              'is_deleted': false,
            }
          : null
    };
  }

  Future<http.Response> handle(http.Request request) async {
    if (mode == 'offline') throw const SocketException('offline');
    if (request.method == 'GET') {
      statusReads++;
      if (mode == '403') return respond('{}', 403);
      if (mode == 'conflict-unverifiable') return respond('{}', 500);
      final op = request.url.pathSegments.last;
      if (!receipts.containsKey(op)) return respond('{}', 404);
      final result = snapshot(op);
      if (mode == 'foreign')
        result['record'] = {...result['record'] as Map, 'company_code': 'C2'};
      return respond(jsonEncode(result), 200);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    posts.add(body);
    if (mode == '500') return respond('{}', 500);
    if (mode == '422') return respond('{}', 422);
    if (mode == '409' || mode == 'conflict-unverifiable')
      return respond('{}', 409);
    if (mode == '403') return respond('{}', 403);
    final op = body['operation_id'] as String;
    if (!receipts.containsKey(op)) {
      final serial = rows.length + 1;
      rows[serial] = {
        ...body,
        'serial': serial,
        'id': serial,
        'updated_at': '2026-11-22T10:00:00',
        'is_deleted': false
      };
      receipts[op] = {'serial': serial};
    }
    final result = snapshot(op);
    // Preserve this response's version even if the server row changes later.
    final reply = jsonEncode(result);
    if (mode == 'committed409') return respond('{}', 409);
    if (mode == 'deleted409') {
      rows.remove(receipts[op]!['serial']);
      return respond('{}', 409);
    }
    if (mode == 'hold') {
      started!.complete();
      await gate!.future;
    }
    if (mode == 'lost')
      throw const SocketException('response lost after commit');
    if (mode == 'malformed') return respond('{', 200);
    if (mode == 'foreign')
      return respond(
          jsonEncode({
            ...result,
            'record': {...result['record'] as Map, 'company_code': 'C2'}
          }),
          200);
    return respond(reply, 200);
  }
}

class BadSaveStore extends JournalIntentStore {
  BadSaveStore() : super(tabId: 'bad-save');
  @override
  Future<void> save(JournalSaveIntent intent) async => throw StateError('disk');
}

class BadAckStore extends JournalIntentStore {
  BadAckStore() : super(tabId: 'bad-ack');
  @override
  Future<void> acknowledge(JournalSaveIntent intent) async =>
      throw StateError('disk');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory directory;
  late JournalServer server;
  late JournalIntentStore store;
  late DailyService service;
  JournalSaveIntent intent() => JournalSaveIntent(
      ownerUid: 'uid-A', companyCode: 'C1', branchCode: 'B1', serial: 0);
  Future<Map<String, dynamic>> save(JournalSaveIntent value,
          {JournalIntentStore? into}) =>
      service.saveTransaction(
          companyCode: 'C1',
          serial: 0,
          treasury: 'A',
          amount: 10,
          statement: 'test',
          category: 'Income',
          date: '2026-11-22',
          type: 'وارد',
          branchCode: 'B1',
          intent: value,
          intentStore: into ?? store);
  Future<JournalSaveIntent?> pending({JournalIntentStore? from}) =>
      (from ?? store).load(
          ownerUid: 'uid-A', companyCode: 'C1', branchCode: 'B1', serial: 0);
  Map? local() =>
      Hive.box('daily_transactions_box').get(JournalCache.key('C1', 'B1', '1'))
          as Map?;
  Future<void> run(Future<void> Function() body) =>
      http.runWithClient(body, () => MockClient(server.handle));
  void rights(bool enabled) => PermissionsService().debugSetPermissionsForTest(
      {
        'حركة الخزينة': {
          'ادخال اذون': enabled,
          'التعديل': enabled,
          'المعاينة': enabled
        },
        'تسويات الموردين': {'معاينة': enabled}
      },
      role: 'employee',
      branches: ['B1']);
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('journal_recovery_');
    Hive.init(directory.path);
    await Hive.openBox('daily_transactions_box');
    await Hive.openBox('supplier_settlement_box');
    f.currentUid = 'uid-A';
    rights(true);
    service = DailyService();
    server = JournalServer();
    store = JournalIntentStore(tabId: 'manual-test');
  });
  tearDown(() async {
    await Hive.close();
    directory.deleteSync(recursive: true);
  });

  test(
      'healthy save has one POST, no status GET, server version in cache, no pending intent',
      () => run(() async {
            final result = await save(intent());
            expect(result['success'], true);
            expect(result['refresh_pending'], false);
            expect(server.posts.length, 1);
            expect(server.statusReads, 0);
            expect(local()!['updated_at'], '2026-11-22T10:00:00');
            expect(await pending(), isNull);
          }));
  test(
      'lost response reconciles receipt without a second POST or voucher',
      () => run(() async {
            server.mode = 'lost';
            final value = intent();
            final result = await save(value);
            expect(result['success'], true);
            expect(server.posts.length, 1);
            expect(server.statusReads, 1);
            expect(server.rows.length, 1);
            expect(await pending(), isNull);
          }));
  test(
      'malformed success is uncertain and reconciles the current receipt',
      () => run(() async {
            server.mode = 'malformed';
            expect((await save(intent()))['success'], true);
            expect(server.posts.length, 1);
            expect(server.statusReads, 1);
          }));
  test(
      'failed attempt retains immutable identity; next click checks status before same POST',
      () => run(() async {
            final value = intent();
            server.mode = '500';
            await expectLater(save(value), throwsA(isA<JournalSaveFailure>()));
            expect((await pending())!.operationId, value.operationId);
            server.mode = 'ok';
            await service.saveCapturedTransaction(value, store: store);
            expect(server.posts.length, 2);
            expect(server.statusReads, 2);
            expect(server.posts.map((p) => p['operation_id']).toSet(),
                {value.operationId});
          }));
  test(
      'deliberately identical confirmed vouchers remain distinct',
      () => run(() async {
            await save(intent());
            await save(intent());
            expect(server.rows.length, 2);
            expect(server.statusReads, 0);
            expect(server.posts[0]['operation_id'],
                isNot(server.posts[1]['operation_id']));
          }));
  test(
      'durable restart uses current server row, never the original captured values',
      () => run(() async {
            final value = intent();
            value.capture({
              'company_code': 'C1',
              'branch_code': 'B1',
              'serial': 0,
              'amount': 10,
              'statement': 'test',
              'category': 'Income',
              'date': '2026-11-22',
              'type': 'وارد',
              'treasury': 'A'
            });
            await store.save(value);
            server.receipts[value.operationId] = {'serial': 1};
            server.rows[1] = {
              ...value.payload!,
              'id': 1,
              'serial': 1,
              'amount': 99,
              'updated_at': '2026-11-22T11:00:00',
              'is_deleted': false
            };
            await Hive.close();
            Hive.init(directory.path);
            await Hive.openBox('daily_transactions_box');
            await Hive.openBox('supplier_settlement_box');
            service = DailyService();
            final restored = (await pending())!;
            await service.saveCapturedTransaction(restored, store: store);
            expect(server.posts, isEmpty);
            expect(local()!['amount'], 99);
          }));
  test(
      'committed but deleted record is acknowledged without recreation',
      () => run(() async {
            final value = intent()
              ..capture(
                  {'company_code': 'C1', 'branch_code': 'B1', 'serial': 0});
            await store.save(value);
            server.receipts[value.operationId] = {'serial': 1};
            final result =
                await service.saveCapturedTransaction(value, store: store);
            expect(result['committed'], true);
            expect(result['available'], false);
            expect(server.posts, isEmpty);
            expect(local(), isNull);
            expect(await pending(), isNull);
          }));
  test(
      'late older HTTP acknowledgement never replaces a newer cached journal version',
      () => run(() async {
            server.mode = 'hold';
            server.gate = Completer();
            server.started = Completer();
            final task = save(intent());
            await server.started!.future;
            await JournalCache.put(Hive.box('daily_transactions_box'), {
              ...server.rows[1]!,
              'amount': 777,
              'updated_at': '2026-11-22T12:00:00'
            });
            server.gate!.complete();
            await task;
            expect(local()!['amount'], 777);
          }));
  test(
      'deletion observed during POST is not resurrected by the delayed reply',
      () => run(() async {
            server.mode = 'hold';
            server.gate = Completer();
            server.started = Completer();
            final task = save(intent());
            await server.started!.future;
            final box = Hive.box('daily_transactions_box');
            await JournalCache.put(box, server.rows[1]!);
            await JournalCache.delete(box,
                company: 'C1', branch: 'B1', serial: '1');
            await Future<void>.delayed(Duration.zero);
            server.gate!.complete();
            final result = await task;
            expect(local(), isNull);
            expect(result['refresh_pending'], true);
          }));
  test(
      'newer linked settlement and foreign-company same doc identity are preserved',
      () => run(() async {
            server.mode = 'hold';
            server.link = true;
            server.gate = Completer();
            server.started = Completer();
            final task = save(intent());
            await server.started!.future;
            final box = Hive.box('supplier_settlement_box');
            await box.put('new', [
              {
                'doc_id': 'd1',
                'company_code': 'C1',
                'branch_code': 'B1',
                'amount': 888,
                'updated_at': '2026-11-22T12:00:00'
              }
            ]);
            await box.put('foreign', [
              {'doc_id': 'd1', 'company_code': 'C2', 'amount': 666}
            ]);
            server.gate!.complete();
            await task;
            expect(box.get('new')[0]['amount'], 888);
            expect(box.get('foreign')[0]['amount'], 666);
          }));
  test(
      'journal-only rights do not populate the linked settlement cache',
      () => run(() async {
            PermissionsService().debugSetPermissionsForTest(
                {
                  'حركة الخزينة': {'ادخال اذون': true, 'المعاينة': true},
                  'تسويات الموردين': {
                    'معاينة': false,
                    'إضافة': false,
                    'تعديل': false
                  }
                },
                role: 'employee',
                branches: ['B1']);
            server.link = true;
            final result = await save(intent());
            expect(result['committed'], true);
            expect(local(), isNotNull);
            expect(Hive.box('supplier_settlement_box').isEmpty, true);
          }));
  test(
      'owner switch during response cannot write cache or erase old owner pending work',
      () => run(() async {
            server.mode = 'hold';
            server.gate = Completer();
            server.started = Completer();
            final task = save(intent());
            await server.started!.future;
            f.currentUid = 'uid-B';
            server.gate!.complete();
            final result = await task;
            expect(result['owner_changed'], true);
            expect(local(), isNull);
            expect(await pending(), isNotNull);
          }));
  test(
      'permission revocation during response cannot repopulate the cache',
      () => run(() async {
            server.mode = 'hold';
            server.gate = Completer();
            server.started = Completer();
            final task = save(intent());
            await server.started!.future;
            rights(false);
            server.gate!.complete();
            final result = await task;
            expect(result['committed'], true);
            expect(result['refresh_pending'], true);
            expect(local(), isNull);
          }));
  test(
      'simultaneous same-intent calls coalesce to one POST',
      () => run(() async {
            server.mode = 'hold';
            server.gate = Completer();
            server.started = Completer();
            final value = intent();
            final a = save(value);
            final b = save(value);
            await server.started!.future;
            server.gate!.complete();
            await Future.wait([a, b]);
            expect(server.posts.length, 1);
            expect(server.rows.length, 1);
          }));
  test(
      'failure to preserve intention prevents any server write',
      () => run(() async {
            await expectLater(
                save(intent(), into: BadSaveStore()), throwsStateError);
            expect(server.posts, isEmpty);
          }));
  test(
      'failure clearing a confirmed intent is pending reconciliation, not failed business save',
      () => run(() async {
            final bad = BadAckStore();
            final result = await save(intent(), into: bad);
            expect(result['committed'], true);
            expect(result['intent_pending'], true);
            expect(await pending(from: bad), isNotNull);
            expect(server.posts.length, 1);
          }));
  test(
      'cache failure after commit reports confirmed save and pending refresh',
      () => run(() async {
            server.mode = 'hold';
            server.gate = Completer();
            server.started = Completer();
            final task = save(intent());
            await server.started!.future;
            await Hive.box('daily_transactions_box').close();
            server.gate!.complete();
            final result = await task;
            expect(result['committed'], true);
            expect(result['refresh_pending'], true);
            expect(server.posts.length, 1);
          }));
  test(
      'definite validation rejection permits correction and clears only its intention',
      () => run(() async {
            server.mode = '422';
            await expectLater(
                save(intent()),
                throwsA(isA<JournalSaveFailure>()
                    .having((e) => e.canReplace, 'canReplace', true)));
            expect(await pending(), isNull);
            expect(server.statusReads, 0);
            expect(server.rows, isEmpty);
          }));
  test(
      'conflict is not silently rebased or automatically resubmitted',
      () => run(() async {
            server.mode = '409';
            await expectLater(
                save(intent()),
                throwsA(isA<JournalSaveFailure>()
                    .having((e) => e.canReplace, 'canReplace', true)));
            expect(server.posts.length, 1);
            expect(server.statusReads, 1);
            expect(server.rows, isEmpty);
          }));
  test(
      '409 after commit reconciles the receipt instead of offering a new write',
      () => run(() async {
            server.mode = 'committed409';
            final result = await save(intent());
            expect(result['committed'], true);
            expect(server.posts.length, 1);
            expect(server.statusReads, 1);
            expect(await pending(), isNull);
            expect(local(), isNotNull);
          }));
  test(
      '409 for an unavailable committed row confirms without recreating it',
      () => run(() async {
            server.mode = 'deleted409';
            final result = await save(intent());
            expect(result['committed'], true);
            expect(result['available'], false);
            expect(server.posts.length, 1);
            expect(server.statusReads, 1);
            expect(await pending(), isNull);
            expect(local(), isNull);
          }));
  test(
      'unverifiable 409 keeps the original intent and uses only one status read',
      () => run(() async {
            server.mode = 'conflict-unverifiable';
            await expectLater(
                save(intent()),
                throwsA(isA<JournalSaveFailure>()
                    .having((error) => error.canReplace, 'canReplace', false)));
            expect(server.posts.length, 1);
            expect(server.statusReads, 1);
            expect(await pending(), isNotNull);
          }));
  test(
      'unverifiable foreign-company acknowledgement is not cached or forgotten',
      () => run(() async {
            server.mode = 'foreign';
            await expectLater(
                save(intent()), throwsA(isA<JournalSaveFailure>()));
            expect(await pending(), isNotNull);
            expect(local(), isNull);
          }));
}
