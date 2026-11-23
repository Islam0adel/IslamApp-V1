import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/cache_partitions.dart';
import 'package:islam_app/views/dashboard/home_page.dart';
import 'commercial_queue_regression_test.dart' as f;
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 FirebasePlatform.instance=f.FakeCore();FirebaseAuthPlatform.instance=f.FakeAuth();
 testWidgets('old Home rebuild during suspended logout does not touch owned box', (tester) async {
  CachePartitions.enable();CachePartitions.suspend();
  // This is the same unavailable-partition state between logout suspension
  // and navigation. The guard remains strict outside the stale route.
  expect(()=>CachePartitions.box('notifications_box'),throwsStateError);
  await tester.pumpWidget(const MaterialApp(home:HomePage(userName:'Test',companyName:'Test',companyCode:'C1')));
  expect(tester.takeException(),isNull);
  await tester.pump(const Duration(seconds:2));
  expect(tester.takeException(),isNull);
  expect(find.byType(Scaffold),findsNothing);
  expect(()=>CachePartitions.box('notifications_box'),throwsStateError);
  await tester.pumpWidget(const SizedBox());
 });
}
