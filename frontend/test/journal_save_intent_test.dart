import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:islam_app/services/journal_save_intent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  JournalSaveIntent intent({String owner = 'u1', String company = 'C1'}) =>
      JournalSaveIntent(
          ownerUid: owner, companyCode: company, branchCode: 'B1', serial: 0);
  Map<String, dynamic> body() => {
        'company_code': 'C1',
        'branch_code': 'B1',
        'serial': 0,
        'amount': 10.0,
        'treasury': 'A',
        'category': 'Income',
        'date': '2026-11-22',
        'type': 'وارد',
        'statement': 'test',
        'link_id': 'stable-link'
      };
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('journal_intent_');
    Hive.init(directory.path);
  });
  tearDown(() async {
    await Hive.close();
    directory.deleteSync(recursive: true);
  });

  test(
      'retry preserves operation and linked identity and does not expose mutable payload',
      () {
    final value = intent();
    final first = value.capture(body());
    first['amount'] = 999;
    final retried = value.capture(body());
    expect(retried['amount'], 10.0);
    expect(retried['operation_id'], value.operationId);
    expect(retried['link_id'], 'stable-link');
    expect(() => value.capture({...body(), 'amount': 20.0}), throwsStateError);
  });
  test('intent capture refuses another company or branch', () {
    expect(() => intent().capture({...body(), 'company_code': 'C2'}),
        throwsStateError);
    expect(() => intent().capture({...body(), 'branch_code': 'B2'}),
        throwsStateError);
  });
  test('intentionally equal new forms retain distinct identities', () {
    final first = intent()..capture(body());
    final second = intent()..capture(body());
    expect(first.operationId, isNot(second.operationId));
  });
  test('durable envelope restores only exact authenticated owner and scope',
      () async {
    final original = intent()..capture(body());
    final store = JournalIntentStore(tabId: 'tab1');
    await store.save(original);
    await Hive.close();
    Hive.init(directory.path);
    final resumed = await store.load(
        ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 0);
    expect(resumed!.operationId, original.operationId);
    expect(resumed.payload, original.payload);
    expect(
        await store.load(
            ownerUid: 'u2', companyCode: 'C1', branchCode: 'B1', serial: 0),
        isNull);
    expect(
        await store.load(
            ownerUid: 'u1', companyCode: 'C2', branchCode: 'B1', serial: 0),
        isNull);
    expect(
        await store.load(
            ownerUid: 'u1', companyCode: 'C1', branchCode: 'B2', serial: 0),
        isNull);
    expect(
        await store.load(
            ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 1),
        isNull);
  });
  test('another tab cannot resume or erase the first tabs pending form',
      () async {
    final original = intent()..capture(body());
    final first = JournalIntentStore(tabId: 'tab1');
    final other = JournalIntentStore(tabId: 'tab2');
    await first.save(original);
    expect(
        await other.load(
            ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 0),
        isNull);
    await other.acknowledge(original);
    expect(
        await first.load(
            ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 0),
        isNotNull);
  });
  test(
      'unresolved work cannot be overwritten and acknowledgement matches its identity',
      () async {
    final first = intent()..capture(body());
    final second = intent()..capture(body());
    final store = JournalIntentStore(tabId: 'tab1');
    await store.save(first);
    await expectLater(store.save(second), throwsStateError);
    await store.acknowledge(second);
    expect(
        await store.load(
            ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 0),
        isNotNull);
    await store.acknowledge(first);
    expect(
        await store.load(
            ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 0),
        isNull);
    await store.save(second);
    await store.acknowledge(first);
    expect(
        (await store.load(
                ownerUid: 'u1',
                companyCode: 'C1',
                branchCode: 'B1',
                serial: 0))!
            .operationId,
        second.operationId);
  });
  test('malformed stored payload or empty authenticated scope does not throw',
      () {
    final original = intent()..capture(body());
    final malformed = original.envelope();
    malformed['payload'] = {3: 'not a string key'};
    expect(
        JournalSaveIntent.restore(malformed,
            ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 0),
        isNull);
    final emptyOwner = {...original.envelope(), 'owner_uid': ''};
    expect(
        JournalSaveIntent.restore(emptyOwner,
            ownerUid: '', companyCode: 'C1', branchCode: 'B1', serial: 0),
        isNull);
  });
  test('same operation cannot replace an already persisted payload', () async {
    final original = intent()..capture(body());
    final changed = JournalSaveIntent(
        ownerUid: 'u1',
        companyCode: 'C1',
        branchCode: 'B1',
        serial: 0,
        operationId: original.operationId)
      ..capture({...body(), 'amount': 20.0});
    final store = JournalIntentStore(tabId: 'tab1');
    await store.save(original);
    await expectLater(store.save(changed), throwsStateError);
    expect(
        (await store.load(
                ownerUid: 'u1',
                companyCode: 'C1',
                branchCode: 'B1',
                serial: 0))!
            .payload!['amount'],
        10.0);
  });
  test('forged envelope owner or payload identity is not attributed', () {
    final original = intent()..capture(body());
    final wrongOwner = {...original.envelope(), 'owner_uid': 'u2'};
    final wrongId = original.envelope();
    wrongId['payload'] = {...body(), 'operation_id': 'another-operation-id'};
    for (final raw in [wrongOwner, wrongId]) {
      expect(
          JournalSaveIntent.restore(raw,
              ownerUid: 'u1', companyCode: 'C1', branchCode: 'B1', serial: 0),
          isNull);
    }
  });
}
