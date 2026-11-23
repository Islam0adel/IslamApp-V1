// Real revocation/Hive paths with synthetic account identity and data.
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/revocation_service.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory dir;
  setUp(() async {
    f.currentUid = 'uid-A';
    dir = Directory.systemTemp.createTempSync('hr_cache_scope_');
    Hive.init(dir.path);
    for (final name in [
      'coding_box',
      'notifications_box',
      'notification_settings_box'
    ]) {
      await Hive.openBox(name);
    }
    await Hive.box('coding_box').put('C1_employees', [
      {
        'company_code': 'C1',
        'code': 'E1',
        'user_uid': 'uid-A',
        'branch_code': 'B1',
        'salary': 112.0
      }
    ]);
    await Hive.box('coding_box').put('C1_hr_adjustments', [
      {'employee_code': 'E1', 'branch_code': 'B1', 'amount': 7.0}
    ]);
    await Hive.box('coding_box').put('salary_report_C1__E1__2026-11',
        {'base_salary': 112.0, 'net_salary': 119.0});
    await Hive.box('coding_box')
        .put('branch_salaries_C1__2026-11__all', {'total_net_salary': 119.0});
    await Hive.box('coding_box')
        .put('salary_report_C2__E1__2026-11', {'net_salary': 222.0});
  });
  tearDown(() async {
    PermissionsService().reset();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });
  Map<String, dynamic> rights({bool own = false, bool salary = false}) => {
        'الموارد البشرية': {
          'canViewEmployees': true,
          'canViewOwnHRData': own,
          'canViewSalaryAmounts': salary
        }
      };
  Future<void> transition(
      Map<String, dynamic> old, Map<String, dynamic> next) async {
    PermissionsService().debugSetPermissionsForTest(next,
        loaded: true, role: 'employee', branches: ['all']);
    await RevocationService.instance.applyTransition(
        email: 'synthetic@example.invalid',
        companyCode: 'C1',
        ownerUid: 'uid-A',
        oldPerms: old,
        newPerms: next,
        oldBranches: ['all'],
        newBranches: ['all']);
  }

  test(
      'removing only own-HR right removes former own salary and adjustment amounts',
      () async {
    await transition(rights(own: true), rights());
    final box = Hive.box('coding_box');
    expect((box.get('C1_employees') as List).single['salary'], isNull);
    expect((box.get('C1_hr_adjustments') as List).single['amount'], isNull);
    expect(box.get('salary_report_C1__E1__2026-11'), isNull);
    expect(box.get('salary_report_C2__E1__2026-11'), isNotNull);
  });
  test(
      'salary-right removal invalidates actual report and branch-total key formats',
      () async {
    await transition(rights(salary: true), rights());
    final box = Hive.box('coding_box');
    expect(box.get('salary_report_C1__E1__2026-11'), isNull);
    expect(box.get('branch_salaries_C1__2026-11__all'), isNull);
    expect(box.get('salary_report_C2__E1__2026-11'), isNotNull);
  });
  test(
      'unchanged own right keeps the own salary and report during startup cleanup',
      () async {
    await transition(rights(own: true), rights(own: true));
    final box = Hive.box('coding_box');
    expect((box.get('C1_employees') as List).single['salary'], 112.0);
    expect((box.get('C1_hr_adjustments') as List).single['amount'], 7.0);
    expect(box.get('salary_report_C1__E1__2026-11'), isNotNull);
  });
  test(
      'salary removal keeps authorized own amounts but removes another employees amounts',
      () async {
    final box = Hive.box('coding_box');
    await box.put('C1_employees', [
      ...(box.get('C1_employees') as List),
      {'code': 'E2', 'user_uid': 'uid-B', 'branch_code': 'B1', 'salary': 222.0}
    ]);
    await box.put('C1_hr_adjustments', [
      ...(box.get('C1_hr_adjustments') as List),
      {'employee_code': 'E2', 'branch_code': 'B1', 'amount': 8.0}
    ]);
    await transition(rights(own: true, salary: true), rights(own: true));
    final employees = box.get('C1_employees') as List;
    final adjustments = box.get('C1_hr_adjustments') as List;
    expect(employees[0]['salary'], 112.0);
    expect(employees[1]['salary'], isNull);
    expect(adjustments[0]['amount'], 7.0);
    expect(adjustments[1]['amount'], isNull);
  });
  for (final dimension in ['branch', 'list']) {
    test(
        'own data survives $dimension narrowing without keeping excluded colleagues',
        () async {
      final box = Hive.box('coding_box');
      await box.put('C1_employees', [
        ...(box.get('C1_employees') as List),
        {
          'code': 'E2',
          'user_uid': 'uid-B',
          'branch_code': 'B1',
          'salary': 222.0
        },
        {
          'code': 'E3',
          'user_uid': 'uid-C',
          'branch_code': 'B2',
          'salary': 333.0
        }
      ]);
      await box.put('C1_hr_adjustments', [
        ...(box.get('C1_hr_adjustments') as List),
        {'employee_code': 'E2', 'branch_code': 'B1', 'amount': 8.0},
        {'employee_code': 'E3', 'branch_code': 'B2', 'amount': 9.0}
      ]);
      final branches = dimension == 'branch' ? ['B2'] : ['all'];
      final viewable = dimension == 'list' ? ['E3'] : null;
      final next = rights(own: true);
      PermissionsService().debugSetPermissionsForTest(next,
          loaded: true,
          role: 'employee',
          branches: branches,
          viewableEmployees: viewable);
      await RevocationService.instance.applyTransition(
          email: 'synthetic@example.invalid',
          companyCode: 'C1',
          ownerUid: 'uid-A',
          oldPerms: next,
          newPerms: next,
          oldBranches: ['all'],
          newBranches: branches,
          oldViewable: null,
          newViewable: viewable);
      final employees = box.get('C1_employees') as List;
      final adjustments = box.get('C1_hr_adjustments') as List;
      expect(employees.map((e) => e['code']), ['E1', 'E3']);
      expect(adjustments.map((e) => e['employee_code']), ['E1', 'E3']);
      expect(employees.first['salary'], 112.0);
      expect(adjustments.first['amount'], 7.0);
      expect(employees.last['salary'], isNull);
      expect(box.get('salary_report_C1__E1__2026-11'), isNotNull);
    });
  }
  test(
      'conflicting explicit UID never keeps cached salary through matching email',
      () async {
    await Hive.box('coding_box').put('C1_employees', [
      {
        'code': 'E1',
        'user_uid': 'uid-B',
        'user_email': 'synthetic@example.invalid',
        'salary': 112.0
      }
    ]);
    await transition(rights(own: true), rights(own: true));
    expect(
        (Hive.box('coding_box').get('C1_employees') as List).single['salary'],
        isNull);
    expect(Hive.box('coding_box').get('salary_report_C1__E1__2026-11'), isNull);
  });
  test('pending work and non-HR amount fields are not monetary cache rows',
      () async {
    final box = Hive.box('coding_box');
    await Hive.openBox('hr_pending_box');
    await Hive.box('hr_pending_box').put('pending', {
      'company_code': 'C1',
      'user_uid': 'uid-A',
      'data': {'amount': 44.0}
    });
    await box.put('C1_products', [
      {'code': 'P1', 'amount': 55.0}
    ]);
    await transition(rights(own: true), rights());
    expect((Hive.box('hr_pending_box').get('pending') as Map)['data']['amount'],
        44.0);
    expect((box.get('C1_products') as List).single['amount'], 55.0);
  });
  test(
      'revoked report values are removed from active Hive file after compaction',
      () async {
    const marker = 'SYNTHETIC_REVOKED_SALARY_VALUE_7F9C';
    final box = Hive.box('coding_box');
    await box.put('salary_report_C1__E1__2026-11', {'net_salary': marker});
    await box.flush();
    final path = File('${dir.path}/coding_box.hive');
    expect(
        String.fromCharCodes(await path.readAsBytes()).contains(marker), true);
    await transition(rights(salary: true), rights());
    await box.flush();
    expect(
        String.fromCharCodes(await path.readAsBytes()).contains(marker), false);
  });
  test(
      'employee unlink triggers real listener cleanup without a permission-map change',
      () async {
    SharedPreferences.setMockInitialValues(
        {'company_code': 'C1', 'user_email': 'synthetic@example.invalid'});
    final prefs = await SharedPreferences.getInstance();
    final ps = PermissionsService();
    final next = rights(own: true);
    ps.debugSetPermissionsForTest(next,
        loaded: true, role: 'employee', branches: ['all']);
    ps.debugSetIdentityForTest(
        email: 'synthetic@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'E1');
    await Hive.box('coding_box').put('C1_employees', [
      {
        'code': 'E1',
        'user_uid': 'uid-B',
        'user_email': 'synthetic@example.invalid',
        'branch_code': 'B1',
        'salary': 112.0
      }
    ]);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (
        Hive.box('coding_box').get('salary_report_C1__E1__2026-11') != null) {
      if (DateTime.now().isAfter(deadline))
        fail('Identity cleanup did not complete');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Drain the serialized cleanup before closing real on-disk Hive stores.
    await transition(next, next);
    expect(ps.currentEmployeeCode, isNull);
    expect(
        (Hive.box('coding_box').get('C1_employees') as List).single['salary'],
        isNull);
    expect(
        (Hive.box('coding_box').get('C1_hr_adjustments') as List)
            .single['amount'],
        isNull);
  });
  test('already masked null amounts do not cause another full resync',
      () async {
    final box = Hive.box('coding_box');
    await box.put('C1_employees', [
      {'code': 'E1', 'user_uid': 'uid-A', 'salary': null}
    ]);
    await box.put('C1_hr_adjustments', [
      {'employee_code': 'E1', 'amount': null}
    ]);
    await box.delete('salary_report_C1__E1__2026-11');
    await box.delete('branch_salaries_C1__2026-11__all');
    final next = rights();
    PermissionsService().debugSetPermissionsForTest(next,
        loaded: true, role: 'employee', branches: ['all']);
    final changed = await RevocationService.instance.applyTransition(
        email: 'synthetic@example.invalid',
        companyCode: 'C1',
        ownerUid: 'uid-A',
        oldPerms: next,
        newPerms: next,
        oldBranches: ['all'],
        newBranches: ['all']);
    expect(changed, false);
  });
}
