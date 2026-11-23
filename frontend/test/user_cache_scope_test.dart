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
import 'package:islam_app/services/user_service.dart';
import 'package:islam_app/services/admin_cache_events.dart';
import 'package:islam_app/services/company_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'commercial_queue_regression_test.dart' as identity;

http.Response reply(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
List<Map<String, dynamic>> rows(String name) => [
      {
        'email': 'target@example.invalid',
        'uid': 'target',
        'name': name,
        'company_code': 'C1',
        'status': 'active'
      }
    ];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = identity.FakeCore();
  FirebaseAuthPlatform.instance = identity.FakeAuth();
  late Directory dir;
  late UserService service;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('user_cache_scope_');
    Hive.init(dir.path);
    await Hive.openBox('users_box');
    await Hive.openBox('companies_box');
    SharedPreferences.setMockInitialValues(
        {'company_code': 'C1', 'user_email': 'owner@example.invalid'});
    identity.currentUid = 'uid-A';
    PermissionsService().debugSetPermissionsForTest({},
        role: 'admin', loaded: true, branches: ['B1']);
    service = UserService();
    await service.clearCache();
  });
  tearDown(() async {
    await service.clearCache();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  test('company display cache requires current root scope and reloads after hint', () async {
    PermissionsService().debugSetPermissionsForTest({}, role: 'super_admin', branches: ['all']);
    var calls = 0;
    final companies = CompanyService();
    await http.runWithClient(() async {
      await companies.fetchAllCompanies();
      expect(companies.hasSnapshot, true);
      expect(companies.getCompaniesFromHive().single['code'], 'C1');
      expect(calls, 1);
      AdminCacheEvents.companyDirectory();
      expect(companies.hasSnapshot, false);
      expect(companies.getCompaniesFromHive(), isEmpty);
      await companies.fetchAllCompanies();
      expect(calls, 2);
      PermissionsService().debugSetPermissionsForTest({}, role: 'employee', branches: ['B1']);
      expect(companies.getCompaniesFromHive(), isEmpty);
      await expectLater(companies.fetchAllCompanies(), throwsStateError);
      expect(calls, 2);
    }, () => MockClient((r) async {calls++; return reply([{'code':'C1','name':'One'}]);}));
  });
  test('empty verified directories reuse cache and a matching hint invalidates them', () async {
    var calls = 0;
    await http.runWithClient(() async {
      await service.ensureUsers(companyCode: 'C1');
      await service.ensureUsers(companyCode: 'C1');
      expect(calls, 1);
      AdminCacheEvents.userDirectory('C2');
      await service.ensureUsers(companyCode: 'C1');
      expect(calls, 1);
      AdminCacheEvents.userDirectory('C1');
      expect(service.hasUsersSnapshot(companyCode: 'C1'), false);
      await service.ensureUsers(companyCode: 'C1');
      expect(calls, 2);
    }, () => MockClient((r) async {calls++; return reply([]);}));
  });
  test(
      'epoch-only revocation purges the actual account cache without a later permissions notification',
      () async {
    await http.runWithClient(() => service.fetchAllUsers(companyCode: 'C1'),
        () => MockClient((request) async => reply(rows('private'))));
    final box = Hive.box('users_box');
    expect(box.isNotEmpty, true);
    final removed = box
        .watch()
        .firstWhere((event) => event.deleted)
        .timeout(const Duration(seconds: 2));
    ReadAuthorizationEpoch.invalidate();
    expect(service.getUsersFromHive(companyCode: 'C1'), isEmpty);
    await removed;
    expect(box.isEmpty, true);
  });
  test('legacy unbound lists never become trusted account cache', () async {
    await Hive.box('users_box').put('company_C1', rows('legacy'));
    await Hive.box('users_box').put('requests_pending', rows('legacy'));
    expect(service.getUsersFromHive(companyCode: 'C1'), isEmpty);
    expect(service.getRequestsFromHive(), isEmpty);
  });
  for (final kind in ['users', 'requests']) {
    Future<void> load() => kind == 'users'
        ? service.fetchAllUsers(companyCode: 'C1')
        : service.fetchPendingRequests();
    List<Map<String, dynamic>> cached() => kind == 'users'
        ? service.getUsersFromHive(companyCode: 'C1')
        : service.getRequestsFromHive();
    test('$kind cache is readable only after its original server read',
        () async {
      var calls = 0;
      await http.runWithClient(() async {
        await load();
        expect(cached().single['name'], 'fresh');
        expect(cached().single['name'], 'fresh');
      },
          () => MockClient((request) async {
                calls++;
                return reply(rows('fresh'));
              }));
      expect(calls, 1);
      identity.currentUid = 'uid-B';
      expect(cached(), isEmpty);
      identity.currentUid = 'uid-A';
      ReadAuthorizationEpoch.invalidate();
      expect(cached(), isEmpty);
    });
    for (final changed in ['owner', 'company', 'revoke-regrant']) {
      test('$kind late response cannot cross $changed', () async {
        final entered = Completer<void>(), release = Completer<void>();
        await http.runWithClient(() async {
          final loading = load();
          final rejected = expectLater(loading, throwsA(anything));
          await entered.future;
          if (changed == 'owner') identity.currentUid = 'uid-B';
          if (changed == 'company')
            await (await SharedPreferences.getInstance())
                .setString('company_code', 'C2');
          if (changed == 'revoke-regrant') {
            PermissionsService().setRole('employee');
            PermissionsService().setRole('admin');
          }
          release.complete();
          await rejected;
          expect(cached(), isEmpty);
          expect(Hive.box('users_box').isEmpty, true);
        },
            () => MockClient((request) async {
                  entered.complete();
                  await release.future;
                  return reply(rows('late'));
                }));
      });
    }
  }
  test('overlapping list reads cannot overwrite a newer response', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var calls = 0;
    await http.runWithClient(() async {
      final old = service.fetchAllUsers(companyCode: 'C1');
      await entered.future;
      await service.fetchAllUsers(companyCode: 'C1');
      release.complete();
      await old;
      expect(service.getUsersFromHive(companyCode: 'C1').single['name'], 'new');
    },
        () => MockClient((request) async {
              calls++;
              if (calls == 1) {
                entered.complete();
                await release.future;
                return reply(rows('old'));
              }
              return reply(rows('new'));
            }));
  });
  test(
      'scope event purges clean account cache while no-op notification preserves it',
      () async {
    await http.runWithClient(() => service.fetchAllUsers(companyCode: 'C1'),
        () => MockClient((request) async => reply(rows('fresh'))));
    PermissionsService().setAllowedBranches(['B1']);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(service.getUsersFromHive(companyCode: 'C1'), isNotEmpty);
    PermissionsService().setRole('employee');
    expect(service.getUsersFromHive(companyCode: 'C1'), isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(Hive.box('users_box').isEmpty, true);
  });
  test('company mismatch and malformed row fail instead of importing a list',
      () async {
    for (final value in [
      <dynamic>[
        {'company_code': 'C2', 'name': 'foreign'}
      ],
      <dynamic>['malformed'],
      {'not': 'a list'}
    ]) {
      await http.runWithClient(
          () => expectLater(
              service.fetchAllUsers(companyCode: 'C1'), throwsA(anything)),
          () => MockClient((request) async => reply(value)));
      expect(service.getUsersFromHive(companyCode: 'C1'), isEmpty);
    }
  });
  test(
      'owner change during the real Hive event cannot leave a late write readable',
      () async {
    var changed = false;
    final subscription = Hive.box('users_box').watch().listen((event) {
      if (!changed && event.value is List && (event.value as List).isNotEmpty) {
        changed = true;
        identity.currentUid = 'uid-B';
      }
    });
    await http.runWithClient(
        () => expectLater(
            service.fetchAllUsers(companyCode: 'C1'), throwsA(anything)),
        () => MockClient((request) async => reply(rows('late-write'))));
    expect(changed, true);
    expect(service.getUsersFromHive(companyCode: 'C1'), isEmpty);
    expect(Hive.box('users_box').isEmpty, true);
    await subscription.cancel();
  });
  for (final action in [
    'add',
    'edit',
    'delete',
    'reset',
    'approve',
    'reject'
  ]) {
    test('acknowledged $action never launches a different owner cache refresh',
        () async {
      var calls = 0;
      await http.runWithClient(() async {
        switch (action) {
          case 'add':
            await service.addUser(
                name: 'Target',
                phoneNumber: 'synthetic',
                branchCode: 'B1',
                role: 'employee',
                companyCode: 'C1');
          case 'edit':
            await service.editUser(
                email: 'target@example.invalid',
                name: 'Target',
                companyCode: 'C1');
          case 'delete':
            await service.deleteUser(
                email: 'target@example.invalid', companyCode: 'C1');
          case 'reset':
            await service.resetPendingUser(
                email: 'target@example.invalid', companyCode: 'C1');
          case 'approve':
            await service.approveRequest(
                requestId: 'request', role: 'employee', companyCode: 'C1');
          case 'reject':
            await service.rejectRequest(requestId: 'request');
        }
      },
          () => MockClient((request) async {
                calls++;
                expect(request.method, isNot('GET'));
                identity.currentUid = 'uid-B';
                return reply({});
              }));
      expect(calls, 1);
      expect(service.getUsersFromHive(companyCode: 'C1'), isEmpty);
    });
  }
  test('the first real Hive list event already has its original read binding',
      () async {
    final observed = <String>[];
    final subscription = Hive.box('users_box').watch().listen((event) {
      if (event.value is List && (event.value as List).isNotEmpty) {
        observed.add(service.getUsersFromHive(companyCode: 'C1').single['name']
            as String);
      }
    });
    await http.runWithClient(() => service.fetchAllUsers(companyCode: 'C1'),
        () => MockClient((request) async => reply(rows('bound-once'))));
    await Future<void>.delayed(Duration.zero);
    expect(observed, ['bound-once']);
    await subscription.cancel();
  });
  test('explicit cache clear cancels already in-flight list materialization',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      final reading = service.fetchAllUsers(companyCode: 'C1');
      await entered.future;
      await service.clearCache();
      release.complete();
      await reading;
      expect(service.getUsersFromHive(companyCode: 'C1'), isEmpty);
      expect(Hive.box('users_box').isEmpty, true);
    },
        () => MockClient((request) async {
              entered.complete();
              await release.future;
              return reply(rows('cleared'));
            }));
  });
}
