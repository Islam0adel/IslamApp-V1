// اختبار واجهة (بكسلات حقيقية) لتجربة الصنف "غير محدد السعر":
// فتح تعديل صنف موسوم cost_pending يعرض حقل تكلفة فارغاً (لا
// صفراً مضللاً) مع شارة توضيحية، وإدخال صفر صراحة يطلب تأكيداً
// واعياً قبل الحفظ. Hive مؤقت بلا خادم ولا شبكة.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/views/dashboard/coding_page.dart';

Directory? _tmp;

Future<void> _loadCairoFont() async {
  final regular = rootBundle.load('assets/fonts/Cairo-Regular.ttf');
  final bold = rootBundle.load('assets/fonts/Cairo-Bold.ttf');
  final loader = FontLoader('Cairo')
    ..addFont(regular)
    ..addFont(bold);
  await loader.load();
}

Future<void> _setupHive() async {
  _tmp = await Directory.systemTemp.createTemp('hive_coding_pending_');
  Hive.init(_tmp!.path);
  final box = await Hive.openBox('coding_box');
  await box.put('01_items', [
    {
      'code': '9',
      'name': 'صنف بلا سعر',
      'type': 'وارد',
      'barcode': '',
      'wholesale_price': 0.0,
      'selling_price': 12.5,
      'profit_margin': 0.0,
      'profit_percent': 0.0,
      'cost_pending': true,
      'is_deleted': false,
    },
  ]);
  await box.put('01_branches', [
    {'code': 'B1', 'name': 'فرع 1'},
  ]);
}

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  PermissionsService().debugSetPermissionsForTest(
    {
      'التكويد': {
        'سعر الشراء': true, 'اضافة صنف': true, 'معاينة': true,
      },
    },
    role: 'admin',
    branches: ['all'],
  );
  await tester.pumpWidget(const MaterialApp(
    home: CodingPage(companyCode: '01'),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _openPendingItemForEdit(WidgetTester tester) async {
  await tester.ensureVisible(find.text('معاينة'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('معاينة'));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.tap(find.text('صنف بلا سعر'));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadCairoFont();
    await _setupHive();
  });

  tearDownAll(() async {
    await Hive.close();
    if (_tmp != null && _tmp!.existsSync()) {
      _tmp!.deleteSync(recursive: true);
    }
  });

  testWidgets('تعديل صنف غير محدد: حقل تكلفة فارغ + شارة', (tester) async {
    await _pumpPage(tester);
    await _openPendingItemForEdit(tester);

    // حقل الجملة فارغ لا "0.0"
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'سعر الجملة'),
    );
    expect(field.controller!.text, isEmpty,
        reason: 'الصفر الشكلي لا يملأ الحقل');
    expect(find.textContaining('سعر الشراء غير محدد'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/coding_pending_edit_mobile.png'),
    );
  });

  testWidgets('إدخال صفر صراحة يطلب تأكيداً واعياً', (tester) async {
    await _pumpPage(tester);
    await _openPendingItemForEdit(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'سعر الجملة'), '0');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('تحديث'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.text('تأكيد سعر صفري'), findsOneWidget);
    expect(find.textContaining('صفر عن قصد'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/coding_pending_zero_confirm.png'),
    );
  });
}
