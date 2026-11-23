import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:islam_app/services/auth_http.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'commercial_queue_regression_test.dart' as f;

late Completer<void> entered;
late Completer<String?> token;

class HeldUser extends f.FakeUser {
  HeldUser(super.auth, super.uid);
  @override
  Future<String?> getIdToken(bool forceRefresh) {
    entered.complete();
    return token.future;
  }
}

class HeldAuth extends f.FakeAuth {
  @override
  UserPlatform? get currentUser =>
      f.currentUid.isEmpty ? null : HeldUser(this, f.currentUid);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = HeldAuth();
  setUp(() {
    entered = Completer<void>();
    token = Completer<String?>();
    f.currentUid = 'uid-A';
  });
  Future<http.Response> send(String method) {
    final url = Uri.parse('https://synthetic.invalid/data');
    switch (method) {
      case 'GET':
        return AuthHttp.get(url);
      case 'POST':
        return AuthHttp.post(url, body: '{}');
      case 'PUT':
        return AuthHttp.put(url, body: '{}');
      default:
        return AuthHttp.delete(url);
    }
  }

  for (final method in ['GET', 'POST', 'PUT', 'DELETE']) {
    for (final change in ['owner', 'permissions']) {
      test(
          '$method is not submitted if $change changes while obtaining its token',
          () async {
        var calls = 0;
        await http.runWithClient(() async {
          final pending = send(method);
          await entered.future;
          if (change == 'owner')
            f.currentUid = 'uid-B';
          else
            ReadAuthorizationEpoch.invalidate();
          final expectation = expectLater(pending, throwsA(isA<Object>()));
          token.complete('synthetic-token');
          await expectation;
          expect(calls, 0);
        },
            () => MockClient((_) async {
                  calls++;
                  return http.Response('{}', 200);
                }));
      });
    }
  }
  for (final method in ['GET', 'POST']) {
    test('$method with unchanged identity uses the existing token once',
        () async {
      var calls = 0;
      await http.runWithClient(() async {
        final pending = send(method);
        await entered.future;
        token.complete('synthetic-token');
        expect((await pending).statusCode, 200);
        expect(calls, 1);
      },
          () => MockClient((request) async {
                calls++;
                expect(
                    request.headers['Authorization'], 'Bearer synthetic-token');
                return http.Response('{}', 200);
              }));
    });
  }
}
