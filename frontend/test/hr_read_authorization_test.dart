import 'package:islam_app/models/hr_models.dart';
import 'package:islam_app/models/employee_model.dart';
// Real report/employee/HR services, synthetic HTTP/auth, temporary real Hive.
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
import 'package:islam_app/models/hr_salary_report_model.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/revocation_service.dart';
import 'package:islam_app/services/hr_report_service.dart';
import 'package:islam_app/services/hr_service.dart';
import 'package:islam_app/services/employee_service.dart';
import 'package:islam_app/services/salary_visibility.dart';
import 'commercial_queue_regression_test.dart' as f;

Map<String, dynamic> flags(
        {bool own = false, bool salary = true, bool read = true}) =>
    {
      'الموارد البشرية': {
        'canViewEmployees': true,
        'canViewOwnHRData': own,
        'canViewSalaryAmounts': salary,
        'canOpenReportPage': read,
        'canViewBranchSalaryReport': read
      }
    };
Map<String, dynamic> report() => {
      'company_code': 'C1',
      'employee_code': 'E1',
      'employee_name': 'Synthetic',
      'branch_code': 'B1',
      'month': '2026-11',
      'net_salary': 112.0,
      'base_salary': 110.0,
      'elapsed_days': 12,
      'future_financial_field': 555.0,
      'adjustment_lines': [
        {'type': 'bonus', 'label': 'Synthetic bonus', 'amount': 7.0}
      ]
    };
Map<String, dynamic> branchReport() => {
      'company_code': 'C1',
      'month': '2026-11',
      'branch_code': 'B1',
      'totals': {
        'employees_count': 1,
        'total_net_salary': 112.0,
        'future_financial_field': 555.0
      },
      'employees': [report()]
    };
http.Response reply(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  final ps = PermissionsService();
  late Directory directory;
  late SharedPreferences prefs;
  void rights(Map<String, dynamic> value,
          {List<String> branches = const ['B1'],
          List<String> employees = const ['E1', 'E2'],
          bool loaded = true}) =>
      ps.debugSetPermissionsForTest(value,
          role: 'employee',
          loaded: loaded,
          branches: branches,
          viewableEmployees: employees);
  setUp(() async {
    ps.reset();
    f.currentUid = 'uid-A';
    directory = Directory.systemTemp.createTempSync('hr_reads_');
    Hive.init(directory.path);
    for (final name in [
      'coding_box',
      'hr_pending_box',
      'notifications_box',
      'notification_settings_box'
    ]) {
      await Hive.openBox(name);
    }
    SharedPreferences.setMockInitialValues(
        {'company_code': 'C1', 'user_email': 'synthetic@example.invalid'});
    prefs = await SharedPreferences.getInstance();
    await Hive.box('coding_box').put('C1_employees', [
      {
        'company_code': 'C1',
        'code': 'E1',
        'name': 'Synthetic',
        'user_uid': 'uid-A',
        'branch_code': 'B1',
        'salary': 110.0
      }
    ]);
    rights(flags());
    ps.debugSetIdentityForTest(
        email: 'synthetic@example.invalid', prefs: prefs);
    expect(ps.currentEmployeeCode, 'E1');
  });
  tearDown(() async {
    ps.reset();
    await Hive.box('coding_box').flush();
    await Hive.close();
    directory.deleteSync(recursive: true);
  });
  Future<Object?> fetch(String kind) async => kind == 'salary'
      ? HRReportService().getSalaryReportFromBackend(
          companyCode: 'C1', employeeCode: 'E1', month: '2026-11')
      : HRReportService().getBranchSalariesTotals(
          companyCode: 'C1',
          month: '2026-11',
          branchCode: 'B1',
          forceRefresh: true);
  String key(String kind) => kind == 'salary'
      ? 'salary_report_C1__E1__2026-11'
      : 'branch_salaries_C1__2026-11__B1';
  for (final kind in ['salary', 'branch']) {
    test('authorized fresh $kind response is retained with unchanged amounts',
        () async {
      final result = await http.runWithClient(
          () => fetch(kind),
          () => MockClient((_) async =>
              reply(kind == 'salary' ? report() : branchReport())));
      expect(result, isNotNull);
      expect(Hive.box('coding_box').get(key(kind)), isNotNull);
      if (kind == 'salary')
        expect((result as HRSalaryReportModel).netSalary, 112.0);
      else
        expect((result as Map)['totals']['total_net_salary'], 112.0);
    });
    for (final change in [
      'revoke',
      'regrant',
      'owner',
      'company',
      'branch',
      'employees',
      'loading'
    ]) {
      test('old $kind response is rejected after $change', () async {
        final started = Completer<void>();
        final response = Completer<http.Response>();
        await http.runWithClient(() async {
          final pending = fetch(kind);
          await started.future;
          switch (change) {
            case 'revoke':
              rights(flags(salary: false));
              break;
            case 'regrant':
              rights(flags(salary: false));
              rights(flags());
              break;
            case 'owner':
              f.currentUid = 'uid-B';
              break;
            case 'company':
              await prefs.setString('company_code', 'C2');
              break;
            case 'branch':
              ps.setAllowedBranches(['B2']);
              break;
            case 'employees':
              rights(flags(), employees: ['E2']);
              break;
            case 'loading':
              rights(flags(), loaded: false);
              break;
          }
          response
              .complete(reply(kind == 'salary' ? report() : branchReport()));
          expect(await pending, isNull);
          expect(Hive.box('coding_box').get(key(kind)), isNull);
        },
            () => MockClient((_) {
                  started.complete();
                  return response.future;
                }));
      });
    }
    test('fresh $kind without financial-display right is masked and not cached',
        () async {
      rights(flags(salary: false));
      final result = await http.runWithClient(
          () => fetch(kind),
          () => MockClient((_) async =>
              reply(kind == 'salary' ? report() : branchReport())));
      expect(result, isNotNull);
      expect(Hive.box('coding_box').get(key(kind)), isNull);
      if (kind == 'salary') {
        expect((result as HRSalaryReportModel).netSalary, 0.0);
        expect(result.elapsedDays, 12);
        expect(result.adjustmentLines.single.amount, 0.0);
      } else {
        expect((result as Map)['totals'], {'employees_count': 1});
        expect(result['employees'].single.containsKey('net_salary'), false);
        expect(result['employees'].single.containsKey('future_financial_field'),
            false);
      }
    });
  }
  test(
      'fresh response after regrant is accepted but previous response is not revived',
      () async {
    rights(flags(salary: false));
    rights(flags());
    final result = await http.runWithClient(
        () => fetch('salary'), () => MockClient((_) async => reply(report())));
    expect((result as HRSalaryReportModel).netSalary, 112.0);
    expect(Hive.box('coding_box').get(key('salary')), isNotNull);
  });
  test('own salary remains readable outside broader branch and employee lists',
      () async {
    rights(flags(own: true, salary: false),
        branches: ['B2'], employees: ['E2']);
    final result = await http.runWithClient(
        () => fetch('salary'), () => MockClient((_) async => reply(report())));
    expect((result as HRSalaryReportModel).netSalary, 112.0);
    expect(Hive.box('coding_box').get(key('salary')), isNotNull);
  });
  test(
      'explicit unlink rejects an old own-report response and does not keep its values',
      () async {
    final current = flags(own: true, salary: false);
    rights(current);
    final started = Completer<void>();
    final response = Completer<http.Response>();
    await http.runWithClient(() async {
      final pending = fetch('salary');
      await started.future;
      await Hive.box('coding_box').put('C1_employees', [
        {
          'code': 'E1',
          'user_uid': 'uid-B',
          'branch_code': 'B1',
          'salary': 110.0
        }
      ]);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (ps.currentEmployeeCode != null) {
        if (DateTime.now().isAfter(deadline))
          fail('Unlink did not reach identity service');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await RevocationService.instance.applyTransition(
          email: 'synthetic@example.invalid',
          companyCode: 'C1',
          ownerUid: 'uid-A',
          oldPerms: current,
          newPerms: current);
      response.complete(reply(report()));
      expect(await pending, isNull);
      expect(Hive.box('coding_box').get(key('salary')), isNull);
    },
        () => MockClient((_) {
              started.complete();
              return response.future;
            }));
  });
  test(
      'report access is not inferred from employee viewing, and no HTTP request is made',
      () async {
    rights(flags(salary: false, read: false));
    var calls = 0;
    final result = await http.runWithClient(
        () => fetch('salary'),
        () => MockClient((_) async {
              calls++;
              return reply(report());
            }));
    expect(result, isNull);
    expect(calls, 0);
  });
  test('salary visibility shared contract matches exact nonfinancial key sets',
      () {
    final contract = jsonDecode(
            File('../contracts/hr_salary_visibility.json').readAsStringSync())
        as Map;
    expect(SalaryVisibility.reportSafeKeys,
        (contract['report_safe_keys'] as List).toSet());
    expect(SalaryVisibility.lineSafeKeys,
        (contract['adjustment_line_safe_keys'] as List).toSet());
    expect(SalaryVisibility.branchTopKeys,
        (contract['branch_top_keys'] as List).toSet());
    expect(SalaryVisibility.branchTotalKeys,
        (contract['branch_total_safe_keys'] as List).toSet());
  });
  final reads =
      <String, ({String key, Future<dynamic> Function() run, bool single})>{
    'employee list': (
      key: 'C1_employees',
      run: () => EmployeeService()
          .getEmployeesList(companyCode: 'C1', forceRefresh: true),
      single: false
    ),
    'employee full': (
      key: 'C1_employees',
      run: () => EmployeeService().fetchAllEmployees('C1'),
      single: false
    ),
    'employee delta': (
      key: 'C1_employees',
      run: () =>
          EmployeeService().syncChangesFromServer('C1', '2026-01-01T00:00:00Z'),
      single: false
    ),
    'attendance day': (
      key: 'C1_hr_attendance',
      run: () => HRService()
          .getAttendanceForDate(companyCode: 'C1', date: '2026-11-01'),
      single: false
    ),
    'attendance month': (
      key: 'C1_hr_attendance',
      run: () => HRService().getEmployeeMonthAttendance(
          companyCode: 'C1', employeeCode: 'E1', month: '2026-11'),
      single: false
    ),
    'attendance full': (
      key: 'C1_hr_attendance',
      run: () => HRService().fetchAllAttendance('C1'),
      single: false
    ),
    'attendance delta': (
      key: 'C1_hr_attendance',
      run: () =>
          HRService().syncChangesFromServer('C1', '2026-01-01T00:00:00Z'),
      single: false
    ),
    'vacation list': (
      key: 'C1_hr_vacations',
      run: () => HRService().getVacations(companyCode: 'C1'),
      single: false
    ),
    'vacation full': (
      key: 'C1_hr_vacations',
      run: () => HRService().fetchAllVacations('C1'),
      single: false
    ),
    'vacation delta': (
      key: 'C1_hr_vacations',
      run: () => HRService()
          .syncVacationsChangesFromServer('C1', '2026-01-01T00:00:00Z'),
      single: false
    ),
    'adjustment list': (
      key: 'C1_hr_adjustments',
      run: () => HRService()
          .getAdjustmentsForMonth(companyCode: 'C1', month: '2026-11'),
      single: false
    ),
    'adjustment employee': (
      key: 'C1_hr_adjustments',
      run: () => HRService().getEmployeeAdjustments(
          companyCode: 'C1', employeeCode: 'E1', month: '2026-11'),
      single: false
    ),
    'adjustment full': (
      key: 'C1_hr_adjustments',
      run: () => HRService().fetchAllAdjustments('C1'),
      single: false
    ),
    'adjustment delta': (
      key: 'C1_hr_adjustments',
      run: () => HRService()
          .syncAdjustmentsChangesFromServer('C1', '2026-01-01T00:00:00Z'),
      single: false
    ),
    'settings employee': (
      key: 'C1_hr_employee_settings',
      run: () => HRService()
          .getEmployeeSettings(companyCode: 'C1', employeeCode: 'E1'),
      single: true
    ),
    'settings full': (
      key: 'C1_hr_employee_settings',
      run: () => HRService().fetchAllEmployeeSettings('C1'),
      single: false
    ),
    'settings delta': (
      key: 'C1_hr_employee_settings',
      run: () => HRService()
          .syncEmployeeSettingsChangesFromServer('C1', '2026-01-01T00:00:00Z'),
      single: false
    ),
  };
  Map<String, dynamic> payload() => {
        'company_code': 'C1',
        'code': 'E1',
        'employee_code': 'E1',
        'user_uid': 'uid-A',
        'id': 1,
        'name': 'Synthetic',
        'branch_code': 'B1',
        'date': '2026-11-01',
        'month': '2026-11',
        'type': 'bonus',
        'salary': 987.0,
        'amount': 987.0,
        'reason': 'SYNTHETIC_LATE_MARKER',
        'note': 'SYNTHETIC_LATE_MARKER',
        'default_check_in': '06:43',
        'action': 'update',
        'is_deleted': false
      };
  for (final entry in reads.entries) {
    for (final mode in ['positive', 'revoke', 'regrant', 'owner', 'company']) {
      test('${entry.key} $mode protects its real cache writer', () async {
        final started = Completer<void>();
        final response = Completer<http.Response>();
        var calls = 0;
        await http.runWithClient(() async {
          final pending = () async {
            try {
              await entry.value.run();
            } catch (error) {
              if (mode == 'positive') rethrow;
            }
          }();
          await started.future.timeout(const Duration(seconds: 3));
          if (mode == 'revoke') rights({});
          if (mode == 'regrant') {
            rights({});
            rights(flags());
          }
          if (mode == 'owner') f.currentUid = 'uid-B';
          if (mode == 'company') await prefs.setString('company_code', 'C2');
          response
              .complete(reply(entry.value.single ? payload() : [payload()]));
          await pending;
          final stored = Hive.box('coding_box').get(entry.value.key);
          if (mode == 'positive') {
            expect(stored, isNotNull);
            if (entry.value.single)
              expect((stored as List).single['default_check_in'], '06:43');
            else
              expect(
                  jsonEncode(stored).contains('SYNTHETIC_LATE_MARKER'), true);
          } else {
            if (entry.value.single)
              expect(stored, isNull);
            else
              expect(
                  jsonEncode(stored).contains('SYNTHETIC_LATE_MARKER'), false);
            expect(calls, 1,
                reason: 'An invalidated batch must not issue more reads');
          }
        },
            () => MockClient((_) {
                  calls++;
                  if (calls == 1) {
                    started.complete();
                    return response.future;
                  }
                  return Future.value(
                      reply(entry.value.single ? payload() : [payload()]));
                }));
      });
    }
  }
  test(
      'multi-month adjustment batch discards earlier accumulated data on later scope change',
      () async {
    final second = Completer<void>();
    final response = Completer<http.Response>();
    var calls = 0;
    await http.runWithClient(() async {
      final pending = HRService().fetchAllAdjustments('C1');
      await second.future.timeout(const Duration(seconds: 3));
      rights({});
      response.complete(reply([payload()]));
      await expectLater(pending, throwsA(isA<Exception>()));
      expect(Hive.box('coding_box').get('C1_hr_adjustments'), isNull);
      expect(calls, 2);
    },
        () => MockClient((_) {
              calls++;
              if (calls == 1) return Future.value(reply([payload()]));
              second.complete();
              return response.future;
            }));
  });
  test(
      'cached salary is checked against current access before it can be displayed',
      () async {
    final box = Hive.box('coding_box');
    await box.put(key('salary'),
        {...report(), '_cached_at': DateTime.now().toUtc().toIso8601String()});
    rights(flags(salary: false, read: false));
    var calls = 0;
    final result = await http.runWithClient(
        () => HRReportService().getSalaryReport(
            companyCode: 'C1',
            employeeCode: 'E1',
            month: '2026-11',
            includePending: false),
        () => MockClient((_) async {
              calls++;
              return reply(report());
            }));
    expect(result, isNull);
    expect(box.get(key('salary')), isNull);
    expect(calls, 0);
  });
  test('authorized cached salary is still immediate and makes no HTTP request',
      () async {
    await Hive.box('coding_box').put(key('salary'),
        {...report(), '_cached_at': DateTime.now().toUtc().toIso8601String()});
    var calls = 0;
    final result = await http.runWithClient(
        () => HRReportService().getSalaryReport(
            companyCode: 'C1',
            employeeCode: 'E1',
            month: '2026-11',
            includePending: false),
        () => MockClient((_) async {
              calls++;
              return reply(report());
            }));
    expect(result?.netSalary, 112.0);
    expect(calls, 0);
  });
  test('a branch aggregate cached for broader employee access is not reused',
      () async {
    final box = Hive.box('coding_box');
    await box.put('branch_salaries_C1__2026-11__B1', {
      ...branchReport(),
      '_cached_at': DateTime.now().toUtc().toIso8601String()
    });
    await box.put('C1_employees', []);
    rights(flags(), employees: ['E2']);
    final fresh = {
      'company_code': 'C1',
      'month': '2026-11',
      'branch_code': 'B1',
      'totals': {'employees_count': 0, 'total_net_salary': 0.0},
      'employees': []
    };
    var calls = 0;
    final result = await http.runWithClient(
        () => HRReportService().getBranchSalariesTotals(
            companyCode: 'C1', month: '2026-11', branchCode: 'B1'),
        () => MockClient((_) async {
              calls++;
              return reply(fresh);
            }));
    expect(result?['totals']['employees_count'], 0);
    expect(calls, 1);
  });
  test(
      'an authorized cached branch aggregate stays immediate with zero HTTP requests',
      () async {
    await Hive.box('coding_box').put('branch_salaries_C1__2026-11__B1', {
      ...branchReport(),
      '_cached_at': DateTime.now().toUtc().toIso8601String()
    });
    var calls = 0;
    final result = await http.runWithClient(
        () => HRReportService().getBranchSalariesTotals(
            companyCode: 'C1', month: '2026-11', branchCode: 'B1'),
        () => MockClient((_) async {
              calls++;
              return reply(branchReport());
            }));
    expect(result?['totals']['total_net_salary'], 112.0);
    expect(calls, 0);
  });
  final writes =
      <String, ({String key, Future<Map<String, dynamic>> Function() run})>{
    'employee': (
      key: 'C1_employees',
      run: () => EmployeeService().saveEmployee(
          companyCode: 'C1',
          model: EmployeeModel.fromMap(
              {...payload(), 'notes': 'SYNTHETIC_LATE_MARKER'}))
    ),
    'attendance': (
      key: 'C1_hr_attendance',
      run: () => HRService().saveAttendance(
          model: HRAttendanceModel.fromMap(
              {...payload(), 'notes': 'SYNTHETIC_LATE_MARKER'}))
    ),
    'vacation': (
      key: 'C1_hr_vacations',
      run: () => HRService().saveVacation(
          model: HRVacationModel.fromMap(
              {...payload(), 'name': 'SYNTHETIC_LATE_MARKER'}))
    ),
    'adjustment': (
      key: 'C1_hr_adjustments',
      run: () => HRService()
          .saveAdjustment(model: HRAdjustmentModel.fromMap(payload()))
    ),
    'settings': (
      key: 'C1_hr_employee_settings',
      run: () => HRService().saveEmployeeSettings(
          model: HREmployeeSettingsModel.fromMap(payload()))
    ),
  };
  for (final entry in writes.entries) {
    for (final mode in ['positive', 'revoke', 'regrant', 'owner', 'company']) {
      test(
          '${entry.key} successful acknowledgement survives $mode without stale cache materialization',
          () async {
        final entered = Completer<void>();
        final response = Completer<http.Response>();
        var calls = 0;
        await http.runWithClient(() async {
          final pending = entry.value.run();
          await entered.future.timeout(const Duration(seconds: 3));
          if (mode == 'revoke') rights({});
          if (mode == 'regrant') {
            rights({});
            rights(flags());
          }
          if (mode == 'owner') f.currentUid = 'uid-B';
          if (mode == 'company') await prefs.setString('company_code', 'C2');
          response.complete(reply({
            'status': 'success',
            'id': 91,
            'code': 'E9',
            'action': 'insert'
          }));
          final result = await pending;
          expect(result['success'], true);
          expect(calls, 1);
          if (entry.key == 'employee')
            expect(result['code'], 'E9');
          else
            expect(result['id'], 91);
          if (mode == 'positive') {
            expect(Hive.box('coding_box').get(entry.value.key), isNotNull);
          } else {
            expect(result['scope_changed'], true);
            final cached = Hive.box('coding_box').get(entry.value.key);
            expect(jsonEncode(cached).contains('SYNTHETIC_LATE_MARKER'), false);
            if (entry.key != 'employee') expect(cached, isNull);
          }
        },
            () => MockClient((request) {
                  expect(request.method, 'POST');
                  calls++;
                  entered.complete();
                  return response.future;
                }));
      });
    }
  }
  test(
      'confirmed attendance pending work is acknowledged once after a read-scope change',
      () async {
    final service = HRService();
    await service.addPendingSave(HRAttendanceModel.fromMap(payload()));
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    var calls = 0;
    await http.runWithClient(() async {
      final pending =
          service.commitPending(companyCode: 'C1', employeeCode: 'E1');
      await entered.future.timeout(const Duration(seconds: 3));
      rights({});
      response
          .complete(reply({'status': 'success', 'id': 91, 'action': 'insert'}));
      final result = await pending;
      expect(result['success'], true);
      expect(result['saved_count'], 1);
      expect(calls, 1);
      expect(Hive.box('hr_pending_box').isEmpty, true);
      expect(Hive.box('coding_box').get('C1_hr_attendance'), isNull);
    },
        () => MockClient((request) {
              expect(request.method, 'POST');
              calls++;
              entered.complete();
              return response.future;
            }));
  });
}
