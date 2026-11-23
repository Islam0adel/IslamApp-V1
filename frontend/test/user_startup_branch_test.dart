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
          ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  final branches = [
    {'code': 'B1', 'name': 'الفرع الرئيسي'},
    {'code': 'B2', 'name': 'الفرع الثاني'},
    {'code': 'B3', 'name': 'فرع غير مسموح'},
  ];
  Map<String, dynamic> user({String start = 'B1'}) => {
        'email': 'fixture@example.invalid',
        'name': 'مستخدم تجربة',
        'phone_number': '',
        'branch_code': start,
        'allowed_branches': ['B1', 'B2'],
        'role': 'employee',
        'status': 'active',
      };
  Future<void> show(WidgetTester tester,
      {required ValueChanged<dynamic> result,
      bool dark = false,
      bool canEdit = true,
      bool changeStatus = false,
      Map<String, dynamic>? data}) async {
    await tester.pumpWidget(MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () async {
                          result(await showDialog(
                              context: context,
                              builder: (_) => Directionality(
                                  textDirection: TextDirection.rtl,
                                  child: CompanyUserEditDialog(
                                      user: data ?? user(),
                                      branches: branches,
                                      allowedRoles: const {},
                                      canChangeRole: false,
                                      canEditMetadata: canEdit,
                                      canChangeStatus: changeStatus))));
                        },
                        child: const Text('فتح')))))));
    await tester.tap(find.text('فتح'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final dark in [false, true]) {
    for (final narrow in [false, true]) {
      testWidgets('actual startup edit dialog dark=$dark narrow=$narrow',
          (tester) async {
        tester.view.physicalSize =
            narrow ? const Size(390, 1100) : const Size(1100, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        dynamic result;
        await show(tester, dark: dark, result: (value) => result = value);
        expect(find.text('فرع بداية الاستخدام'), findsOneWidget);
        expect(find.text('لا يغيّر الفروع المسموحة أو فرع العمل.'),
            findsOneWidget);
        await expectLater(
            find.byType(AlertDialog),
            matchesGoldenFile(
                'goldens/user_startup_${dark ? 'dark' : 'light'}_${narrow ? 'narrow' : 'wide'}.png'));
        await tester.tap(find.text('حفظ'));
        await tester.pumpAndSettle();
        expect(result, isA<Map>());
        expect(result.containsKey('branch_code'), false);
        expect(result.containsKey('allowed_branches'), false);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final dark in [false, true]) {
    testWidgets('status-only editor hides metadata dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      dynamic result;
      await show(tester, dark: dark, canEdit: false, changeStatus: true,
          result: (value) => result = value);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('فرع بداية الاستخدام'), findsNothing);
      await expectLater(find.byType(AlertDialog), matchesGoldenFile(
          'goldens/user_status_only_${dark ? 'dark' : 'light'}.png'));
      await tester.tap(find.text('نشط'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('موقوف').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(result, {'status': 'suspended', 'is_active': true});
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('pending account status stays pending unless explicitly changed', (tester) async {
    dynamic result;
    final data = user()..['status'] = 'pending';
    await show(tester, data: data, canEdit: false, changeStatus: true,
        result: (value) => result = value);
    expect(find.text('معلق'), findsOneWidget);
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(result, {'status': 'pending', 'is_active': true});
    expect(tester.takeException(), isNull);
  });
  for (final unblock in [false, true]) {
    testWidgets('blocked pending account does not silently activate unblock=$unblock', (tester) async {
      dynamic result;
      final data = user()..['is_active'] = false..['status'] = 'pending';
      await show(tester, data: data, canEdit: false, changeStatus: true,
          result: (value) => result = value);
      expect(find.text('محظور'), findsOneWidget);
      if (unblock) {
        await tester.tap(find.text('محظور'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('معلق').last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(result, unblock ? {'status': 'pending', 'is_active': true} : {'is_active': false});
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('explicit startup change sends only the changed startup value',
      (tester) async {
    dynamic result;
    await show(tester, result: (value) => result = value);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('فرع غير مسموح'), findsNothing);
    await tester.tap(find.text('الفرع الثاني').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(result['branch_code'], 'B2');
    expect(result.containsKey('allowed_branches'), false);
  });
  testWidgets(
      'unavailable historical startup does not silently select the first branch',
      (tester) async {
    dynamic result;
    await show(tester,
        data: user(start: 'B9'), result: (value) => result = value);
    expect(find.text('B9 (غير متاح حالياً)'), findsOneWidget);
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(result.containsKey('branch_code'), false);
    expect(tester.takeException(), isNull);
  });
  testWidgets('all means all already-permitted branches, not an access grant',
      (tester) async {
    dynamic result;
    await show(tester, result: (value) => result = value);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('كل الفروع المسموحة').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(result['branch_code'], '');
    expect(result.containsKey('allowed_branches'), false);
  });
}
