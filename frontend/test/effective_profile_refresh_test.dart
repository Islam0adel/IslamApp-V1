import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/effective_profile_snapshot.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;

class QuietFirestore extends FirebaseFirestorePlatform {
  final events = StreamController<DocumentSnapshotPlatform>.broadcast();
  @override
  FirebaseFirestorePlatform delegateFor(
          {required FirebaseApp app, required String databaseId}) =>
      this;
  @override
  CollectionReferencePlatform collection(String path) =>
      QuietCollection(this, path);
  @override
  DocumentReferencePlatform doc(String path) => QuietDocument(this, path);
  @override
  Settings get settings => const Settings();
  @override
  set settings(Settings value) {}
}

class QuietCollection extends CollectionReferencePlatform {
  QuietCollection(super.firestore, super.path);
  @override
  DocumentReferencePlatform doc([String? path]) =>
      QuietDocument(firestore, 'users/${path ?? 'fixture'}');
}

class QuietDocument extends DocumentReferencePlatform {
  QuietDocument(super.firestore, super.path);
  @override
  Stream<DocumentSnapshotPlatform> snapshots(
          {bool includeMetadataChanges = false,
          ServerTimestampBehavior serverTimestampBehavior =
              ServerTimestampBehavior.none,
          required ListenSource listenSource}) =>
      (firestore as QuietFirestore).events.stream;
}

const email = 'fixture@example.invalid';
Map<String, dynamic> effective({bool active = true}) => {
      'uid': 'uid-A',
      'email': email,
      'company_code': 'C1',
      'role': 'admin',
      'job_code': '201',
      'is_active': true,
      'allowed_branches': ['B1'],
      'hr_viewable_employees': ['E1'],
      'company_policy_active': active,
      'company_policy_revision': active ? 1 : null,
      'permissions': active
          ? {
              'المبيعات': {'تعديل': true, 'إضافة': true}
            }
          : <String, dynamic>{},
      if (active)
        'company_permissions': {
          'المبيعات': {'تعديل': true}
        },
      if (active)
        'assigned_permissions': {
          'المبيعات': {'تعديل': true}
        },
      if (active)
        'delegable_permissions': {
          'المبيعات': {'إضافة': true}
        },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  final fs = QuietFirestore();
  FirebaseFirestorePlatform.instance = fs;
  final ps = PermissionsService();
  late Directory dir;
  setUp(() async {
    ps.reset();
    f.currentUid = 'uid-A';
    dir = Directory.systemTemp.createTempSync('effective_profile_');
    Hive.init(dir.path);
    for (final name in [
      'coding_box',
      'notifications_box',
      'notification_settings_box',
      'hr_pending_box'
    ]) {
      await Hive.openBox(name);
    }
    SharedPreferences.setMockInitialValues({
      'user_email': email,
      'company_code': 'C1',
      'role': 'admin',
      'job_code': '201'
    });
    ps.debugSetPermissionsForTest(
        {
          'الموارد البشرية': {
            'canViewEmployees': true,
            'canViewSalaryAmounts': true
          }
        },
        role: 'admin',
        loaded: true,
        branches: ['B1']);
    await Hive.box('coding_box').put('C1_employees', [
      {
        'company_code': 'C1',
        'code': 'E1',
        'branch_code': 'B1',
        'user_uid': 'other',
        'salary': 91827364
      },
    ]);
  });
  tearDown(() async {
    ps.reset();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('independent branch delegation refresh, hold, revocation and restart',
      () async {
    final data = effective()
      ..['permissions'] = <String, dynamic>{}
      ..['assigned_permissions'] = <String, dynamic>{}
      ..['delegable_permissions'] = <String, dynamic>{}
      ..['delegable_branches'] = ['B2'];
    await http.runWithClient(() => ps.refreshEffectiveProfile(),
        () => MockClient((_) async => http.Response(jsonEncode(data), 200,
            headers: {'content-type': 'application/json'})));
    expect(ps.delegableBranchCodes, ['B2']);
    expect(ps.canDelegateBranch('B2'), true);
    expect(ps.canDelegateBranch('B1'), false);
    expect(ps.canAccessBranch('B1'), true);
    expect(ps.canAccessBranch('B2'), false);
    expect(ps.canManagePermissions, true);
    expect(() => ps.delegableBranchCodes.add('B3'), throwsUnsupportedError);
    final entered = Completer<void>(), release = Completer<void>();
    data['delegable_branches'] = <String>[];
    await http.runWithClient(() async {
      final refresh = ps.refreshEffectiveProfile();
      await entered.future;
      expect(ps.canDelegateBranch('B2'), false);
      expect(ps.delegableBranchCodes, isEmpty);
      release.complete();
      await refresh;
    },
        () => MockClient((_) async {
              entered.complete();
              await release.future;
              return http.Response(jsonEncode(data), 200,
                  headers: {'content-type': 'application/json'});
            }));
    expect(ps.canManagePermissions, false);
    expect(ps.canDelegateBranch('B2'), false);
    ps.reset();
    await ps.loadPermissions();
    expect(ps.delegableBranchCodes, isEmpty);
    expect(ps.canDelegateBranch('B2'), false);
    expect(ps.canAccessBranch('B2'), false);
  });

  for (final bad in [
    'uid',
    'email',
    'company',
    'role',
    'active',
    'revision',
    'branch',
    'rights',
    'ceiling',
    'delegation'
  ]) {
    test('effective snapshot rejects invalid $bad', () {
      final data = effective();
      if (bad == 'uid') data['uid'] = 'another';
      if (bad == 'email') data['email'] = 'another@example.invalid';
      if (bad == 'company') data['company_code'] = 'C2';
      if (bad == 'role') data['role'] = 'owner';
      if (bad == 'active') data['company_policy_active'] = 'true';
      if (bad == 'revision') data['company_policy_revision'] = 0;
      if (bad == 'branch') data['allowed_branches'] = [];
      if (bad == 'rights')
        data['permissions'] = {
          'المبيعات': {'حذف': true}
        };
      if (bad == 'ceiling') data['company_permissions'] = {};
      if (bad == 'delegation')
        data['delegable_permissions'] = {
          'المبيعات': {'حذف': true}
        };
      expect(
          () => EffectiveProfileSnapshot.parse(data,
              uid: 'uid-A', email: email, company: 'C1'),
          throwsA(anything));
    });
  }
  test(
      'effective profile waits for server and cleanup, persists only owner-bound scope',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      final refresh = ps.refreshEffectiveProfile();
      await entered.future;
      expect(ps.isLoaded, false);
      expect(ps.canBypassPermissions, false);
      expect(ps.canViewSalaryAmounts, false);
      expect(ps.canManageUsers, false);
      release.complete();
      await refresh;
    },
        () => MockClient((request) async {
              expect(request.url.path, '/auth/session-profile');
              entered.complete();
              await release.future;
              return http.Response(jsonEncode(effective()), 200,
                  headers: {'content-type': 'application/json'});
            }));
    expect(ps.companyPolicyActive, true);
    expect(ps.currentRole, 'admin');
    expect(ps.canBypassPermissions, false);
    expect(ps.canAddSale, true);
    expect(ps.canEditSale, true);
    expect(ps.canViewSales, false);
    expect(ps.canDeleteSale, false);
    expect(ps.canViewSalaryAmounts, false);
    expect(ps.canManagePermissions, true);
    expect(ps.isLoaded, true);
    final box = Hive.box('coding_box');
    expect(box.containsKey(EffectiveProfileSnapshot.cacheKey('uid-A', 'C1')),
        true);
    expect(box.containsKey(EffectiveProfileSnapshot.cacheKey('uid-B', 'C1')),
        false);
    expect(jsonEncode(box.toMap()).contains('91827364'), false);
    // A restart/local reload must not add legacy admin defaults to active rights.
    ps.reset();
    await ps.loadPermissions();
    expect(ps.companyPolicyActive, true);
    expect(ps.canAddSale, true);
    expect(ps.canDeleteSale, false);
    expect(ps.canViewSalaryAmounts, false);
    expect(ps.canShowCoding, false);
    expect(ps.canViewOwnHRData, false);
  });
  test('global platform admin refresh preserves selected-company context',
      () async {
    final data = effective(active: false)
      ..['role'] = 'super_admin'
      ..['company_code'] = null;
    await http.runWithClient(
        () => ps.refreshEffectiveProfile(),
        () => MockClient(
            (request) async => http.Response(jsonEncode(data), 200)));
    expect(ps.canManageCompanies, true);
    expect(ps.canBypassPermissions, true);
    ps.reset();
    await ps.loadPermissions();
    expect(ps.canManageCompanies, true);
    expect(ps.currentRole, 'super_admin');
    await http.runWithClient(() async {
      await expectLater(ps.refreshEffectiveProfile(), throwsA(anything));
    }, () => MockClient((request) async => http.Response('{}', 503)));
    expect(ps.isSuperAdmin, false);
    expect(ps.canManageCompanies, false);
    ps.reset();
    await ps.loadPermissions();
    expect(ps.isSuperAdmin, false);
    expect(ps.canManageCompanies, false);
  });
  test('raw source listener cannot replace company-clipped server rights',
      () async {
    await http.runWithClient(
        () => ps.refreshEffectiveProfile(),
        () => MockClient((request) async => http.Response(
            jsonEncode(effective()), 200,
            headers: {'content-type': 'application/json'})));
    ps.reset();
    final entered = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      await ps.loadPermissions();
      fs.events.add(DocumentSnapshotPlatform(
          fs,
          'users/$email',
          {
            'is_active': true,
            'permissions': {
              'المبيعات': {'حذف': true}
            },
            'allowed_branches': ['all'],
          },
          PigeonSnapshotMetadata(hasPendingWrites: false, isFromCache: false)));
      await entered.future;
      expect(ps.canDeleteSale, false);
      expect(ps.canViewSalaryAmounts, false);
      release.complete();
      // Join the same refresh rather than launching an additional request.
      await ps.refreshEffectiveProfile(restrictWhileLoading: false);
    },
        () => MockClient((request) async {
              entered.complete();
              await release.future;
              return http.Response(jsonEncode(effective()), 200,
                  headers: {'content-type': 'application/json'});
            }));
    expect(ps.canDeleteSale, false);
    expect(ps.canAccessBranch('B2'), false);
    expect(Hive.box('coding_box').get('permissions_$email'), isNull);
  });
  test(
      'cached startup source event keeps offline scope, confirmed later change holds it',
      () async {
    await http.runWithClient(
        () => ps.refreshEffectiveProfile(),
        () => MockClient((request) async => http.Response(
            jsonEncode(effective()), 200,
            headers: {'content-type': 'application/json'})));
    ps.reset();
    var calls = 0;
    final received = Completer<void>(), release = Completer<void>();
    await http.runWithClient(() async {
      await ps.loadPermissions();
      final source = <String, Object?>{
        'is_active': true,
        'permissions': {
          'المبيعات': {'إضافة': true}
        }
      };
      fs.events.add(DocumentSnapshotPlatform(fs, 'users/$email', source,
          PigeonSnapshotMetadata(hasPendingWrites: false, isFromCache: true)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 0);
      expect(ps.canAddSale, true);
      fs.events.add(DocumentSnapshotPlatform(
          fs,
          'users/$email',
          {...source, 'permissions': <String, dynamic>{}},
          PigeonSnapshotMetadata(hasPendingWrites: false, isFromCache: false)));
      await received.future;
      expect(ps.canAddSale, false);
      expect(ps.canManageUsers, false);
      final rejected = expectLater(
          ps.refreshEffectiveProfile(restrictWhileLoading: false),
          throwsA(anything));
      release.complete();
      await rejected;
    },
        () => MockClient((request) async {
              calls++;
              received.complete();
              await release.future;
              return http.Response('{}', 503);
            }));
    expect(calls, 1);
    expect(ps.canAddSale, false);
  });
  test(
      'scope change during cache cleanup blocks late verification and restart grants',
      () async {
    var changed = false;
    final watch =
        Hive.box('coding_box').watch(key: 'C1_employees').listen((event) {
      if (!changed) {
        changed = true;
        ps.setRole('employee');
      }
    });
    await http.runWithClient(() async {
      await expectLater(ps.refreshEffectiveProfile(), throwsA(anything));
    },
        () => MockClient((request) async => http.Response(
            jsonEncode(effective()), 200,
            headers: {'content-type': 'application/json'})));
    await watch.cancel();
    expect(changed, true);
    expect(ps.canAddSale, false);
    ps.reset();
    await ps.loadPermissions();
    expect(ps.canAddSale, false);
    expect(ps.canManageUsers, false);
  });
  test('legacy verified empty admin scope retains its existing defaults',
      () async {
    await http.runWithClient(
        () => ps.refreshEffectiveProfile(),
        () => MockClient((request) async =>
            http.Response(jsonEncode(effective(active: false)), 200)));
    expect(ps.companyPolicyActive, false);
    expect(ps.canBypassPermissions, true);
    expect(ps.canAddSale, true);
    expect(ps.canManagePermissions, true);
  });
  test('failed known scope refresh remains held, not successful local reload',
      () async {
    await http.runWithClient(() async {
      await expectLater(ps.refreshEffectiveProfile(), throwsA(anything));
    }, () => MockClient((request) async => http.Response('{}', 503)));
    expect(ps.isLoaded, false);
    expect(ps.isAdmin, false);
    expect(ps.isSuperAdmin, false);
    expect(ps.canBypassPermissions, false);
    expect(ps.canViewSalaryAmounts, false);
    expect(ps.canManageUsers, false);
  });
  test(
      'unresolved verification survives restart without legacy default resurrection',
      () async {
    await http.runWithClient(() async {
      await expectLater(ps.refreshEffectiveProfile(), throwsA(anything));
    }, () => MockClient((request) async => http.Response('{}', 503)));
    ps.reset();
    await ps.loadPermissions();
    expect(ps.canBypassPermissions, false);
    expect(ps.canViewSalaryAmounts, false);
    expect(ps.canShowNotifications, false);
    expect(ps.canShowProductLookup, false);
    expect(ps.canManageUsers, false);
    expect(ps.canAccessBranch('B1'), false);
  });
  test(
      'overlapping revocation supersedes late grants and restart keeps the latest scope',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    var calls = 0;
    await http.runWithClient(() async {
      final first = ps.refreshEffectiveProfile();
      final rejected = expectLater(first, throwsA(anything));
      await entered.future;
      final second = ps.refreshEffectiveProfile();
      release.complete();
      await rejected;
      await second;
    },
        () => MockClient((request) async {
              calls++;
              if (calls == 1) {
                entered.complete();
                await release.future;
              }
              final data = effective();
              if (calls == 2) {
                data['role'] = 'employee';
                for (final key in [
                  'permissions',
                  'company_permissions',
                  'assigned_permissions',
                  'delegable_permissions'
                ]) {
                  data[key] = <String, dynamic>{};
                }
              }
              return http.Response(jsonEncode(data), 200,
                  headers: {'content-type': 'application/json'});
            }));
    expect(calls, 2);
    expect(ps.canAddSale, false);
    expect(ps.currentRole, 'employee');
    ps.reset();
    await ps.loadPermissions();
    expect(ps.currentRole, 'employee');
    expect(ps.canAddSale, false);
    expect(ps.canManageUsers, false);
    expect(ps.canBypassPermissions, false);
  });
  test('current verification joins replacement after a superseded reconnect read',()async{
    final entered=Completer<void>(),release=Completer<void>();var calls=0;
    await http.runWithClient(()async{
      final original=ps.refreshEffectiveProfile(restrictWhileLoading:false);
      final rejected=expectLater(original,throwsA(anything));
      await entered.future;
      final current=ps.refreshEffectiveProfile();
      final joined=ps.verifyCurrentEffectiveProfile(restrictWhileLoading:false);
      release.complete();await rejected;await current;await joined;
      expect(ps.isLoaded,true);expect(ps.canEditSale,true);
    },()=>MockClient((r)async{calls++;if(calls==1){entered.complete();await release.future;}
      return http.Response(jsonEncode(effective()),200,headers:{'content-type':'application/json'});}));
    expect(calls,inInclusiveRange(2,3));
  });
  test('joined verification succeeds for a fresh current authenticated response',()async{
    await http.runWithClient(()async{
      final verify=ps.verifyCurrentEffectiveProfile();
      await verify;
      expect(ps.isLoaded,true);
    },()=>MockClient((r)async=>http.Response(jsonEncode(effective()),200,headers:{'content-type':'application/json'})));
  });
  test('same UID re-login reads verified prior scope without broad sync invalidation',()async{
    await http.runWithClient(()async{
      await ps.refreshEffectiveProfile();ps.takeScopeSyncModules();
      ps.reset();
      await ps.refreshEffectiveProfile();
      expect(ps.takeScopeSyncModules(),isEmpty);
    },()=>MockClient((r)async=>http.Response(jsonEncode(effective()),200,headers:{'content-type':'application/json'})));
  });
  test('root and legacy admin re-login compare expanded defaults consistently',()async{
    for(final role in ['super_admin','admin']){
      ps.reset();
      final data=effective(active:false);data['role']=role;data['job_code']=role=='super_admin'?'99':'201';
      await http.runWithClient(()async{
        await ps.refreshEffectiveProfile();ps.takeScopeSyncModules();ps.reset();
        await ps.refreshEffectiveProfile();expect(ps.takeScopeSyncModules(),isEmpty);
      },()=>MockClient((r)async=>http.Response(jsonEncode(data),200,headers:{'content-type':'application/json'})));
    }
  });
  test('startup refresh failure retains previously usable offline scope',
      () async {
    await http.runWithClient(() async {
      await expectLater(ps.refreshEffectiveProfile(restrictWhileLoading: false),
          throwsA(anything));
    },
        () => MockClient(
            (request) async => throw const SocketException('fixture offline')));
    expect(ps.canViewSalaryAmounts, true);
    expect(ps.canBypassPermissions, true);
  });
  for (final changed in ['owner', 'company', 'scope']) {
    test('late effective profile cannot install after $changed changes',
        () async {
      final entered = Completer<void>(), release = Completer<void>();
      await http.runWithClient(() async {
        final refresh = ps.refreshEffectiveProfile();
        final caught = expectLater(refresh, throwsA(anything));
        await entered.future;
        if (changed == 'owner') f.currentUid = 'uid-B';
        if (changed == 'company')
          await (await SharedPreferences.getInstance())
              .setString('company_code', 'C2');
        if (changed == 'scope')
          ps.debugSetPermissionsForTest({}, role: 'employee');
        release.complete();
        await caught;
      },
          () => MockClient((request) async {
                entered.complete();
                await release.future;
                return http.Response(jsonEncode(effective()), 200,
                    headers: {'content-type': 'application/json'});
              }));
      expect(
          Hive.box('coding_box')
              .containsKey(EffectiveProfileSnapshot.cacheKey('uid-A', 'C1')),
          false);
    });
  }
}
