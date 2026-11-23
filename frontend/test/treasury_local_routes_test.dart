// Real client + local FastAPI/SQLite only. No production host is accepted.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/treasury_transfer_service.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final endpoint = Platform.environment['ISLAMAPP_TEST_API'];
  if (endpoint == null) {
    test('treasury local route integration (opt-in)', () {},
        skip: 'Local validation fixture required');
    return;
  }
  final base = Uri.parse(endpoint);
  if (!{'127.0.0.1', 'localhost'}.contains(base.host))
    throw StateError('Local fixture only');
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  final io = HttpClient();
  late Directory dir;
  Future<http.Response> forward(http.Request request) async {
    final outgoing = await io.openUrl(request.method,
        base.replace(path: request.url.path, query: request.url.query));
    request.headers.forEach(outgoing.headers.set);
    outgoing.add(utf8.encode(request.body));
    final response = await outgoing.close();
    return http.Response(
        await utf8.decoder.bind(response).join(), response.statusCode,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  Future<Map> counts() async {
    final req = await io.getUrl(base.replace(path: '/fixture-counts'));
    final response = await req.close();
    expect(response.statusCode, 200);
    return jsonDecode(await utf8.decoder.bind(response).join()) as Map;
  }

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('treasury_routes_');
    Hive.init(dir.path);
    for (final name in [
      TreasuryTransferService.recordsBox,
      TreasuryTransferService.effectsBox
    ]) {
      await Hive.openBox(name);
    }
    f.currentUid = 'uid-A';
    PermissionsService()
        .debugSetPermissionsForTest({}, role: 'admin', branches: ['all']);
  });
  tearDownAll(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
    io.close(force: true);
  });
  test(
      'T1 single-record create retry edit stale delete retry never writes journal',
      () async {
    final service = TreasuryTransferService();
    final payload = <String, dynamic>{
      'id': service.newId(),
      'company_code': 'C1',
      'branch_code': 'B1',
      'serial': 0,
      'from_treasury': 'الرئيسية',
      'to_treasury': 'الفرعية',
      'amount': 125.5,
      'date': '2026-11-22',
      'statement': 'نقل سيولة',
      'employee': 'أحمد'
    };
    await http.runWithClient(() async {
      final created = await service.save(payload);
      expect(created['refresh_pending'], false);
      final first = Map<String, dynamic>.from(created['record']);
      expect(first['serial'], 1);
      expect(first['updated_at'], isNotEmpty);
      expect(service.localRecords('C1').single['statement'], 'نقل سيولة');
      expect(
          service.balanceEffects('C1'), {'الرئيسية': -125.5, 'الفرعية': 125.5});
      await service.save(payload);
      expect((await counts())['treasury_transfers'], 1);
      expect((await counts())['journal'], 0);
      final edit = {
        ...payload,
        'serial': 1,
        'amount': 80.0,
        'base_updated_at': first['updated_at']
      };
      final edited = await service.save(edit);
      expect(
          service.balanceEffects('C1'), {'الرئيسية': -80.0, 'الفرعية': 80.0});
      await expectLater(
          service.save({...edit, 'amount': 10.0}),
          throwsA(isA<TreasuryTransferFailure>()
              .having((e) => e.statusCode, 'status', 409)));
      final row = Map<String, dynamic>.from(edited['record']);
      final deleted = await service.delete(row);
      expect(deleted['refresh_pending'], false);
      expect(service.localRecords('C1'), isEmpty);
      expect(service.balanceEffects('C1'), isEmpty);
      await service.delete(row);
      await expectLater(
          service.save(payload),
          throwsA(isA<TreasuryTransferFailure>()
              .having((e) => e.statusCode, 'status', 404)));
      final finalCounts = await counts();
      expect(finalCounts,
          {'treasury_transfers': 1, 'active_transfers': 0, 'journal': 0});
    }, () => MockClient(forward));
  });
}
