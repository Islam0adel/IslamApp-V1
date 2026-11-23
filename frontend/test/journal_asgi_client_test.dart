// Opt-in real loopback ASGI route/client integration, with fake identity and
// temporary SQLite/Hive. Does not exercise production Firebase or PostgreSQL.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/daily_service.dart';
import 'package:islam_app/services/journal_save_intent.dart';
import 'package:islam_app/services/journal_import_batch.dart';
import 'package:islam_app/services/journal_save_client.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;

class FixtureNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  final endpoint = Platform.environment['JOURNAL_TEST_URL'];
  final base = Uri.parse(endpoint ?? 'http://127.0.0.1:58731');
  if (base.host != '127.0.0.1' || base.scheme != 'http') {
    throw StateError('Fixture integration must use loopback only');
  }
  late Directory directory;
  late IOClient network;
  late DailyService service;
  late JournalIntentStore store;
  var mode = 'ok';
  var posts = 0;
  var reads = 0;
  Future<Map<String, dynamic>> state() async =>
      Map<String, dynamic>.from(jsonDecode(
          (await network.get(base.replace(path: '/__fixture/state'))).body));
  Future<http.Response> bridge(http.Request request) async {
    if (request.method == 'POST')
      posts++;
    else
      reads++;
    if (mode == 'unconfirmed' && request.method == 'GET') {
      throw const SocketException('fixture status unavailable');
    }
    final forwarded = http.Request(request.method,
        base.replace(path: request.url.path, query: request.url.query))
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;
    final response =
        await http.Response.fromStream(await network.send(forwarded));
    if (request.method == 'POST') {
      expect(response.statusCode, 200, reason: response.body);
      if (mode == 'deleted-lost') {
        await network.post(base.replace(path: '/__fixture/delete'));
      }
      if (mode == 'lost' || mode == 'unconfirmed' || mode == 'deleted-lost') {
        throw const SocketException(
            'fixture response lost after actual commit');
      }
      if (mode == 'malformed') return http.Response('{', 200);
    }
    return response;
  }

  Future<T> run<T>(Future<T> Function() work) =>
      http.runWithClient(work, () => MockClient(bridge));
  JournalSaveIntent intent() => JournalSaveIntent(
      ownerUid: 'uid-A', companyCode: 'C1', branchCode: 'B1', serial: 0);
  Future<Map<String, dynamic>> save(JournalSaveIntent value,
          {bool linked = false}) =>
      service.saveTransaction(
          companyCode: 'C1',
          serial: 0,
          treasury: 'A',
          amount: 10,
          statement: 'ASGI fixture',
          category: linked ? 'بضاعة' : 'Income',
          date: '2026-11-22',
          type: 'وارد',
          branchCode: 'B1',
          intent: value,
          intentStore: store,
          linkId: linked ? 'stable-link' : null,
          supplierName: linked ? 'Supplier' : null,
          addToSettlement: linked);
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('journal_client_asgi_');
    Hive.init(directory.path);
    await Hive.openBox('daily_transactions_box');
    await Hive.openBox('supplier_settlement_box');
    f.currentUid = 'uid-A';
    PermissionsService().debugSetPermissionsForTest(
        {
          'حركة الخزينة': {
            'ادخال اذون': true,
            'التعديل': true,
            'المعاينة': true
          }
        },
        role: 'employee',
        branches: ['B1', 'B2']);
    network = IOClient(FixtureNetwork().createHttpClient(null));
    final reset = await network.post(base.replace(path: '/__fixture/reset'));
    expect(reset.statusCode, 200);
    service = DailyService();
    store = JournalIntentStore(tabId: 'asgi-test');
    mode = 'ok';
    posts = 0;
    reads = 0;
  });
  tearDown(() async {
    network.close();
    await Hive.close();
    directory.deleteSync(recursive: true);
  });
  for (final scenario in [
    'ok',
    'lost',
    'malformed',
    'deleted-lost',
    'linked-lost'
  ]) {
    test(
        'actual ASGI journal client: $scenario',
        () => run(() async {
              mode = scenario == 'linked-lost' ? 'lost' : scenario;
              final result =
                  await save(intent(), linked: scenario == 'linked-lost');
              expect(result['committed'], true);
              expect(result['available'], scenario != 'deleted-lost');
              expect(posts, 1);
              expect(reads, scenario == 'ok' ? 0 : 1);
              expect(await state(), {
                'rows': 1,
                'receipts': 1,
                'settlements': scenario == 'linked-lost' ? 1 : 0
              });
              expect(
                  await store.load(
                      ownerUid: 'uid-A',
                      companyCode: 'C1',
                      branchCode: 'B1',
                      serial: 0),
                  isNull);
            }),
        skip: endpoint == null
            ? 'Requires temporary loopback journal fixture'
            : false);
  }
  test('actual ASGI unfinished import retries the committed row without duplication',
      () => run(() async {
        JournalImportBatch batch() => JournalImportBatch(ownerUid:'uid-A',companyCode:'C1',branchCode:'B1',bytes:[4,5,6],tabId:'asgi-import');
        final rows=List.generate(2,(index)=><String,dynamic>{'company_code':'C1','branch_code':'B1','serial':0,
          'amount':10.0,'treasury':'A','statement':'import$index','category':'Income','date':'2026-11-22','type':'وارد'});
        Future<void> submit() => batch().run(rows:rows,stillAuthorized:()=>true,
          submit:(intent,store)=>service.saveCapturedTransaction(intent,store:store));
        mode='unconfirmed';
        await expectLater(submit(),throwsA(isA<JournalSaveFailure>()));
        expect(await state(),{'rows':1,'receipts':1,'settlements':0});
        mode='ok';
        await submit();
        expect(await state(),{'rows':2,'receipts':2,'settlements':0});
        expect(posts,2);
        expect(Hive.box(JournalImportBatch.boxName).isEmpty,true);
      }),skip:endpoint==null?'Requires temporary loopback journal fixture':false);
  test(
      'actual ASGI journal client: explicit retry uses persisted receipt, not POST',
      () => run(() async {
            mode = 'unconfirmed';
            await expectLater(
                save(intent()), throwsA(isA<JournalSaveFailure>()));
            final restored = await store.load(
                ownerUid: 'uid-A',
                companyCode: 'C1',
                branchCode: 'B1',
                serial: 0);
            expect(restored, isNotNull);
            mode = 'ok';
            final result =
                await service.saveCapturedTransaction(restored!, store: store);
            expect(result['committed'], true);
            expect(posts, 1);
            expect(reads, 2);
            expect(await state(), {'rows': 1, 'receipts': 1, 'settlements': 0});
          }),
      skip: endpoint == null
          ? 'Requires temporary loopback journal fixture'
          : false);
}
