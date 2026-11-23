import 'package:islam_app/services/cache_partitions.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/core/theme.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/views/dashboard/commercial/sales_page.dart';
import 'package:islam_app/views/dashboard/commercial/sales_dashboard_page.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory directory;
  setUpAll(() async {
    await (FontLoader('Cairo')
          ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('commercial_colors_');
    Hive.init(directory.path);
    await Hive.openBox('coding_box');
    await Hive.openBox('users_box');
    SharedPreferences.setMockInitialValues({'company_code': 'C1'});
    f.currentUid = 'uid-A';
    CachePartitions.enable();
    await CachePartitions.activate('uid-A', 'C1');
    PermissionsService().debugSetPermissionsForTest(
        {
          'المبيعات': {
            'إضافة': true,
            'معاينة': true,
            'تعديل': true,
            'حذف': true
          },
          'المرتجعات': {'إضافة': true, 'معاينة': true},
          'حسابات العملاء': {'إضافة تحصيل': true, 'معاينة تحصيل': true},
        },
        role: 'employee',
        branches: ['B1']);
    final box = CachePartitions.box('coding_box');
    await box.put('C1_branches', [
      {'code': 'B1', 'name': 'الفرع الرئيسي'}
    ]);
    await box.put('C1_stores', [
      {'code': 'S1', 'name': 'المخزن الرئيسي', 'branch_code': 'B1'}
    ]);
    await box.put('C1_customers', [
      {'code': 'CU1', 'name': 'عميل تجربة'}
    ]);
    await box.put('C1_items', [
      {'code': 'P1', 'name': 'صنف تجربة', 'price': 100}
    ]);
  });
  tearDown(() async {
    CachePartitions.suspend();
    await Hive.close();
    directory.deleteSync(recursive: true);
  });
  for (final dark in [false, true]) {
    testWidgets('shared semantic foreground contrast dark=$dark',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          home: Builder(builder: (context) {
            final theme = Theme.of(context);
            double contrast(Color a, Color b) {
              final x = a.computeLuminance(), y = b.computeLuminance();
              return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
            }

            expect(
                contrast(
                    theme.colorScheme.primary, theme.colorScheme.onPrimary),
                greaterThanOrEqualTo(4.5));
            for (final color in [
              AppTheme.accentFor(context),
              AppTheme.dangerFor(context),
              AppTheme.warningOrangeFor(context),
              AppTheme.successFor(context),
              AppTheme.infoSoftFor(context)
            ]) {
              final background = Color.alphaBlend(
                  color.withAlpha(dark ? 26 : 15), AppTheme.surface(context));
              expect(contrast(color, background), greaterThanOrEqualTo(4.5));
            }
            for (final color in [
              AppTheme.warningOrangeFor(context),
              AppTheme.successFor(context)
            ]) {
              expect(contrast(color, AppTheme.onAccentFor(context)),
                  greaterThanOrEqualTo(4.5));
            }
            expect(theme.cardTheme.color, AppTheme.surface(context));
            return const SizedBox();
          })));
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final dark in [false, true]) {
    for (final dashboard in [false, true]) {
      for (final narrow in [false, true]) {
        testWidgets(
            'real commercial colors dark=$dark dashboard=$dashboard narrow=$narrow',
            (tester) async {
          tester.view.physicalSize =
              narrow ? const Size(390, 1300) : const Size(1280, 1500);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final page = dashboard
              ? const SalesDashboardPage(companyCode: 'C1', branchCode: 'B1')
              : SalesPage(
                  companyCode: 'C1',
                  selectedBranchCode: 'B1',
                  userName: 'مستخدم تجربة',
                  editItem: {
                      'branch_code': 'B1',
                      'store_code': 'S1',
                      'customer_code': 'CU1',
                      'discount': 10,
                      'due': narrow ? 0 : 40,
                      'items': [
                        {
                          'code': 'P1',
                          'name': 'صنف تجربة',
                          'quantity': 2,
                          'price': 100
                        }
                      ],
                      'payments': [
                        {'method': 'نقدي', 'treasury': 'نقدي', 'amount': 150}
                      ],
                    });
          await tester.pumpWidget(MaterialApp(
              theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
              home: Directionality(
                  textDirection: TextDirection.rtl, child: page)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await expectLater(
              find.byType(dashboard ? SalesDashboardPage : SalesPage),
              matchesGoldenFile(
                  'goldens/commercial_colors_${dark ? 'dark' : 'light'}_${dashboard ? 'dashboard' : 'invoice'}${narrow ? '_narrow' : ''}.png'));
          if (narrow && !dashboard) {
            await tester.drag(
                find.byType(ListView).first, const Offset(0, -1050));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await expectLater(
                find.byType(SalesPage),
                matchesGoldenFile(
                    'goldens/commercial_colors_${dark ? 'dark' : 'light'}_cash_warning_narrow.png'));
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
