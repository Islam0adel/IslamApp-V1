import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/core/theme.dart';
import 'package:islam_app/views/dashboard/company_users_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Cairo')
      ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf'))).load();
    await (FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final dark in [false, true]) {
    testWidgets('old phone invitation email field dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(390, 880);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: Builder(builder: (context) => Scaffold(body: TextButton(
          child: const Text('open'), onPressed: () async {
            saved = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const CompanyUserEditDialog(
              user: {'email':'phone_01000000000', 'uid':'', 'name':'دعوة موظف', 'phone_number':'01000000000',
                'username':'', 'invitation_email':'', 'can_set_invitation_email':true,
                'status':'pending', 'role':'employee', 'allowed_branches':['B1'], 'branch_code':'B1'},
              branches:[{'code':'B1','name':'فرع القاهرة'}],
              allowedRoles:{'employee':'موظف'}, canChangeRole:false, canChangeStatus:false));
          })))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('بريد الدعوة (مطلوب)'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'invited@example.com');
      await tester.pumpAndSettle();
      await expectLater(find.byType(AlertDialog), matchesGoldenFile('goldens/invitation_email_${dark ? 'dark' : 'light'}.png'));
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(saved?['invitation_email'], 'invited@example.com');
      expect(saved!.containsKey('allowed_branches'), false);
      expect(tester.takeException(), isNull);
    });
  }
}
