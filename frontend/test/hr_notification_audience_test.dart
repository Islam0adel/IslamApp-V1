// Actual client services and on-disk Hive. All identities, HTTP and sockets are synthetic.
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
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:islam_app/services/auth_http.dart';
import 'package:islam_app/services/notifications_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/websocket_sync_service.dart';
import 'commercial_queue_regression_test.dart' as f;
import 'notification_cache_revocation_test.dart' as n;

void rights(String kind) => PermissionsService().debugSetPermissionsForTest(
    {
      ...n.allow,
      'الموارد البشرية': {
        'canViewOwnHRData': kind == 'own',
        'canViewEmployees': kind != 'own',
      },
    },
    role: 'employee',
    loaded: true,
    branches: ['B1'],
    viewableEmployees: kind == 'limited' ? ['E1'] : []);

Map<String, dynamic> item(String id,
        {String? code,
        bool self = false,
        String company = 'C1',
        String owner = 'uid-A'}) =>
    {
      ...n.row(id, company: company, owner: owner, section: 'hr_employees'),
      if (code != null)
        'notification_scope': {'employee_code': code, 'is_self': self},
    };
Map<String, dynamic> event(String id,
        {String? code, bool self = false, String company = 'C1'}) =>
    {
      'type': 'employee',
      'event_id': id,
      'action': 'update',
      'data': {
        'company_code': company,
        'branch_code': 'B1',
        'code': code ?? 'E2',
        'name': 'SYNTHETIC_HR_DETAIL'
      },
      if (code != null)
        'notification_scope': {'employee_code': code, 'is_self': self},
    };
Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline))
      fail('Synthetic asynchronous checkpoint timed out');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class Sink implements WebSocketSink {
  final values = <dynamic>[];
  bool closed = false;
  @override
  void add(dynamic value) => values.add(value);
  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Channel implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  @override
  final Sink sink = Sink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready async {}
  void emit(Map<String, dynamic> value) => incoming.add(jsonEncode(value));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  final service = NotificationsService.instance;
  late Directory directory;
  final sockets = <Channel>[];
  final clients = <WebSocketSyncService>[];
  WebSocketSyncService client() {
    final ws = WebSocketSyncService(channelFactory: (_) {
      final channel = Channel();
      sockets.add(channel);
      return channel;
    });
    clients.add(ws);
    return ws;
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('hr_notification_');
    Hive.init(directory.path);
    for (final name in [
      'coding_box',
      'daily_transactions_box',
      'inventory_box',
      'supplier_box',
      'supplier_settlement_box',
      'notifications_box',
      'notification_settings_box'
    ]) {
      await Hive.openBox(name);
    }
    SharedPreferences.setMockInitialValues({'company_code': 'C1'});
    f.currentUid = 'uid-A';
    rights('own');
    service.finishHRAuthorization(await service.invalidateHRAuthorization(
        companyCode: 'C1', uid: 'uid-A'));
  });
  tearDown(() async {
    for (final ws in clients) {
      ws.disconnect();
    }
    for (final socket in sockets) {
      await socket.incoming.close();
    }
    clients.clear();
    sockets.clear();
    await Hive.close();
    directory.deleteSync(recursive: true);
  });
  test('socket binding then Home joins settings and history without resetting scope', () async {
    var settings = 0, history = 0;
    final release = Completer<void>();
    await http.runWithClient(() async {
      service.bindCompany('C1');
      final firstSettings = service.loadSettingsFromServer();
      final firstHistory = service.refreshFromServer(companyCode:'C1');
      await until(() => settings == 1 && history == 1);
      service.setCompany('C1'); // Home mounting in the same owner/cache.
      final joinedSettings = service.loadSettingsFromServer();
      final joinedHistory = service.refreshFromServer(companyCode:'C1');
      await Future<void>.delayed(const Duration(milliseconds:20));
      expect(settings,1); expect(history,1);
      release.complete();
      await Future.wait([firstSettings,firstHistory,joinedSettings,joinedHistory]);
      service.setCompany('C1');
      await Future<void>.delayed(const Duration(milliseconds:20));
      expect(settings,1); expect(history,1);
      // Reconnect still explicitly rechecks, even for same company.
      await service.loadSettingsFromServer();
      await service.refreshFromServer(companyCode:'C1');
      expect(settings,2); expect(history,2);
    },()=>MockClient((r) async {
      if(r.url.path.endsWith('/settings')) {settings++;await release.future;return http.Response('{}',200);}
      history++;await release.future;return n.reply([]);
    }));
  });
  test('settings-change during held fetch coalesces into one fresh follow-up', () async {
    var calls=0;
    final release=Completer<void>();
    await http.runWithClient(() async {
      service.bindCompany('C1');
      final first=service.loadSettingsFromServer();
      await until(()=>calls==1);
      final second=service.loadSettingsFromServer(force:true);
      service.loadSettingsFromServer(force:true);
      release.complete();
      await Future.wait([first,second]);
      expect(calls,2);
    },()=>MockClient((r) async {calls++;if(calls==1)await release.future;return http.Response('{}',200);}));
  });
  for (final kind in ['own', 'limited', 'broad']) {
    for (final code in <String?>['E1', 'E2', null]) {
      final allowed = kind == 'broad' || code == 'E1';
      for (final mode in ['incremental', 'unread', 'live']) {
        test('$kind $mode target=$code allowed=$allowed', () async {
          rights(kind);
          if (mode == 'live') {
            await service.handleSyncEvent(
                event('event', code: code, self: code == 'E1'));
          } else {
            await http.runWithClient(
                () => mode == 'unread'
                    ? service.refreshUnreadFromServer(companyCode: 'C1')
                    : service.refreshFromServer(companyCode: 'C1'),
                () => MockClient((_) async =>
                    n.reply([item('event', code: code, self: code == 'E1')])));
          }
          expect(Hive.box('notifications_box').isNotEmpty, allowed);
          expect(
              service.getNotifications(companyCode: 'C1').isNotEmpty, allowed);
        });
      }
    }
  }
  test(
      'self flag without employee code and foreign flag on self code fail closed',
      () async {
    for (final scope in [
      {'is_self': true},
      {'is_self': false, 'employee_code': 'E1'}
    ]) {
      await service
          .handleSyncEvent({...event('rejected'), 'notification_scope': scope});
    }
    expect(Hive.box('notifications_box').isEmpty, true);
  });
  test(
      'HR invalidation removes only active owner/company HR and compacts the file',
      () async {
    final box = Hive.box('notifications_box');
    const marker = 'SYNTHETIC_OLD_HR_NOTIFICATION';
    await box.putAll({
      'old': {...item('old', code: 'E1', self: true), 'body': marker},
      'owner': item('owner', owner: 'uid-B', code: 'E2'),
      'company': item('company', company: 'C2', code: 'E2'),
      'ordinary': n.row('ordinary'),
    });
    await box.flush();
    final path = box.path!;
    expect(
        latin1.decode(await File(path).readAsBytes()).contains(marker), true);
    final token = await service.invalidateHRAuthorization(
        companyCode: 'C1', uid: 'uid-A');
    expect(box.keys.toSet(), {'owner', 'company', 'ordinary'});
    expect(
        latin1.decode(await File(path).readAsBytes()).contains(marker), false);
    expect(service.getNotifications(companyCode: 'C1').map((r) => r['id']),
        ['ordinary']);
    expect(service.finishHRAuthorization(token), true);
  });
  for (final unread in [false, true]) {
    test(
        'in-flight HTTP cannot refill HR or advance its cursor after invalidation unread=$unread',
        () async {
      final entered = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        final work = unread
            ? service.refreshUnreadFromServer(companyCode: 'C1')
            : service.refreshFromServer(companyCode: 'C1');
        await entered.future;
        final token = await service.invalidateHRAuthorization(
            companyCode: 'C1', uid: 'uid-A');
        service.finishHRAuthorization(token);
        release.complete();
        await work;
        expect(Hive.box('notifications_box').isEmpty, true);
        expect(
            Hive.box('notification_settings_box')
                .get('notification_cursor_uid-A_C1'),
            isNull);
      },
          () => MockClient((_) async {
                entered.complete();
                await release.future;
                return n.reply([item('late', code: 'E1', self: true)]);
              }));
    });
  }
  test('old authorization token cannot reopen the cache for a newer change',
      () async {
    final old = await service.invalidateHRAuthorization(
        companyCode: 'C1', uid: 'uid-A');
    final current = await service.invalidateHRAuthorization(
        companyCode: 'C1', uid: 'uid-A');
    expect(service.finishHRAuthorization(old), false);
    await service.handleSyncEvent(event('blocked', code: 'E1', self: true));
    expect(Hive.box('notifications_box').isEmpty, true);
    expect(service.finishHRAuthorization(current), true);
    await service.handleSyncEvent(event('fresh', code: 'E1', self: true));
    expect(Hive.box('notifications_box').containsKey('fresh'), true);
  });
  test(
      'overlapping real socket controls serialize callbacks and fetch only after the latest finishes',
      () async {
    final ws = client();
    final first = Completer<void>(), second = Completer<void>();
    var callbacks = 0, calls = 0;
    ws.onPermissionsChanged = ({required bool resync}) async {
      callbacks++;
      if (callbacks == 1)
        await first.future;
      else
        await second.future;
    };
    await http.runWithClient(() async {
      await ws.connect('C1');
      final socket = sockets.single;
      socket.emit({'type': 'permissions_changed'});
      await until(() => callbacks == 1);
      socket.emit({'type': 'permissions_changed'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(callbacks, 1);
      first.complete();
      await until(() => callbacks == 2);
      await Hive.box('notifications_box')
          .put('cached', item('cached', code: 'E1', self: true));
      expect(service.getNotifications(companyCode: 'C1'), isEmpty);
      await service.refreshFromServer(companyCode: 'C1');
      expect(calls, 0);
      second.complete();
      await until(() => calls == 1);
      await until(() => Hive.box('notifications_box').containsKey('fresh'));
      expect(service.getNotifications(companyCode: 'C1').isNotEmpty, true);
      expect(calls, 1);
      await ws.debugAuthorizationRefresh;
    },
        () => MockClient((_) async {
              calls++;
              return n.reply([item('fresh', code: 'E1', self: true)]);
            }));
  });
  test(
      'socket from previous owner cannot write cache or invoke new-owner permission callback',
      () async {
    rights('broad');
    final ws = client();
    var callbacks = 0;
    ws.onPermissionsChanged = ({required bool resync}) {
      callbacks++;
    };
    await ws.connect('C1');
    final old = sockets.single;
    f.currentUid = 'uid-B';
    old.emit(event('wrong-owner', code: 'E2'));
    old.emit({'type': 'permissions_changed'});
    await until(() => old.sink.closed);
    expect(Hive.box('notifications_box').isEmpty, true);
    expect(Hive.box('coding_box').isEmpty, true);
    expect(callbacks, 0);
  });
  test(
      'new owner connection supersedes an in-flight token read without old state clobber',
      () async {
    final ws = client();
    final old = ws.connect('C1');
    f.currentUid = 'uid-B';
    final next = ws.connect('C1');
    await old;
    await next;
    expect(sockets.length, 1);
    expect(sockets.single.sink.values.length, 1);
    expect(jsonDecode(sockets.single.sink.values.single)['type'], 'auth');
  });
  test(
      'late old-company socket message cannot write after reconnect to another company',
      () async {
    rights('broad');
    final ws = client();
    await ws.connect('C1');
    final old = sockets.single;
    await ws.connect('C2');
    expect(sockets.length, 2);
    expect(old.sink.closed, true);
    old.emit(event('old-company', code: 'E2'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(Hive.box('notifications_box').isEmpty, true);
    expect(Hive.box('coding_box').isEmpty, true);
  });
  test('connected callback waits for successful authorization reconciliation',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    var connected = 0;
    final ws = client();
    ws.onPermissionsChanged = ({required bool resync}) async {
      entered.complete();
      await release.future;
    };
    ws.onConnected = () {
      connected++;
    };
    await http.runWithClient(() async {
      await ws.connect('C1');
      sockets.single.emit({'type': 'auth_success', 'company_code': 'C1'});
      await entered.future;
      expect(ws.isConnected, true);
      expect(ws.authorizationReady, false);
      expect(connected, 0);
      release.complete();
      await ws.debugAuthorizationRefresh;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ws.authorizationReady, true);
      expect(connected, 1);
    }, () => MockClient((_) async => n.reply([])));
  });
  test('failed authorization never runs connected data callback', () async {
    var connected = 0;
    final ws = client();
    ws.onPermissionsChanged = ({required bool resync}) async {
      throw StateError('synthetic failed verification');
    };
    ws.onConnected = () {
      connected++;
    };
    await ws.connect('C1');
    sockets.single.emit({'type': 'auth_success', 'company_code': 'C1'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await ws.debugAuthorizationRefresh;
    expect(ws.isConnected, true);
    expect(ws.authorizationReady, false);
    expect(connected, 0);
  });
  test(
      'verified business connection proceeds while notification history is blocked',
      () async {
    final ws = client();
    final verified = Completer<void>(), releaseScope = Completer<void>();
    final historyStarted = Completer<void>(),
        releaseHistory = Completer<http.Response>();
    var connected = 0;
    ws.onPermissionsChanged = ({required bool resync}) async {
      verified.complete();
      await releaseScope.future;
    };
    final requestOrder = <String>[];
    ws.onConnected = () {
      connected++;
      unawaited(AuthHttp.get(Uri.parse('https://test.invalid/business')));
    };
    await http.runWithClient(() async {
      await ws.connect('C1');
      sockets.single.emit({'type': 'auth_success', 'company_code': 'C1'});
      await verified.future;
      expect(connected, 0);
      expect(ws.authorizationReady, false);
      releaseScope.complete();
      await historyStarted.future;
      await until(() => connected == 1);
      expect(ws.authorizationReady, true);
      await until(() => requestOrder.contains('/business'));
      expect(requestOrder.indexOf('/notifications'), lessThan(requestOrder.indexOf('/business')));
      expect(releaseHistory.isCompleted, false);
      releaseHistory.complete(n.reply([]));
      await ws.debugAuthorizationRefresh;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    },
        () => MockClient((r) async {
              requestOrder.add(r.url.path);
              if (r.url.path.endsWith('/business')) return http.Response('{}', 200);
              if (r.url.path.endsWith('/settings'))
                return http.Response('{}', 200);
              if (!historyStarted.isCompleted) historyStarted.complete();
              return releaseHistory.future;
            }));
  });
  test(
      'authenticated reconnect removes stale offline HR before one history refresh',
      () async {
    final box = Hive.box('notifications_box');
    await box.put('stale', item('stale', code: 'E1', self: true));
    await box.put('ordinary', n.row('ordinary'));
    var calls = 0;
    final ws = client();
    await http.runWithClient(() async {
      await ws.connect('C1');
      sockets.single.emit({'type': 'auth_success', 'company_code': 'C1'});
      await until(() => calls == 1);
      await ws.debugAuthorizationRefresh;
      expect(box.containsKey('stale'), false);
      expect(box.containsKey('ordinary'), true);
      expect(ws.isConnected, true);
      f.currentUid = 'uid-B';
      expect(ws.isConnected, false);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/settings'))
                return http.Response('{}', 200);
              calls++;
              return n.reply([]);
            }));
  });
  for (final change in ['authorization', 'owner']) {
    test('live notification awaiting settings cannot survive $change change',
        () async {
      final entered = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        service.setCompany('C1');
        await entered.future;
        final work =
            service.handleSyncEvent(event('late-live', code: 'E1', self: true));
        if (change == 'owner') {
          f.currentUid = 'uid-B';
        } else {
          final token = await service.invalidateHRAuthorization(
              companyCode: 'C1', uid: 'uid-A');
          service.finishHRAuthorization(token);
        }
        release.complete();
        await work;
        expect(Hive.box('notifications_box').isEmpty, true);
      },
          () => MockClient((request) async {
                if (request.url.path.endsWith('/settings')) {
                  if (!entered.isCompleted) entered.complete();
                  await release.future;
                  return http.Response('{}', 200);
                }
                return n.reply([]);
              }));
    });
  }
  for (final changed in ['owner', 'company']) {
    test('$changed switch resets HR hold without accepting an old token',
        () async {
      await http.runWithClient(() async {
        final token = await service.invalidateHRAuthorization(
            companyCode: 'C1', uid: 'uid-A');
        final company = changed == 'company' ? 'C2' : 'C1';
        if (changed == 'owner') f.currentUid = 'uid-B';
        service.setCompany(company);
        expect(service.finishHRAuthorization(token), false);
        await service.handleSyncEvent(
            event('new-scope', code: 'E1', self: true, company: company));
        await service.refreshFromServer(companyCode: company);
        expect(Hive.box('notifications_box').get('new-scope')['recipient_uid'],
            f.currentUid);
      },
          () => MockClient((request) async =>
              request.url.path.endsWith('/settings')
                  ? http.Response('{}', 200)
                  : n.reply([])));
    });
  }
  test(
      'directory controls need authenticated current-company socket and never import payload',
      () async {
    final ws = client();
    final initial = WebSocketSyncService.userDirectoryChanges.value.revision;
    await http.runWithClient(() async {
      await ws.connect('C1');
      sockets.single.emit({
        'type': 'user_directory_changed',
        'data': {'company_code': 'C1'}
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(WebSocketSyncService.userDirectoryChanges.value.revision, initial);
      sockets.single.emit({'type': 'auth_success', 'company_code': 'C1'});
      await until(() => ws.isConnected);
      await ws.debugAuthorizationRefresh;
      expect(WebSocketSyncService.userDirectoryChanges.value.revision,
          initial + 1);
      final coding = Map.from(Hive.box('coding_box').toMap());
      final notices = Map.from(Hive.box('notifications_box').toMap());
      sockets.single.emit({
        'type': 'user_directory_changed',
        'data': {'company_code': 'C2'}
      });
      sockets.single
          .emit({'type': 'user_directory_changed', 'data': 'malformed'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(WebSocketSyncService.userDirectoryChanges.value.revision,
          initial + 1);
      sockets.single.emit({
        'type': 'user_directory_changed',
        'data': {
          'company_code': 'C1',
          'name': 'private',
          'permissions': {'bad': true}
        }
      });
      await until(() =>
          WebSocketSyncService.userDirectoryChanges.value.revision ==
          initial + 2);
      expect(WebSocketSyncService.userDirectoryChanges.value.company, 'C1');
      expect(Hive.box('coding_box').toMap(), coding);
      expect(Hive.box('notifications_box').toMap(), notices);
      f.currentUid = 'uid-B';
      sockets.single.emit({
        'type': 'user_directory_changed',
        'data': {'company_code': 'C1'}
      });
      await until(() => sockets.single.sink.closed);
      expect(WebSocketSyncService.userDirectoryChanges.value.revision,
          initial + 2);
    },
        () => MockClient((request) async =>
            request.url.path.endsWith('/settings')
                ? http.Response('{}', 200)
                : n.reply([])));
  });
}
