// Actual notification/revocation services with temporary on-disk Hive.
// Fake auth and HTTP only. No external account, push, or backend is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/notifications_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/revocation_service.dart';
import 'commercial_queue_regression_test.dart' as f;

const allow = {
  'حركة الخزينة': {'المعاينة': true},
  'صلاحيات عامة': {'إظهار حركة الخزينة': true}
};
const deny = {
  'حركة الخزينة': {'المعاينة': false},
  'صلاحيات عامة': {'إظهار حركة الخزينة': false}
};
Map<String, dynamic> row(String id,
        {String company = 'C1',
        String branch = 'B1',
        String owner = 'uid-A',
        String section = 'daily'}) =>
    {
      'id': id,
      'event_id': id,
      'recipient_uid': owner,
      'company_code': company,
      'branch_code': branch,
      'section': section,
      'title': 'Synthetic private title',
      'body': 'Synthetic private detail',
      'created_at': DateTime.now().toIso8601String(),
      'read': false,
    };
void rights(Map<String, dynamic> value, List<String> branches,
        {bool loaded = true}) =>
    PermissionsService().debugSetPermissionsForTest(value,
        role: 'employee', branches: branches, loaded: loaded);
Future<void> transition(Map<String, dynamic> next,
    {List<String> branches = const ['all']}) async {
  rights(next, branches);
  await RevocationService.instance.applyTransition(
      email: 'fixture@example.invalid',
      companyCode: 'C1',
      ownerUid: 'uid-A',
      oldPerms: allow,
      newPerms: next,
      oldBranches: const ['all'],
      newBranches: branches);
}

http.Response reply(List<Map<String, dynamic>> items,
        {int cursor = 1, bool more = false}) =>
    http.Response(
        jsonEncode({'items': items, 'next_cursor': cursor, 'has_more': more}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory directory;
  final service = NotificationsService.instance;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('notification_cache_');
    Hive.init(directory.path);
    for (final name in [
      'coding_box',
      'daily_transactions_box',
      'notifications_box',
      'notification_settings_box'
    ]) {
      await Hive.openBox(name);
    }
    SharedPreferences.setMockInitialValues({'company_code': 'C1'});
    f.currentUid = 'uid-A';
    rights(allow, ['all']);
  });
  tearDown(() async {
    await Hive.close();
    directory.deleteSync(recursive: true);
  });

  test('general show toggles alone cannot retain any section notification', () async {
    rights({'صلاحيات عامة': {'إظهار الإشعارات':true,'إظهار حركة الخزينة':true,'إظهار التكويد':true,'إظهار حركة الجرد':true,'إظهار حركة الموردين':true}}, ['all']);
    final box=Hive.box('notifications_box');
    for(final section in ['daily','coding','inventory','purchases','sales','settlements']) { await box.put(section,row(section,section:section)); }
    await service.purgeInaccessibleCache(companyCode:'C1',ownerUid:'uid-A',scopeChanged:true);
    expect(box.isEmpty,true);
  });
  test(
      'revoked content is physically deleted, allowed and other owner/company records stay',
      () async {
    final box = Hive.box('notifications_box');
    await box.put('revoked', row('revoked'));
    await box.put('other-company', row('other-company', company: 'C2'));
    await box.put('other-owner', row('other-owner', owner: 'uid-B'));
    await transition(deny);
    expect(box.containsKey('revoked'), false);
    expect(box.containsKey('other-company'), true);
    expect(box.containsKey('other-owner'), true);
  });
  test('branch narrowing purges only records outside new scope', () async {
    final box = Hive.box('notifications_box');
    await box.put('keep', row('keep'));
    await box.put('remove', row('remove', branch: 'B2'));
    await transition(allow, branches: ['B1']);
    expect(box.containsKey('keep'), true);
    expect(box.containsKey('remove'), false);
  });
  for (final unread in [false, true]) {
    final label = unread ? 'unread' : 'incremental';
    Future<void> refresh() => unread
        ? service.refreshUnreadFromServer(companyCode: 'C1')
        : service.refreshFromServer(companyCode: 'C1');
    test(
        '$label: denied section/branch/owner/company are never written; read state is preserved',
        () async {
      rights(allow, ['B1']);
      final box = Hive.box('notifications_box');
      await box.put('ok', {...row('ok'), 'read': true});
      await http.runWithClient(
          refresh,
          () => MockClient((_) async => reply([
                row('ok'),
                row('branch', branch: 'B2'),
                row('section', section: 'unknown'),
                row('owner', owner: 'uid-B'),
                row('company', company: 'C2'),
              ])));
      expect(box.keys.toList(), ['ok']);
      expect(box.get('ok')['read'], true);
    });
    test(
        '$label: HTTP reply after revocation cannot repopulate deleted content or cursor',
        () async {
      final requested = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        final task = refresh();
        await requested.future;
        await transition(deny);
        release.complete();
        await task;
        expect(Hive.box('notifications_box').isEmpty, true);
        expect(
            Hive.box('notification_settings_box')
                .get('notification_cursor_uid-A_C1'),
            isNull);
      },
          () => MockClient((_) async {
                requested.complete();
                await release.future;
                return reply([row('late')]);
              }));
    });
    test(
        '$label: account switch during HTTP does not relabel old response as current owner',
        () async {
      final requested = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        final task = refresh();
        await requested.future;
        f.currentUid = 'uid-B';
        release.complete();
        await task;
        expect(Hive.box('notifications_box').isEmpty, true);
      },
          () => MockClient((_) async {
                requested.complete();
                await release.future;
                return reply([row('late')]);
              }));
    });
    test('$label: latest rights are checked even without a transition callback',
        () async {
      final requested = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        final task = refresh();
        await requested.future;
        rights(deny, ['all']);
        release.complete();
        await task;
        expect(Hive.box('notifications_box').isEmpty, true);
      },
          () => MockClient((_) async {
                requested.complete();
                await release.future;
                return reply([row('late')]);
              }));
    });
  }
  test(
      'regrant does not revive an old in-flight response; a fresh refresh is not coalesced into it',
      () async {
    final requested = Completer<void>(), release = Completer<void>();
    var calls = 0;
    await http.runWithClient(() async {
      final old = service.refreshFromServer(companyCode: 'C1');
      await requested.future;
      await transition(deny);
      await transition(allow);
      final fresh = service.refreshFromServer(companyCode: 'C1');
      await fresh;
      release.complete();
      await old;
      final box = Hive.box('notifications_box');
      expect(calls, 2);
      expect(box.containsKey('new'), true);
      expect(box.containsKey('old'), false);
    },
        () => MockClient((_) async {
              calls++;
              if (calls == 1) {
                requested.complete();
                await release.future;
                return reply([row('old')]);
              }
              return reply([row('new')]);
            }));
  });
  test('purge compacts deleted title/body out of the active Hive file',
      () async {
    const privateMarker = 'REVOKED_SYNTHETIC_NOTIFICATION_ONLY';
    final box = Hive.box('notifications_box');
    await box.put('remove', {...row('remove'), 'body': privateMarker});
    await box.flush();
    final path = box.path!;
    expect(
        latin1.decode(await File(path).readAsBytes()).contains(privateMarker),
        true);
    await transition(deny);
    await box.flush();
    expect(
        latin1.decode(await File(path).readAsBytes()).contains(privateMarker),
        false);
    await box.close();
    final reopened = await Hive.openBox('notifications_box');
    expect(reopened.containsKey('remove'), false);
  });
  test('read flags are not borrowed from another owner of the same event key',
      () async {
    final box = Hive.box('notifications_box');
    await box.put('shared', {...row('shared', owner: 'uid-B'), 'read': true});
    await http.runWithClient(() => service.refreshFromServer(companyCode: 'C1'),
        () => MockClient((_) async => reply([row('shared')])));
    expect(box.get('shared')['recipient_uid'], 'uid-A');
    expect(box.get('shared')['read'], false);
  });
  test(
      'unknown permission loading state neither exposes cached content nor starts an HTTP fetch',
      () async {
    await Hive.box('notifications_box').put('old', row('old'));
    rights(allow, ['all'], loaded: false);
    var calls = 0;
    expect(service.getNotifications(companyCode: 'C1'), isEmpty);
    await http.runWithClient(
        () => service.refreshFromServer(companyCode: 'C1'),
        () => MockClient((_) async {
              calls++;
              return reply([]);
            }));
    expect(calls, 0);
  });
  test(
      'company switch during HTTP rejects the old reply and permits a fresh company fetch',
      () async {
    final requested = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      final old = service.refreshFromServer(companyCode: 'C1');
      await requested.future;
      service.setCompany('C2');
      await service.refreshFromServer(companyCode: 'C2');
      release.complete();
      await old;
      final box = Hive.box('notifications_box');
      expect(box.containsKey('old-company'), false);
      expect(box.get('new-company')['company_code'], 'C2');
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/settings'))
                return http.Response('{}', 200);
              if (!requested.isCompleted) {
                requested.complete();
                await release.future;
                return reply([row('old-company')]);
              }
              return reply([row('new-company', company: 'C2')]);
            }));
  });
}
