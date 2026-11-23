import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/core/theme.dart';
import 'package:islam_app/views/widgets/permission_editor_state.dart';

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
  testWidgets('all-branch startup shows coded catalog name without unavailable placeholder',(tester) async {
    tester.view.physicalSize=const Size(390,600);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme:AppTheme.lightTheme,home:Directionality(textDirection:TextDirection.rtl,
      child:Scaffold(body:Padding(padding:const EdgeInsets.all(20),child:PermissionEditorStartup(value:'1',
        choices:const [{'code':'1','name':'الفرع الرئيسي'}],allowed:const ['all'],enabled:true,onChanged:(_){}))))));
    await tester.pumpAndSettle();
    expect(find.text('الفرع الرئيسي'),findsOneWidget);
    expect(find.textContaining('غير متاح'),findsNothing);
    await expectLater(find.byType(Scaffold),matchesGoldenFile('goldens/startup_branch_catalog_fixed.png'));
  });
  for (final dark in [false, true]) {
    for (final narrow in [false, true]) {
      testWidgets(
          'actual editor status and startup widgets dark=$dark narrow=$narrow',
          (tester) async {
        tester.view.physicalSize =
            narrow ? const Size(390, 800) : const Size(1000, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var reloads = 0;
        String? chosen;
        const branches = [
          {'code': 'B2', 'name': 'فرع القاهرة'},
          {'code': 'B4', 'name': 'فرع غير مسموح'}
        ];
        const allowed = ['B2'];
        await tester.pumpWidget(MaterialApp(
            theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
            home: Directionality(
                textDirection: TextDirection.rtl,
                child: Scaffold(
                    body: SafeArea(
                        child: ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('إدارة الصلاحيات',
                        style:
                            const TextStyle(fontFamily: 'Cairo', fontSize: 22)),
                  ),
                  PermissionEditorStatus(
                      loading: false,
                      saving: false,
                      error: null,
                      onReload: () {
                        reloads++;
                      }),
                  PermissionEditorStatus(
                      loading: false,
                      saving: false,
                      error:
                          'تغيرت بيانات الحساب. أعد التحميل قبل الحفظ حتى لا تضيع تعديلات أحدث',
                      onReload: () {
                        reloads++;
                      }),
                  Padding(
                      padding: const EdgeInsets.all(20),
                      child: PermissionEditorStartup(
                          value: 'B3',
                          choices: branches,
                          allowed: allowed,
                          enabled: true,
                          onChanged: (v) {
                            chosen = v;
                          })),
                ]))))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('تم الحفظ محلياً'), findsNothing);
        await expectLater(
            find.byType(Scaffold),
            matchesGoldenFile(
                'goldens/permission_editor_${dark ? 'dark' : 'light'}_${narrow ? 'narrow' : 'wide'}.png'));
        await tester.tap(find.byTooltip('إعادة تحميل بيانات الحساب').first);
        await tester.pump();
        expect(reloads, 1);
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        expect(find.text('فرع غير مسموح'), findsNothing);
        await tester.tap(find.text('فرع القاهرة').last);
        await tester.pumpAndSettle();
        expect(chosen, 'B2');
        expect(allowed, ['B2']);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('saving status cannot offer a reload during an in-flight write',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: PermissionEditorStatus(
                loading: false, saving: true, error: null, onReload: null))));
    expect(find.byType(IconButton), findsNothing);
    expect(find.textContaining('تأكيد الخادم'), findsOneWidget);
  });
}
