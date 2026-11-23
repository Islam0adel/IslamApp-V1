import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/hr_service.dart';
import 'package:islam_app/models/hr_models.dart';
import 'commercial_queue_regression_test.dart' as f;

const day = '2026-11-22';
const targetKey = 'C1_E2_2026-11-22';
HRAttendanceModel attendance(String employee, int id, {String notes = ''}) =>
    HRAttendanceModel(
        id: id,
        companyCode: 'C1',
        branchCode: 'B1',
        employeeCode: employee,
        date: day,
        status: 'present',
        checkIn: '09:00',
        checkOut: '17:00',
        notes: notes);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  Directory? dir;
  late List<http.Request> posts;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'company_code':'C1'});
    await Hive.close();
    dir?.deleteSync(recursive: true);
    dir = Directory.systemTemp.createTempSync('hr_regression_');
    Hive.init(dir!.path);
    await Hive.openBox('coding_box');
    await Hive.openBox('hr_pending_box');
    f.currentUid = 'uid-A';
    posts = [];
  });
  tearDown(() async {
    await Hive.close();
  });

  for (final restriction in [
    'other-account',
    'unknown-owner',
    'revoked',
    'discarded'
  ]) {
    test('H1 retry respects $restriction and retains pending operation',
        () async {
      final service = HRService();
      await service.addPendingSave(attendance('E2', 2));
      final q = Hive.box('hr_pending_box');
      final op = Map<String, dynamic>.from(q.get(targetKey));
      if (restriction == 'other-account') op['user_uid'] = 'uid-B';
      if (restriction == 'unknown-owner') op.remove('user_uid');
      if (restriction == 'revoked') op['revoked_hold'] = true;
      if (restriction == 'discarded') op['discarded'] = true;
      await q.put(targetKey, op);
      await http.runWithClient(() async {
        await service.retryAllPending('C1');
      },
          () => MockClient((request) async {
                posts.add(request);
                return http.Response('{"id":2,"action":"update"}', 200);
              }));
      expect(posts, isEmpty);
      expect(q.containsKey(targetKey), true);
    });
  }

  test('H2 background delete uses target employee, not first same-date row',
      () async {
    final service = HRService();
    await Hive.box('coding_box').put('C1_hr_attendance', [
      attendance('E1', 1).toMap(),
      attendance('E2', 2).toMap(),
    ]);
    await service.addPendingDelete(
        companyCode: 'C1', employeeCode: 'E2', date: day);
    final done = Completer<void>();
    await http.runWithClient(() async {
      await service.commitPendingFast(
          companyCode: 'C1',
          employeeCode: 'E2',
          onCompleted: () => done.complete());
      await done.future;
    },
        () => MockClient((request) async {
              posts.add(request);
              return http.Response('{}', 200);
            }));
    expect(posts.single.url.path.endsWith('/2'), true);
    final rows = Hive.box('coding_box').get('C1_hr_attendance') as List;
    expect(rows.map((r) => r['employee_code']).toList(), ['E1']);
    expect(Hive.box('hr_pending_box').isEmpty, true);
  });

  test('H3 reconnect cannot send newer attendance concurrently with old save',
      () async {
    final service = HRService();
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final done = Completer<void>();
    final serverNotes = <String>[];
    await service.addPendingSave(attendance('E2', 2, notes: 'old'));
    await http.runWithClient(() async {
      await service.commitPendingFast(
          companyCode: 'C1',
          employeeCode: 'E2',
          onCompleted: () => done.complete());
      await firstEntered.future;
      await service.addPendingSave(attendance('E2', 2, notes: 'latest'));
      final retry = HRService().retryAllPending('C1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final sentBeforeRelease = posts.length;
      releaseFirst.complete();
      await done.future;
      await retry;
      expect(sentBeforeRelease, 1);
      expect(serverNotes.last, 'latest');
      expect(Hive.box('hr_pending_box').isEmpty, true);
    },
        () => MockClient((request) async {
              posts.add(request);
              final data = jsonDecode(request.body) as Map;
              if (data['notes'] == 'old') {
                firstEntered.complete();
                await releaseFirst.future;
              }
              serverNotes.add(data['notes'].toString());
              return http.Response('{"id":2,"action":"update"}', 200);
            }));
  });

  test('H4 hold applied during upload survives acknowledgement', () async {
    final service = HRService();
    final entered = Completer<void>();
    final release = Completer<void>();
    final done = Completer<void>();
    await service.addPendingSave(attendance('E2', 2));
    await http.runWithClient(() async {
      await service.commitPendingFast(
          companyCode: 'C1',
          employeeCode: 'E2',
          onCompleted: () => done.complete());
      await entered.future;
      final q = Hive.box('hr_pending_box');
      final op = Map<String, dynamic>.from(q.get(targetKey));
      op['revoked_hold'] = true;
      await q.put(targetKey, op);
      release.complete();
      await done.future;
      expect(q.containsKey(targetKey), true);
      expect(q.get(targetKey)['revoked_hold'], true);
    },
        () => MockClient((request) async {
              entered.complete();
              await release.future;
              return http.Response('{"id":2}', 200);
            }));
  });
  test('H5 delete resolves committed lost-response save by exact employee/day',
      () async {
    final service = HRService();
    await service.addPendingDelete(
        companyCode: 'C1', employeeCode: 'E2', date: day);
    await http.runWithClient(() async {
      final result =
          await service.commitPending(companyCode: 'C1', employeeCode: 'E2');
      expect(result['success'], true);
      expect(posts.length, 2);
      expect(posts.first.method, 'GET');
      expect(posts.first.url.queryParameters['employee_code'], 'E2');
      expect(posts.last.url.path.endsWith('/2'), true);
      expect(Hive.box('hr_pending_box').isEmpty, true);
    },
        () => MockClient((request) async {
              posts.add(request);
              return request.method == 'GET'
                  ? http.Response(
                      jsonEncode([attendance('E2', 2).toMap()]), 200)
                  : http.Response('{}', 200);
            }));
  });

  test('H6 duplicate fast-save calls share upload lane and do not post twice',
      () async {
    final one = HRService();
    final two = HRService();
    final release = Completer<void>();
    final entered = Completer<void>();
    final done1 = Completer<void>();
    final done2 = Completer<void>();
    await one.addPendingSave(attendance('E2', 2));
    await http.runWithClient(() async {
      await one.commitPendingFast(
          companyCode: 'C1',
          employeeCode: 'E2',
          onCompleted: () => done1.complete());
      await entered.future;
      await two.commitPendingFast(
          companyCode: 'C1',
          employeeCode: 'E2',
          onCompleted: () => done2.complete());
      release.complete();
      await Future.wait([done1.future, done2.future]);
      expect(posts.length, 1);
      expect(Hive.box('hr_pending_box').isEmpty, true);
    },
        () => MockClient((request) async {
              posts.add(request);
              entered.complete();
              await release.future;
              return http.Response('{"id":2}', 200);
            }));
  });
}
