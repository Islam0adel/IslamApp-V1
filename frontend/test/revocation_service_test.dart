// اختبارات سلوكية لدورة حياة سحب الصلاحيات (RevocationService)
// بصناديق Hive حقيقية على قرص مؤقت وبمفاتيح/خرائط صلاحيات
// بنفس شكل العميل الفعلي. لا خادم ولا شبكة.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/revocation_service.dart';

Directory? _tmpDir;

Future<void> _openBoxes() async {
  for (final name in [
    'commercial_pending_box',
    'hr_pending_box',
    'coding_box',
    'inventory_box',
    'supplier_box',
    'sales_box',
    'commercial_stock_events_box',
  ]) {
    if (!Hive.isBoxOpen(name)) {
      await Hive.openBox(name);
    }
  }
}

Future<void> _resetHive() async {
  await Hive.close();
  if (_tmpDir != null && _tmpDir!.existsSync()) {
    _tmpDir!.deleteSync(recursive: true);
  }
  _tmpDir = Directory.systemTemp.createTempSync('revoke_test_');
  Hive.init(_tmpDir!.path);
  await _openBoxes();
}

/// خريطة صلاحيات كاملة الشكل (كل قسم فيه مفتاح واحد مسموح)
/// بنفس بنية permissions_$email في coding_box.
Map<String, dynamic> fullPerms() => {
      'حركة الجرد': {'اذن اضافة مخزون': true},
      'حسابات الموردين': {'اضافة': true},
      'تسويات الموردين': {'اضافة': true},
      'المبيعات': {'اضافة فاتورة': true},
      'المرتجعات': {'إضافة': true},
      'التحويلات المخزنية': {'إضافة': true},
      'حسابات العملاء': {'اضافة تحصيل': true},
      'حركة الخزينة': {'اضافة حركة': true},
      'أرصدة خزائن المبيعات': {'معاينة': true},
      'التكويد': {'سعر الشراء': true, 'اضافة صنف': true},
      'الموارد البشرية': {'معاينة': true},
    };

Map<String, dynamic> withoutSection(
  Map<String, dynamic> perms,
  String section,
) {
  final out = <String, dynamic>{};
  perms.forEach((k, v) {
    if (k == section) return;
    out[k] = Map<String, dynamic>.from(v as Map);
  });
  return out;
}

void main() {
  setUp(_resetHive);
  tearDown(() async {
    await Hive.close();
    if (_tmpDir != null && _tmpDir!.existsSync()) {
      _tmpDir!.deleteSync(recursive: true);
    }
  });

  test(
      'سحب قسم يعلّق عمليات القسم للمالك فقط: نوع مجهول '
      'ومستخدم آخر وعمليات HR لا تمس', () async {
    final commercial = Hive.box('commercial_pending_box');
    final hr = Hive.box('hr_pending_box');
    await commercial.put('01_s1', {
      'kind': 'sales',
      'company_code': '01',
      'user_uid': 'u1',
      'data': {'branch_code': '1'},
    });
    await commercial.put('01_s2', {
      'kind': 'sales',
      'company_code': '01',
      'user_uid': 'u2',
    });
    await commercial.put('01_x1', {
      'kind': 'weird_kind',
      'company_code': '01',
      'user_uid': 'u1',
    });
    await commercial.put('01_legacy', {
      'kind': 'sales',
      'company_code': '01',
    });
    await hr.put('01_E1_2026-11-01', {
      'company_code': '01',
      'user_uid': 'u1',
      'action': 'save',
    });

    final needsResync = await RevocationService.instance
        .applyTransition(
      email: 'a@b.c',
      companyCode: '01',
      oldPerms: fullPerms(),
      newPerms: withoutSection(fullPerms(), 'المبيعات'),
      ownerUid: 'u1',
    );

    expect(needsResync, isTrue);
    final s1 = commercial.get('01_s1') as Map;
    expect(s1['revoked_hold'], isTrue);
    expect(s1['revoked_hold_section'], 'المبيعات');

    final s2 = commercial.get('01_s2') as Map;
    expect(s2.containsKey('revoked_hold'), isFalse,
        reason: 'عملية مستخدم آخر لا تُعلَّق');

    final x1 = commercial.get('01_x1') as Map;
    expect(x1.containsKey('revoked_hold'), isFalse,
        reason: 'نوع مجهول لا يُعلَّق مع المبيعات');

    final legacy = commercial.get('01_legacy') as Map;
    expect(legacy.containsKey('revoked_hold'), isFalse,
        reason: 'عملية بلا مالك لا تُعلَّق');

    final hrOp = hr.get('01_E1_2026-11-01') as Map;
    expect(hrOp.containsKey('revoked_hold'), isFalse,
        reason: 'قسم آخر في صندوق مختلف لا يتأثر');
  });

  test(
      'عودة القسم ترفع التعليق بعد تحقق الفروع: عملية فرع '
      'خارج النطاق تبقى معلقة', () async {
    final commercial = Hive.box('commercial_pending_box');
    await commercial.put('01_b2', {
      'kind': 'sales',
      'company_code': '01',
      'user_uid': 'u1',
      'data': {'branch_code': '2'},
      'revoked_hold': true,
      'revoked_hold_section': 'المبيعات',
      'hold_reason': 'صلاحية القسم مسحوبة حالياً',
    });
    await commercial.put('01_b1', {
      'kind': 'sales',
      'company_code': '01',
      'user_uid': 'u1',
      'data': {'branch_code': '1'},
      'revoked_hold': true,
      'revoked_hold_section': 'المبيعات',
    });

    // عودة المبيعات لكن الفروع مقيدة بفرع 1 فقط
    final old = withoutSection(fullPerms(), 'المبيعات');
    await RevocationService.instance.applyTransition(
      email: 'a@b.c',
      companyCode: '01',
      oldPerms: old,
      newPerms: fullPerms(),
      oldBranches: ['1'],
      newBranches: ['1'],
      ownerUid: 'u1',
    );

    final b1 = commercial.get('01_b1') as Map;
    expect(b1.containsKey('revoked_hold'), isFalse,
        reason: 'فرع 1 داخل النطاق: يُرفع التعليق');
    final b2 = commercial.get('01_b2') as Map;
    expect(b2['revoked_hold'], isTrue,
        reason: 'فرع 2 خارج النطاق: يبقى معلقاً');
  });

  test('نوع مجهول لا يُرفع تعليقه تلقائياً أبداً', () async {
    final commercial = Hive.box('commercial_pending_box');
    await commercial.put('01_x1', {
      'kind': 'weird_kind',
      'company_code': '01',
      'user_uid': 'u1',
      'revoked_hold': true,
      'revoked_hold_section': 'عمليات غير مصنفة',
    });

    final old = withoutSection(fullPerms(), 'المبيعات');
    await RevocationService.instance.applyTransition(
      email: 'a@b.c',
      companyCode: '01',
      oldPerms: old,
      newPerms: fullPerms(),
      ownerUid: 'u1',
    );

    final x1 = commercial.get('01_x1') as Map;
    expect(x1['revoked_hold'], isTrue,
        reason: 'لا تفويض ضمني بنوع مجهول');
  });

  test(
      'سحب حق التكلفة ينتزع حقول الجملة والأسعار من الكتالوج '
      'والجرد وفواتير الموردين المخزنة', () async {
    final coding = Hive.box('coding_box');
    final inventory = Hive.box('inventory_box');
    final supplier = Hive.box('supplier_box');

    await coding.put('01_items', [
      {
        'code': 'I1',
        'name': 'صنف',
        'wholesale_price': 10.0,
        'wholesalePrice': 10.0,
      }
    ]);
    await inventory.put('01_1_2026-11-21', [
      {
        'doc_id': '1',
        'total_wholesale': 100.0,
        'items': [
          {'code': 'I1', 'wholesalePrice': 10.0, 'name': 'صنف'}
        ],
      }
    ]);
    await supplier.put('01_1_2026-11-20', [
      {
        'doc_id': '9',
        'supplier_name': 'مورد',
        'total_amount': 200.0,
        'items': [
          {
            'code': 'I1',
            'price': 100.0,
            'total': 200.0,
            'discountAmount': 0.0,
            'name': 'صنف',
          }
        ],
      }
    ]);

    final oldPerms = fullPerms();
    final newPerms = fullPerms();
    (newPerms['التكويد'] as Map)['سعر الشراء'] = false;

    await RevocationService.instance.applyTransition(
      email: 'a@b.c',
      companyCode: '01',
      oldPerms: oldPerms,
      newPerms: newPerms,
      ownerUid: 'u1',
    );

    final item = (coding.get('01_items') as List).first as Map;
    expect(item.containsKey('wholesale_price'), isFalse);
    expect(item.containsKey('wholesalePrice'), isFalse);
    expect(item['name'], 'صنف', reason: 'الصف الصالح يبقى');

    final invRow =
        (inventory.get('01_1_2026-11-21') as List).first as Map;
    expect(invRow.containsKey('total_wholesale'), isFalse);
    expect(
        (invRow['items'] as List).first
            .containsKey('wholesalePrice'),
        isFalse);

    final supRow =
        (supplier.get('01_1_2026-11-20') as List).first as Map;
    expect(supRow.containsKey('total_amount'), isFalse,
        reason: 'الإجمالي لا يبقى على جهاز من لا يملك حقه');
    expect(supRow['supplier_name'], 'مورد');
    final supItem = (supRow['items'] as List).first as Map;
    expect(supItem.containsKey('price'), isFalse);
    expect(supItem.containsKey('total'), isFalse);
    expect(supItem['name'], 'صنف');
  });

  test(
      'تضييق الموظفين المرئيين: صفوف الخارجين وصفوف بلا '
      'employee_code تُحذف (إغلاق عند المجهول)', () async {
    final coding = Hive.box('coding_box');
    await coding.put('01_hr_attendance', [
      {'employee_code': 'E1', 'day': '2026-11-01'},
      {'employee_code': 'E2', 'day': '2026-11-01'},
      {'day': '2026-11-01'}, // بلا كود موظف
    ]);

    await RevocationService.instance.applyTransition(
      email: 'a@b.c',
      companyCode: '01',
      oldPerms: fullPerms(),
      newPerms: fullPerms(),
      oldViewable: ['E1', 'E2'],
      newViewable: ['E1'],
      ownerUid: 'u1',
    );

    final rows = (coding.get('01_hr_attendance') as List);
    expect(rows.length, 1);
    expect((rows.first as Map)['employee_code'], 'E1');
  });

  test(
      'تسوية بدء التشغيل: المعلَّق بقسم مسموح يُرفع، '
      'والمعلق بقسم مسحوب يبقى', () async {
    final commercial = Hive.box('commercial_pending_box');
    await commercial.put('01_a', {
      'kind': 'sales',
      'company_code': '01',
      'user_uid': 'u1',
      'revoked_hold': true,
      'revoked_hold_section': 'المبيعات',
    });
    await commercial.put('01_b', {
      'kind': 'sale_returns',
      'company_code': '01',
      'user_uid': 'u1',
      'revoked_hold': true,
      'revoked_hold_section': 'المرتجعات',
    });

    // حالة سابقة مجهولة، الحالية تسمح المبيعات دون المرتجعات
    await RevocationService.instance.applyTransition(
      email: 'a@b.c',
      companyCode: '01',
      oldPerms: null,
      newPerms: withoutSection(fullPerms(), 'المرتجعات'),
      ownerUid: 'u1',
    );

    final a = commercial.get('01_a') as Map;
    expect(a.containsKey('revoked_hold'), isFalse,
        reason: 'قسم مسموح حالياً يُرفع تعليقه');
    final b = commercial.get('01_b') as Map;
    expect(b['revoked_hold'], isTrue,
        reason: 'قسم ما زال مسحوباً يبقى معلقاً');
  });

  test('مسار تسوية الملكية: عرض، نسب للجلسة فقط، استبعاد قابل للاسترجاع',
      () async {
    RevocationService.debugCurrentUidForTest = 'u1';
    addTearDown(() =>
        RevocationService.debugCurrentUidForTest = null);
    // مدير بحق المبيعات والمرتجعات والحضور، كل الفروع
    PermissionsService().debugSetPermissionsForTest({
      'المبيعات': {'إضافة': true, 'حذف': true},
      'المرتجعات': {'إضافة': true},
      'الموارد البشرية': {'canAddAttendance': true},
    }, role: 'admin', branches: ['all']);
    addTearDown(() => PermissionsService()
        .debugSetPermissionsForTest(null, role: 'employee'));

    final commercial = Hive.box('commercial_pending_box');
    await commercial.put('01_legacy1', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '01',
      'ownership_unverified': true,
    });
    await commercial.put('01_owned', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '01',
      'user_uid': 'u9',
    });
    await commercial.put('02_other_company', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '02',
    });
    await commercial.put('01_to_discard', {
      'kind': 'returns',
      'action': 'save',
      'company_code': '01',
    });

    final listed = RevocationService.instance
        .listUnverifiedOwnershipOps('01');
    expect(listed.length, 2);
    expect(
      listed.map((e) => e['key']).toSet(),
      {'01_legacy1', '01_to_discard'},
      reason: 'المملوكة وعمليات الشركات الأخرى لا تُعرض',
    );

    // نسب عملية مملوكة ممنوع
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_owned',
        companyCode: '01',
      ),
      isFalse,
    );

    // نسب عملية شركة أخرى ممنوع (عزل المستأجرين)
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '02_other_company',
        companyCode: '01',
      ),
      isFalse,
    );

    // النسب الصريح: الهوية من الجلسة فقط + ختم تدقيق
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_legacy1',
        companyCode: '01',
      ),
      isTrue,
    );
    final assigned = commercial.get('01_legacy1') as Map;
    expect(assigned['user_uid'], 'u1');
    expect(assigned['assigned_by'], 'u1');
    expect(assigned['assigned_at'], isNotNull);
    expect(
      assigned.containsKey('ownership_unverified'),
      isFalse,
    );
    expect(assigned.containsKey('revoked_hold'), isFalse,
        reason: 'التحقق عند النسب يرفع التعليق فوراً');

    // استبعاد عملية مملوكة عبر هذا المسار ممنوع
    expect(
      await RevocationService.instance.discardUnverifiedPendingOp(
        boxName: 'commercial_pending_box',
        key: '01_owned',
        companyCode: '01',
      ),
      isFalse,
    );
    expect(commercial.containsKey('01_owned'), isTrue);

    // الاستبعاد ليس حذفاً: السجل يبقى، خارج القوائم، معلّق
    expect(
      await RevocationService.instance.discardUnverifiedPendingOp(
        boxName: 'commercial_pending_box',
        key: '01_to_discard',
        companyCode: '01',
      ),
      isTrue,
    );
    final d = commercial.get('01_to_discard') as Map;
    expect(d['discarded'], isTrue);
    expect(d['revoked_hold'], isTrue,
        reason: 'المستبعدة تبقى معلقة فلا تُرفع أبداً');
    expect(
      RevocationService.instance
          .listUnverifiedOwnershipOps('01')
          .map((e) => e['key']),
      isNot(contains('01_to_discard')),
    );
    expect(
      RevocationService.instance
          .listDiscardedOwnershipOps('01')
          .map((e) => e['key']),
      contains('01_to_discard'),
    );

    // نسب عملية مستبعدة ممنوع حتى استرجاعها
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_to_discard',
        companyCode: '01',
      ),
      isFalse,
    );

    // الاسترجاع يعيدها لقائمة التسوية مجهولة الملكية
    expect(
      await RevocationService.instance.recoverDiscardedPendingOp(
        boxName: 'commercial_pending_box',
        key: '01_to_discard',
      ),
      isTrue,
    );
    final r = commercial.get('01_to_discard') as Map;
    expect(r.containsKey('discarded'), isFalse);
    expect(r['ownership_unverified'], isTrue);
    expect(
      RevocationService.instance
          .listUnverifiedOwnershipOps('01')
          .map((e) => e['key']),
      contains('01_to_discard'),
    );
  });

  test('تخويل النسب: لا نسب بلا مدير ولا بلا حق القسم ولا لقسم مجهول',
      () async {
    RevocationService.debugCurrentUidForTest = 'u1';
    addTearDown(() =>
        RevocationService.debugCurrentUidForTest = null);
    addTearDown(() => PermissionsService()
        .debugSetPermissionsForTest(null, role: 'employee'));
    final commercial = Hive.box('commercial_pending_box');
    final hr = Hive.box('hr_pending_box');
    await commercial.put('01_sale', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '01',
    });
    await commercial.put('01_transfer', {
      'kind': 'transfers',
      'action': 'save',
      'company_code': '01',
    });
    await commercial.put('01_unknown_kind', {
      'kind': 'mystery',
      'action': 'save',
      'company_code': '01',
    });
    await commercial.put('01_bad_action', {
      'kind': 'sales',
      'action': 'teleport',
      'company_code': '01',
    });
    await hr.put('01_E1_2026-11-01', {
      'action': 'save',
      'data': {'employee_code': 'E1'},
      'company_code': '01',
    });

    // 1) غير المدير لا ينسب شيئاً
    PermissionsService().debugSetPermissionsForTest({
      'المبيعات': {'إضافة': true},
    }, role: 'employee', branches: ['all']);
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_sale',
        companyCode: '01',
      ),
      isFalse,
      reason: 'بوابة الخدمة: مدير النظام فقط',
    );

    // 2) مدير بلا حق قسم التحويلات: لا نسب
    PermissionsService().debugSetPermissionsForTest({
      'المبيعات': {'إضافة': true},
      'الموارد البشرية': {'canAddAttendance': true},
    }, role: 'admin', branches: ['all']);
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_transfer',
        companyCode: '01',
      ),
      isFalse,
      reason: 'صلاحية إدارة المستخدمين لا تمنح حق الأقسام',
    );

    // 3) نوع غير مصنف: فشل مغلق، لا ترقية لعمل مجهول
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_unknown_kind',
        companyCode: '01',
      ),
      isFalse,
    );

    // 4) إجراء مجهول: فشل مغلق
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_bad_action',
        companyCode: '01',
      ),
      isFalse,
    );

    // 5) مدير بحق القسم ينسب بنجاح
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_sale',
        companyCode: '01',
      ),
      isTrue,
    );

    // 6) مدير بلا حق الحضور لا ينسب عملية HR
    PermissionsService().debugSetPermissionsForTest({
      'المبيعات': {'إضافة': true},
    }, role: 'admin', branches: ['all']);
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'hr_pending_box',
        key: '01_E1_2026-11-01',
        companyCode: '01',
      ),
      isFalse,
      reason: 'عملية HR تحتاج حق الحضور نفسه',
    );

    // 7) حق الحضور موجود لكن الموظف خارج المرئيين
    PermissionsService().debugSetPermissionsForTest({
      'الموارد البشرية': {'canAddAttendance': true},
    }, role: 'admin', branches: ['all'],
        viewableEmployees: ['E2']);
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'hr_pending_box',
        key: '01_E1_2026-11-01',
        companyCode: '01',
      ),
      isFalse,
      reason: 'الموظف المقيد خارج قائمة المرئيين',
    );

    // 8) الموظف ضمن المرئيين: النسب ينجح
    PermissionsService().debugSetPermissionsForTest({
      'الموارد البشرية': {'canAddAttendance': true},
    }, role: 'admin', branches: ['all'],
        viewableEmployees: ['E1', 'E2']);
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'hr_pending_box',
        key: '01_E1_2026-11-01',
        companyCode: '01',
      ),
      isTrue,
    );

    // 9) الفرع خارج نطاق المدير: لا نسب
    await commercial.put('01_branch9', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '01',
      'data': {'branch_code': '9'},
    });
    PermissionsService().debugSetPermissionsForTest({
      'المبيعات': {'إضافة': true},
    }, role: 'admin', branches: ['1', '2']);
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_branch9',
        companyCode: '01',
      ),
      isFalse,
      reason: 'فرع العملية خارج فروع المدير',
    );

    // 10) الاسترجاع لغير المدير ممنوع
    PermissionsService().debugSetPermissionsForTest(
      null,
      role: 'employee',
      branches: ['all'],
    );
    await commercial.put('01_gone', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '01',
      'discarded': true,
      'revoked_hold': true,
    });
    expect(
      await RevocationService.instance.recoverDiscardedPendingOp(
        boxName: 'commercial_pending_box',
        key: '01_gone',
      ),
      isFalse,
    );

    // 11) الاستبعاد لغير المدير ممنوع (بوابة الخدمة)
    await commercial.put('01_d1', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '01',
    });
    expect(
      await RevocationService.instance.discardUnverifiedPendingOp(
        boxName: 'commercial_pending_box',
        key: '01_d1',
        companyCode: '01',
      ),
      isFalse,
      reason: 'الاستبعاد قرار تسوية لمدير النظام فقط',
    );

    // 12) الاستبعاد لعملية شركة أخرى ممنوع
    PermissionsService().debugSetPermissionsForTest({
      'المبيعات': {'إضافة': true},
    }, role: 'admin', branches: ['all']);
    await commercial.put('02_d1', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '02',
    });
    expect(
      await RevocationService.instance.discardUnverifiedPendingOp(
        boxName: 'commercial_pending_box',
        key: '02_d1',
        companyCode: '01',
      ),
      isFalse,
      reason: 'لا استبعاد عبر حدود الشركة',
    );

    // 13) نسب عملية معلّقة يرفع تعليقها فوراً بعد التحقق
    await commercial.put('01_held', {
      'kind': 'sales',
      'action': 'save',
      'company_code': '01',
      'revoked_hold': true,
      'revoked_hold_section': 'المبيعات',
    });
    expect(
      await RevocationService.instance.assignPendingOpToUser(
        boxName: 'commercial_pending_box',
        key: '01_held',
        companyCode: '01',
      ),
      isTrue,
    );
    final held = commercial.get('01_held') as Map;
    expect(held.containsKey('revoked_hold'), isFalse,
        reason: 'لا انتظار لدورة تشغيل قادمة بعد النسب');
  });
}
