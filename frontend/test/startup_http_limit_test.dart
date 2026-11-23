import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/auth_http.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  setUp(() {
    f.currentUid = 'uid-A';
    SharedPreferences.setMockInitialValues({'company_code': 'C1'});
  });
  test('nested fanout shares five request slots without extra calls', () async {
    var count = 0, running = 0, peak = 0;
    final release = Completer<void>();
    await http.runWithClient(() async {
      final work = Future.wait(List.generate(12,
          (i) => AuthHttp.get(Uri.parse('https://test.invalid/changes/$i'))));
      while (count < 5) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(count, 5);
      expect(peak, 5);
      release.complete();
      await work;
      expect(count, 12);
    },
        () => MockClient((r) async {
              count++;
              running++;
              if (running > peak) peak = running;
              await release.future;
              running--;
              return http.Response('[]', 200);
            }));
  });
  test(
      'queued old-owner HTTP request is rejected before network after account change',
      () async {
    final gates = List.generate(5, (_) => Completer<http.Response>());
    var calls = 0;
    await http.runWithClient(() async {
      final workers = List.generate(
          5,
          (i) => AuthHttp.get(Uri.parse('https://test.invalid/holding/$i'))
              .then<Object>((v) => v, onError: (Object e) => e));
      while (calls < 5) {
        await Future<void>.delayed(Duration.zero);
      }
      final queued = AuthHttp.get(Uri.parse('https://test.invalid/old'))
          .then<Object>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(Duration.zero);
      f.currentUid = 'uid-B';
      for (final g in gates) {
        g.complete(http.Response('[]', 200));
      }
      await Future.wait(workers);
      expect(await queued, isA<Exception>());
      expect(calls, 5);
    },
        () => MockClient((r) {
              return gates[calls++].future;
            }));
  });
  test('queued request cannot acquire later permissions after epoch change',
      () async {
    final gates = List.generate(5, (_) => Completer<http.Response>());
    var calls = 0;
    await http.runWithClient(() async {
      final workers = List.generate(
          5, (i) => AuthHttp.get(Uri.parse('https://test.invalid/holding/$i')));
      while (calls < 5) {
        await Future<void>.delayed(Duration.zero);
      }
      final queued = AuthHttp.get(Uri.parse('https://test.invalid/oldscope'))
          .then<Object>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(Duration.zero);
      ReadAuthorizationEpoch.invalidate();
      for (final g in gates) {
        g.complete(http.Response('[]', 200));
      }
      await Future.wait(workers);
      expect(await queued, isA<ReadAuthorizationChanged>());
      expect(calls, 5);
    }, () => MockClient((r) => gates[calls++].future));
  });
}
