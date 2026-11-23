// اختبار واجهة (بكسلات حقيقية بخط Cairo) لإخفاء أسعار وإجماليات
// المشتريات عن من لا يملك حق التكلفة. فاتورة ممثلة بقيم مميزة
// (10.50 × 2 = 21.00 و7.25 × 3 = 21.75 والإجمالي 42.75) حتى
// يثبت الإخفاء/الظهور على أرقام فعلية لا صفحات فارغة.
// يضخ الصفحة الحقيقية SupplierPage بصناديق Hive مؤقتة بلا خادم
// ولا شبكة ولا Firestore. لقطات: موبايل + ديسكتوب لكلتا الحالتين.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:islam_app/models/supplier_settlement_model.dart';
import 'package:islam_app/models/supplier_transaction_model.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/supplier_service.dart';
import 'package:islam_app/views/dashboard/supplier_page.dart';

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
  _tmp = Directory.systemTemp.createTempSync('supplier_ui_');
  Hive.init(_tmp!.path);
  for (final name in [
    'coding_box',
    'supplier_box',
    'supplier_settlement_box',
  ]) {
    if (!Hive.isBoxOpen(name)) await Hive.openBox(name);
  }
  await Hive.box('coding_box').put('01_stores', [
    {'code': 'S1', 'name': 'مخزن 1', 'branch_code': ''},
  ]);
  await Hive.box('coding_box').put('01_suppliers', [
    {'code': 'M1', 'name': 'مورد 1'},
  ]);
  await Hive.box('coding_box').put('01_treasuries', [
    {'code': 'T1', 'name': 'خزينة 1', 'branch_code': ''},
  ]);
}

Map<String, dynamic> _perms({required bool costRight}) => {
      'صلاحيات عامة': {'إظهار حركة الموردين': true},
      'حسابات الموردين': {'اضافة': true, 'تعديل': true},
      'التكويد': {
        'سعر الشراء': costRight,
        'اضافة صنف': false,
      },
      'المبيعات': {'عرض سعر الجملة': false},
      'رصيد المخزون': {'عرض سعر الجملة': false},
    };

/// فاتورة ممثلة بقيم مميزة غير قابلة للالتباس.
SupplierTransactionModel _fixtureInvoice() => SupplierTransactionModel(
      companyCode: '01',
      branchCode: '1',
      storeCode: 'S1',
      serial: 7,
      date: '2026-11-21',
      supplierName: 'مورد 1',
      paymentMethod: 'نقدي',
      treasury: 'T1',
      employee: 'احمد',
      docId: '42',
      items: [
        SupplierItem(
          code: 'I1',
          name: 'صنف أول',
          quantity: 2,
          price: 10.50,
          total: 21.00,
        ),
        SupplierItem(
          code: 'I2',
          name: 'صنف ثان',
          quantity: 3,
          price: 7.25,
          total: 21.75,
        ),
      ],
      totalAmount: 42.75,
    );

Widget _app() => MaterialApp(
      theme: ThemeData(fontFamily: 'Cairo'),
      home: SupplierPage(
        companyCode: '01',
        userName: 'احمد',
        editItem: _fixtureInvoice(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await _setupHive();
    await _loadCairoFont();
  });
  tearDown(() async {
    await Hive.close();
    if (_tmp != null && _tmp!.existsSync()) {
      _tmp!.deleteSync(recursive: true);
    }
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required bool costRight,
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    PermissionsService().debugSetPermissionsForTest(
      _perms(costRight: costRight),
      role: 'employee',
    );
    await tester.pumpWidget(_app());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
      'ديسكتوب بدون حق التكلفة: الأسعار والإجماليات مخفية '
      '(—) والقيم الحقيقية غائبة تماماً', (tester) async {
    await pumpPage(
      tester,
      costRight: false,
      size: const Size(1400, 900),
    );

    expect(find.text('—'), findsWidgets);
    // لا تسريب لأي قيمة مشتقة من التكلفة
    expect(find.text('10.5'), findsNothing);
    expect(find.text('7.25'), findsNothing);
    expect(find.text('21.00'), findsNothing);
    expect(find.text('21.75'), findsNothing);
    expect(find.text('42.75'), findsNothing);
    expect(find.text('0.00'), findsNothing);
    expect(find.text('الإجمالي بعد الخصم'), findsNothing);
    expect(find.text('الرصيد'), findsNothing);
    // البيانات غير المحمية تظهر عادياً
    expect(find.text('صنف أول'), findsWidgets);

    await expectLater(
      find.byType(SupplierPage),
      matchesGoldenFile('goldens/supplier_masked_desktop.png'),
    );
  });

  testWidgets(
      'ديسكتوب مع حق التكلفة: كل القيم ظاهرة بلا تغيير',
      (tester) async {
    await pumpPage(
      tester,
      costRight: true,
      size: const Size(1400, 900),
    );

    expect(find.text('10.5'), findsWidgets);
    expect(find.text('21.00'), findsWidgets);
    expect(find.text('21.75'), findsWidgets);
    expect(find.text('الإجمالي بعد الخصم'), findsOneWidget);
    expect(find.text('42.75'), findsWidgets);
    expect(find.text('—'), findsNothing);

    await expectLater(
      find.byType(SupplierPage),
      matchesGoldenFile('goldens/supplier_full_desktop.png'),
    );
  });

  testWidgets(
      'موبايل بدون حق التكلفة: نفس الإخفاء على التخطيط '
      'الصغير', (tester) async {
    await pumpPage(
      tester,
      costRight: false,
      size: const Size(500, 900),
    );

    expect(find.text('—'), findsWidgets);
    expect(find.text('10.5'), findsNothing);
    expect(find.text('42.75'), findsNothing);
    expect(find.text('الإجمالي بعد الخصم'), findsNothing);

    await expectLater(
      find.byType(SupplierPage),
      matchesGoldenFile('goldens/supplier_masked_mobile.png'),
    );
  });

  testWidgets('موبايل مع حق التكلفة: القيم ظاهرة',
      (tester) async {
    await pumpPage(
      tester,
      costRight: true,
      size: const Size(500, 900),
    );

    expect(find.text('10.5'), findsWidgets);
    expect(find.text('21.00'), findsWidgets);
    expect(find.text('—'), findsNothing);

    await expectLater(
      find.byType(SupplierPage),
      matchesGoldenFile('goldens/supplier_full_mobile.png'),
    );
  });

  test('رصيد المورد: null صريح لمن لا يملك حق التكلفة (لا NaN)',
      () async {
    PermissionsService().debugSetPermissionsForTest(
      _perms(costRight: false),
      role: 'employee',
    );
    final service = SupplierService();
    final balance =
        await service.getSupplierBalance('01', 'all', 'مورد 1');
    expect(balance, isNull);
  });

  test('رصيد المورد: قيمة رقمية صحيحة لصاحب الحق', () async {
    PermissionsService().debugSetPermissionsForTest(
      _perms(costRight: true),
      role: 'employee',
    );
    final service = SupplierService();
    final balance =
        await service.getSupplierBalance('01', 'all', 'مورد 1');
    expect(balance, isNotNull);
    expect(balance!.isNaN, isFalse);
  });

  test('حمولة التسوية مبلغ فقط: لا رصيد ولا إجمالي ولا أسعار',
      () {
    final model = SupplierSettlementModel(
      companyCode: '01',
      branchCode: '1',
      supplierName: 'مورد 1',
      date: '2026-11-21',
      serial: 1,
      amount: 500.0,
      paymentMethod: 'نقدي',
      treasury: 'خزينة 1',
      statement: 'دفعة',
      employee: 'احمد',
    );
    final map = model.toMap();
    expect(map['amount'], 500.0);
    for (final key in map.keys) {
      final k = key.toString();
      expect(k.contains('balance'), isFalse, reason: k);
      expect(k.contains('total'), isFalse, reason: k);
      expect(k.contains('price'), isFalse, reason: k);
    }
  });
}
