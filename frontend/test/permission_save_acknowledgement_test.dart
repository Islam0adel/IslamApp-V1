import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'commercial_queue_regression_test.dart' as f;
import 'permission_editor_snapshot_test.dart' as editorFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory dir;
  const email = 'fixture@example.invalid';
  final old = {
    'المبيعات': {'إضافة': true}
  };
  final proposed = {
    'المبيعات': {'تعديل': true, 'حذف': true}
  };
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('permissions_ack_');
    Hive.init(dir.path);
    await Hive.openBox('coding_box');
    SharedPreferences.setMockInitialValues(
        {'user_email': email, 'company_code': 'C1'});
    f.currentUid = 'uid-A';
    PermissionsService()
        .debugSetPermissionsForTest(old, role: 'employee', branches: ['B1']);
    await Hive.box('coding_box').put('permissions_$email', old);
    await Hive.box('coding_box').put('allowed_branches_$email', ['B1']);
    await Hive.box('coding_box').put('hr_viewable_employees_$email', ['E1']);
  });
  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  for (final status in [403, 409, 500, 503]) {
    test(
        'rejected permission save never changes current rights or clean cache $status',
        () async {
      await http.runWithClient(() async {
        await expectLater(
            PermissionsService().savePermissions(proposed,
                allowedBranches: ['all'], clearHrViewableEmployees: true),
            throwsA(anything));
      },
          () => MockClient((request) async =>
              http.Response('{"detail":"fixture refusal"}', status)));
      expect(PermissionsService().canDeleteSale, false);
      expect(PermissionsService().canEditSale, false);
      expect(Hive.box('coding_box').get('permissions_$email'), old);
      expect(Hive.box('coding_box').get('allowed_branches_$email'), ['B1']);
      expect(
          Hive.box('coding_box').get('hr_viewable_employees_$email'), ['E1']);
    });
  }
  test('clearing employee visibility sends the actual server clear flag',
      () async {
    Map? body;
    await http.runWithClient(
        () => PermissionsService().savePermissions(old,
            targetEmail: 'other@example.invalid',
            clearHrViewableEmployees: true),
        () => MockClient((request) async {
              body = jsonDecode(request.body) as Map;
              return http.Response('{}', 200);
            }));
    expect(body!['clear_hr_viewable_employees'], true);
  });
  test('authorized save does not change cache before acknowledgement',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      final save = PermissionsService()
          .savePermissions(proposed, allowedBranches: ['B2']);
      await entered.future;
      expect(Hive.box('coding_box').get('permissions_$email'), old);
      expect(PermissionsService().canDeleteSale, false);
      release.complete();
      await save;
      expect(Hive.box('coding_box').get('permissions_$email'), proposed);
      expect(PermissionsService().canDeleteSale, true);
    },
        () => MockClient((request) async {
              entered.complete();
              await release.future;
              return http.Response('{}', 200);
            }));
  });
  for (final change in ['owner', 'company', 'revoke', 'regrant']) {
    test(
        'acknowledged save stays successful without stale materialization after $change',
        () async {
      final entered = Completer<void>(), release = Completer<void>();
      var posts = 0;
      await http.runWithClient(() async {
        final save = PermissionsService().savePermissions(proposed,
            allowedBranches: ['all'], clearHrViewableEmployees: true);
        await entered.future;
        if (change == 'owner') f.currentUid = 'uid-B';
        if (change == 'company')
          await (await SharedPreferences.getInstance())
              .setString('company_code', 'C2');
        if (change == 'revoke' || change == 'regrant') {
          PermissionsService()
              .debugSetPermissionsForTest(old, role: 'employee');
          if (change == 'regrant')
            PermissionsService()
                .debugSetPermissionsForTest(old, role: 'employee');
        }
        release.complete();
        await save;
      },
          () => MockClient((request) async {
                posts++;
                entered.complete();
                await release.future;
                return http.Response('{}', 200);
              }));
      expect(posts, 1);
      expect(Hive.box('coding_box').get('permissions_$email'), old);
      expect(Hive.box('coding_box').get('allowed_branches_$email'), ['B1']);
      expect(
          Hive.box('coding_box').get('hr_viewable_employees_$email'), ['E1']);
      expect(PermissionsService().canDeleteSale, false);
    });
  }
  test('lost response retains original permission cache', () async {
    await http.runWithClient(() async {
      await expectLater(
          PermissionsService().savePermissions(proposed), throwsA(anything));
    },
        () => MockClient((request) async =>
            throw const SocketException('fixture response lost')));
    expect(Hive.box('coding_box').get('permissions_$email'), old);
    expect(PermissionsService().canDeleteSale, false);
  });
  test(
      'materialized maps and lists match the submitted payload, not later editor mutations',
      () async {
    final changed = {
      'المبيعات': {'حذف': true}
    };
    final branches = ['B2'];
    final entered = Completer<void>(), release = Completer<void>();
    Map? sent;
    await http.runWithClient(() async {
      final save = PermissionsService()
          .savePermissions(changed, allowedBranches: branches);
      await entered.future;
      changed['المبيعات']!['حذف'] = false;
      branches.add('B3');
      release.complete();
      await save;
    },
        () => MockClient((request) async {
              sent = jsonDecode(request.body) as Map;
              entered.complete();
              await release.future;
              return http.Response('{}', 200);
            }));
    expect(sent!['permissions'], {
      'المبيعات': {'حذف': true}
    });
    expect(sent!['allowed_branches'], ['B2']);
    expect(Hive.box('coding_box').get('permissions_$email'), {
      'المبيعات': {'حذف': true}
    });
    expect(Hive.box('coding_box').get('allowed_branches_$email'), ['B2']);
  });

  test(
      'versioned editor read is targeted and never imports target rights into current cache',
      () async {
    final json = editorFixture.editorJson();
    final value = await http.runWithClient(
        () => PermissionsService().loadPermissionEditor(json['email']),
        () => MockClient((request) async {
              expect(request.method, 'GET');
              expect(request.url.pathSegments.last, json['email']);
              return http.Response(jsonEncode(json), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    expect(value.uid, 'target');
    expect(value.version, 'v1');
    expect(value.revision, 2);
    expect(Hive.box('coding_box').get('permissions_$email'), old);
    expect(PermissionsService().canDeleteSale, false);
  });
  test(
      'write sends exact target, source and policy versions with separate startup',
      () async {
    Map? sent;
    await http.runWithClient(
        () => PermissionsService().savePermissions(old,
            targetEmail: 'target@example.invalid',
            expectedTargetUid: 'target-uid',
            expectedProfileVersion: 'source-v7',
            expectedPolicyRevision: 8,
            startupBranchCode: 'B2'),
        () => MockClient((request) async {
              sent = jsonDecode(request.body) as Map;
              return http.Response('{}', 200);
            }));
    expect(sent!['expected_target_uid'], 'target-uid');
    expect(sent!['expected_profile_version'], 'source-v7');
    expect(sent!['expected_policy_revision'], 8);
    expect(sent!['startup_branch_code'], 'B2');
    expect(sent!.containsKey('allowed_branches'), false);
    expect(sent!.containsKey('hr_viewable_employees'), false);
  });
  test('editor refuses a different returned target identity', () async {
    await http.runWithClient(
        () => expectLater(
            PermissionsService().loadPermissionEditor('other@example.invalid'),
            throwsA(anything)),
        () => MockClient((request) async => http.Response(
            jsonEncode(editorFixture.editorJson()), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    expect(Hive.box('coding_box').get('permissions_$email'), old);
  });
  test('late editor read is discarded when owner changes', () async {
    final entered = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      final reading =
          PermissionsService().loadPermissionEditor('target@example.invalid');
      final rejected = expectLater(reading, throwsA(anything));
      await entered.future;
      f.currentUid = 'uid-B';
      release.complete();
      await rejected;
    },
        () => MockClient((request) async {
              entered.complete();
              await release.future;
              return http.Response(jsonEncode(editorFixture.editorJson()), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    expect(Hive.box('coding_box').get('permissions_$email'), old);
  });
  test(
      'editor handoff keeps its original epoch and cannot upgrade an old result',
      () async {
    final result = await http.runWithClient(
        () =>
            PermissionsService().loadPermissionEditor('target@example.invalid'),
        () => MockClient((request) async => http.Response(
            jsonEncode(editorFixture.editorJson()), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    expect(result.readScope!.isCurrent, true);
    ReadAuthorizationEpoch.invalidate();
    expect(result.readScope!.isCurrent, false);
    final next = await ReadAuthorizationSnapshot.capture();
    expect(() => result.withReadScope(next), throwsStateError);
  });
  test(
      'target directory imports only minimal fields and never target rights into cache',
      () async {
    final value = await http.runWithClient(
        () => PermissionsService().loadPermissionTargets('C1'),
        () => MockClient((request) async {
              expect(request.url.path.endsWith('/permission-editor-targets'),
                  true);
              expect(request.url.queryParameters['company_code'], 'C1');
              return http.Response(
                  jsonEncode({
                    'company_code': 'C1',
                    'users': [
                      {
                        'email': 'target@example.invalid',
                        'uid': 'target',
                        'name': 'Target',
                        'role': 'employee',
                        'company_code': 'C1',
                        'phone': 'private',
                        'username': 'private',
                        'salary': 999,
                        'permissions': proposed
                      }
                    ]
                  }),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    expect(value.users.single.keys.toSet(),
        {'email', 'uid', 'name', 'role', 'company_code'});
    expect(value.readScope.isCurrent, true);
    expect(Hive.box('coding_box').get('permissions_$email'), old);
    expect(PermissionsService().canDeleteSale, false);
  });
  for (final change in ['owner', 'company', 'epoch']) {
    test('late minimal directory cannot survive $change change', () async {
      final entered = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        final reading = PermissionsService().loadPermissionTargets('C1');
        final rejected = expectLater(reading, throwsA(anything));
        await entered.future;
        if (change == 'owner') f.currentUid = 'uid-B';
        if (change == 'company')
          await (await SharedPreferences.getInstance())
              .setString('company_code', 'C2');
        if (change == 'epoch') ReadAuthorizationEpoch.invalidate();
        release.complete();
        await rejected;
      },
          () => MockClient((request) async {
                entered.complete();
                await release.future;
                return http.Response('{"company_code":"C1","users":[]}', 200);
              }));
    });
  }
  for (final value in [
    {'company_code': 'C2', 'users': []},
    {
      'company_code': 'C1',
      'users': [
        {
          'email': 'target',
          'uid': 'target',
          'name': 'Target',
          'role': 'employee',
          'company_code': 'C2'
        }
      ]
    },
    {
      'company_code': 'C1',
      'users': [
        {
          'email': 'target',
          'uid': 'target',
          'role': 'employee',
          'company_code': 'C1'
        }
      ]
    },
  ]) {
    test('target directory refuses malformed or foreign selector rows $value',
        () async {
      await http.runWithClient(
          () => expectLater(PermissionsService().loadPermissionTargets('C1'),
              throwsA(anything)),
          () => MockClient(
              (request) async => http.Response(jsonEncode(value), 200)));
    });
  }
}
