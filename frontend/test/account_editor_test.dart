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
import 'package:islam_app/services/account_editor_snapshot.dart';
import 'package:islam_app/services/user_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'commercial_queue_regression_test.dart' as identity;

const target = 'target@example.invalid';
Map<String, dynamic> response({bool edit = true, bool status = false}) => {
      'document_id': target,
      'uid': 'target-uid',
      'company_code': 'C1',
      'profile_version': 'source-version-1',
      'company_policy_revision': 4,
      'company_policy_active': true,
      'name': 'Fresh target',
      'role': 'employee',
      'status': 'active',
      'is_active': true,
      'can_edit': edit,
      'can_change_status': status,
      'can_change_role': false,
      if (edit) ...{
        'phone_number': '01000000000',
        'username': 'fresh_name',
        'startup_branch_code': 'B2',
        'allowed_branches': ['B2']
      },
      'branch_choices': edit
          ? [
              {'code': 'B2', 'name': 'Second'}
            ]
          : [],
    };
http.Response reply(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = identity.FakeCore();
  FirebaseAuthPlatform.instance = identity.FakeAuth();
  late Directory dir;
  late UserService service;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('account_editor_');
    Hive.init(dir.path);
    await Hive.openBox('users_box');
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
  test(
      'current API editor carries exact original identity and versions to save',
      () async {
    final seen = <http.Request>[];
    await http.runWithClient(() async {
      final editor = await service.loadAccountEditor(target);
      expect(editor.data['username'], 'fresh_name');
      expect(editor.branches.single['code'], 'B2');
      await service.editUser(
          email: target, name: 'Changed', companyCode: 'C1', editor: editor);
    },
        () => MockClient((request) async {
              seen.add(request);
              if (request.url.path.contains('/user-editor/'))
                return reply(response());
              if (request.method == 'PUT') {
                final body = jsonDecode(request.body);
                expect(body['expected_target_uid'], 'target-uid');
                expect(body['expected_profile_version'], 'source-version-1');
                expect(body['expected_policy_revision'], 4);
                expect(body.containsKey('allowed_branches'), false);
                expect(body.containsKey('hr_viewable_employees'), false);
                return reply({'status': 'success'});
              }
              return reply(<dynamic>[]);
            }));
    expect(seen.map((request) => request.method), ['GET', 'PUT', 'GET']);
  });
  for (final change in ['owner', 'company', 'epoch']) {
    test('late metadata response cannot cross $change', () async {
      final entered = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        final pending = service.loadAccountEditor(target);
        final rejected = expectLater(pending, throwsA(anything));
        await entered.future;
        if (change == 'owner') identity.currentUid = 'uid-B';
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
                return reply(response());
              }));
    });
    test('loaded editor cannot be rebound after $change', () async {
      var writes = 0;
      await http.runWithClient(() async {
        final editor = await service.loadAccountEditor(target);
        if (change == 'owner') identity.currentUid = 'uid-B';
        if (change == 'company')
          await (await SharedPreferences.getInstance())
              .setString('company_code', 'C2');
        if (change == 'epoch') ReadAuthorizationEpoch.invalidate();
        await expectLater(
            service.editUser(email: target, name: 'No', editor: editor),
            throwsA(anything));
      },
          () => MockClient((request) async {
                if (request.method != 'GET') writes++;
                return reply(response());
              }));
      expect(writes, 0);
    });
  }
  for (final bad in [
    'target',
    'company',
    'version',
    'revision',
    'flag',
    'choices'
  ]) {
    test('rejects malformed or mismatched $bad response', () async {
      final value = response();
      switch (bad) {
        case 'target':
          value['document_id'] = 'another@example.invalid';
        case 'company':
          value['company_code'] = 'C2';
        case 'version':
          value['profile_version'] = '';
        case 'revision':
          value['company_policy_revision'] = '4';
        case 'flag':
          value['can_edit'] = 'true';
        case 'choices':
          value['branch_choices'] = [
            {'code': 'B2'}
          ];
      }
      await http.runWithClient(
          () =>
              expectLater(service.loadAccountEditor(target), throwsA(anything)),
          () => MockClient((request) async => reply(value)));
    });
  }
  test('status-only editor never manufactures blank metadata updates',
      () async {
    var writes = 0;
    await http.runWithClient(() async {
      final editor = await service.loadAccountEditor(target);
      expect(editor.data.containsKey('phone_number'), false);
      expect(editor.data.containsKey('username'), false);
      expect(editor.branches, isEmpty);
      await expectLater(
          service.editUser(email: target, name: 'No', editor: editor),
          throwsA(anything));
      await service.editUser(
          email: target,
          status: 'suspended',
          editor: editor,
          companyCode: 'C1');
    },
        () => MockClient((request) async {
              if (request.url.path.contains('/user-editor/'))
                return reply(response(edit: false, status: true));
              if (request.method == 'PUT') {
                writes++;
                final body = jsonDecode(request.body);
                for (final field in [
                  'name',
                  'phone_number',
                  'username',
                  'branch_code',
                  'role'
                ]) {
                  expect(body.containsKey(field), false);
                }
                return reply({'status': 'success'});
              }
              return reply(<dynamic>[]);
            }));
    expect(writes, 1);
  });
  test('saved edit with failed list refresh is not reported as failed mutation',
      () async {
    var writes = 0;
    await http.runWithClient(() async {
      final editor = await service.loadAccountEditor(target);
      await expectLater(
          service.editUser(
              email: target, name: 'Saved', editor: editor, companyCode: 'C1'),
          throwsA(isA<UserSavedRefreshFailed>()));
    },
        () => MockClient((request) async {
              if (request.url.path.contains('/user-editor/'))
                return reply(response());
              if (request.method == 'PUT') {
                writes++;
                return reply({'status': 'success'});
              }
              return reply({'detail': 'Synthetic refresh failure'}, 503);
            }));
    expect(writes, 1);
  });
  test('snapshot data and branch choices cannot be changed in place', () async {
    final editor = AccountEditorSnapshot.fromServer(
        response(), target, await ReadAuthorizationSnapshot.capture());
    expect(() => editor.data['username'] = 'No', throwsUnsupportedError);
    expect(() => editor.branches.single['code'] = 'B1', throwsUnsupportedError);
    expect(() => (editor.data['allowed_branches'] as List).add('B1'),
        throwsUnsupportedError);
  });
}
