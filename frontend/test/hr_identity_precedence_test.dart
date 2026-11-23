// Actual identity/notification services, synthetic auth/HTTP, temporary on-disk Hive.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/employee_identity.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/notifications_service.dart';
import 'commercial_queue_regression_test.dart' as f;
import 'notification_cache_revocation_test.dart' as n;

String? authEmail = 'a@example.invalid';

class IdentityUser extends f.FakeUser {
  IdentityUser(super.auth, super.uid);
  @override
  String? get email => authEmail;
}

class IdentityAuth extends f.FakeAuth {
  @override
  UserPlatform? get currentUser =>
      f.currentUid.isEmpty ? null : IdentityUser(this, f.currentUid);
}

Future<void> until(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(limit))
      fail('Synthetic identity checkpoint timed out');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = IdentityAuth();
  final ps = PermissionsService();
  final notifications = NotificationsService.instance;
  late Directory directory;
  late SharedPreferences prefs;
  setUp(() async {
    ps.reset();
    f.currentUid = 'uid-A';
    authEmail = 'a@example.invalid';
    directory = Directory.systemTemp.createTempSync('hr_identity_');
    Hive.init(directory.path);
    for (final name in [
      'coding_box',
      'daily_transactions_box',
      'notifications_box',
      'notification_settings_box'
    ]) {
      await Hive.openBox(name);
    }
    SharedPreferences.setMockInitialValues(
        {'company_code': 'C1', 'user_email': 'a@example.invalid'});
    prefs = await SharedPreferences.getInstance();
    notifications.finishHRAuthorization(await notifications
        .invalidateHRAuthorization(companyCode: 'C1', uid: 'uid-A'));
  });
  tearDown(() async {
    ps.reset();
    await Hive.close();
    directory.deleteSync(recursive: true);
  });
  final contract =
      jsonDecode(File('../contracts/employee_identity.json').readAsStringSync())
          as Map;
  for (final raw in contract['cases'] as List) {
    final row = Map<String, dynamic>.from(raw['row'] as Map);
    final actor = raw['actor'] as Map;
    test('shared identity: ${raw['name']}', () {
      expect(
          EmployeeIdentity.matches(row,
              uid: actor['uid'], email: actor['email']),
          raw['self']);
      expect(
          EmployeeIdentity.resolveCode([row],
              uid: actor['uid'], email: actor['email']),
          raw['self'] == true ? 'E1' : null);
    });
  }
  test('UID-only current employee beats a conflicting email row', () async {
    await Hive.box('coding_box').put('C1_employees', [
      {'code': 'wrong', 'user_uid': 'uid-B', 'user_email': 'a@example.invalid'},
      {'code': 'right', 'user_uid': 'uid-A', 'user_email': null},
    ]);
    ps.debugSetIdentityForTest(
        email: 'wrong-prefs@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'right');
    expect(ps.isCurrentEmployee('wrong'), false);
  });
  test(
      'email fallback uses authenticated email, never another saved profile email',
      () async {
    await Hive.box('coding_box').put('C1_employees', [
      {'code': 'wrong', 'user_uid': null, 'user_email': 'old@example.invalid'},
      {'code': 'right', 'user_uid': null, 'user_email': ' A@EXAMPLE.INVALID '},
    ]);
    ps.debugSetIdentityForTest(email: 'old@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'right');
    authEmail = null;
    ps.debugSetIdentityForTest(email: 'old@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, isNull);
  });
  test('new owner cannot reuse the previous owners cached self code', () async {
    await Hive.box('coding_box').put('C1_employees', [
      {'code': 'A', 'user_uid': 'uid-A'},
      {'code': 'B', 'user_uid': 'uid-B'},
    ]);
    ps.debugSetIdentityForTest(email: 'a@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'A');
    f.currentUid = 'uid-B';
    authEmail = 'b@example.invalid';
    expect(ps.currentEmployeeCode, isNull);
    ps.debugSetIdentityForTest(email: 'b@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'B');
  });
  test(
      'company switch does not carry an identical employee code into another company',
      () async {
    await Hive.box('coding_box').put('C1_employees', [
      {'code': 'E1', 'user_uid': 'uid-A'}
    ]);
    await Hive.box('coding_box').put('C2_employees', [
      {'code': 'E1', 'user_uid': 'uid-B'}
    ]);
    ps.debugSetIdentityForTest(email: 'a@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'E1');
    await prefs.setString('company_code', 'C2');
    expect(ps.currentEmployeeCode, isNull);
    await Hive.box('coding_box').put('C2_employees', [
      {'code': 'E2', 'user_uid': 'uid-A'}
    ]);
    // The same account in a new company still needs that company's profile load.
    expect(ps.currentEmployeeCode, isNull);
    ps.debugSetIdentityForTest(email: 'a@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'E2');
  });
  test('unlink notifies listeners and removes the own-salary exception',
      () async {
    await Hive.box('coding_box').put('C1_employees', [
      {'code': 'E1', 'user_uid': 'uid-A'}
    ]);
    ps.debugSetPermissionsForTest({
      'الموارد البشرية': {'canViewOwnHRData': true}
    }, role: 'employee', loaded: true);
    ps.debugSetIdentityForTest(email: 'a@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'E1');
    expect(ps.canSeeEmployeeSalary('E1'), true);
    var updates = 0;
    void listener() {
      updates++;
    }

    ps.addListener(listener);
    await Hive.box('coding_box').put('C1_employees', [
      {'code': 'E1', 'user_uid': 'uid-B', 'user_email': 'a@example.invalid'}
    ]);
    await until(() => updates > 0);
    expect(ps.currentEmployeeCode, isNull);
    expect(ps.canSeeEmployeeSalary('E1'), false);
    ps.removeListener(listener);
  });
  test(
      'ambiguous links are not guessed; unique UID is preferred to email-only legacy row',
      () {
    expect(
        EmployeeIdentity.resolveCode([
          {'code': 'E1', 'user_uid': 'uid-A'},
          {'code': 'E2', 'user_uid': 'uid-A'}
        ], uid: 'uid-A', email: 'a@example.invalid'),
        isNull);
    expect(
        EmployeeIdentity.resolveCode([
          {'code': 'E2', 'user_uid': null, 'user_email': 'a@example.invalid'},
          {'code': 'E1', 'user_uid': 'uid-A'}
        ], uid: 'uid-A', email: 'a@example.invalid'),
        'E1');
  });
  const types = {
    'employee': 'hr_employees',
    'hr_employee_settings': 'hr_employees',
    'hr_attendance': 'hr_attendance',
    'hr_vacation': 'hr_vacations',
    'hr_adjustment': 'hr_adjustments'
  };
  for (final broad in [false, true]) {
    for (final entry in types.entries) {
      for (final mode in ['incremental', 'unread', 'live']) {
        test(
            'own $mode ${entry.key} survives branch/list exclusion broad=$broad',
            () async {
          ps.debugSetPermissionsForTest(
              {
                'الموارد البشرية': {
                  'canViewOwnHRData': true,
                  'canViewEmployees': broad
                }
              },
              loaded: true,
              role: 'employee',
              branches: ['B2'],
              viewableEmployees: ['E2']);
          final scope = {'employee_code': 'E1', 'is_self': true};
          final item = {
            ...n.row('own', section: entry.value),
            'notification_scope': scope
          };
          if (mode == 'live') {
            await notifications.handleSyncEvent({
              'type': entry.key,
              'event_id': 'own',
              'action': 'update',
              'data': {
                'company_code': 'C1',
                'branch_code': 'B1',
                'code': 'E1',
                'employee_code': 'E1'
              },
              'notification_scope': scope
            });
          } else {
            await http.runWithClient(
                () => mode == 'unread'
                    ? notifications.refreshUnreadFromServer(companyCode: 'C1')
                    : notifications.refreshFromServer(companyCode: 'C1'),
                () => MockClient((_) async => n.reply([item])));
          }
          expect(Hive.box('notifications_box').containsKey('own'), true);
          expect(notifications.getNotifications(companyCode: 'C1').length, 1);
        });
      }
    }
  }
  test('self metadata without an own right cannot bypass another scope',
      () async {
    ps.debugSetPermissionsForTest(
        {
          'الموارد البشرية': {
            'canViewOwnHRData': false,
            'canViewEmployees': true
          }
        },
        loaded: true,
        role: 'employee',
        branches: ['B2'],
        viewableEmployees: ['E2']);
    await notifications.handleSyncEvent({
      'type': 'employee',
      'event_id': 'forbidden',
      'data': {'company_code': 'C1', 'code': 'E1', 'branch_code': 'B1'},
      'notification_scope': {'employee_code': 'E1', 'is_self': true}
    });
    expect(Hive.box('notifications_box').isEmpty, true);
  });
  test(
      'notification disable keeps own data notifications off and avoids HTTP calls',
      () async {
    ps.debugSetPermissionsForTest(
        {
          'الموارد البشرية': {'canViewOwnHRData': true},
          'صلاحيات عامة': {'إظهار الإشعارات': false}
        },
        loaded: true,
        role: 'employee',
        branches: ['B1']);
    var calls = 0;
    await http.runWithClient(
        () => notifications.refreshFromServer(companyCode: 'C1'),
        () => MockClient((_) async {
              calls++;
              return n.reply([]);
            }));
    expect(calls, 0);
    await notifications.handleSyncEvent({
      'type': 'employee',
      'event_id': 'forbidden',
      'data': {'company_code': 'C1', 'code': 'E1'},
      'notification_scope': {'employee_code': 'E1', 'is_self': true}
    });
    expect(Hive.box('notifications_box').isEmpty, true);
  });
}
