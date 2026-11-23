import 'cache_partitions.dart';
import 'hr_cache_scope.dart';
import 'journal_cache.dart';
import 'notifications_service.dart';
import 'permission_hierarchy.dart';
import 'treasury_cache_scope.dart';
// ============================================================
// RevocationService — دورة حياة سحب الصلاحيات محلياً
//
// العقد (بعد مراجعة V5):
//   1) سحب قسم أو حق: حذف صفوف الكاش النظيفة الخاصة به (scoped
//      delete). لا quarantine خام قابل للقراءة: البيانات
//      المسحوبة لا تبقى على الجهاز.
//   2) العمليات المعلقة (عمل المستخدم غير المرفوع) لا تُحذف
//      أبداً: تُعلَّم revoked_hold + revoked_hold_section في
//      صندوقها الأصلي، فلا تُرفع ولا تُعاد حتى يعود نفس القسم
//      مسموحاً لنفس الحساب.
//   3) عودة السماح: لا استعادة لكاش قديم (stale restore ممنوع)
//      — يُرفع التعليق عن عمليات القسم العائد فقط ويُطلب
//      resync كامل يجلب البيانات بالنطاق الحالي.
//   4) سحب حق حقلي (سعر الشراء/عرض الجملة/مبالغ المرتبات):
//      تُزال الحقول الحساسة من صفوف الكاش مع بقاء الصفوف
//      الصالحة للعمليات المسموحة (كتالوج بلا تكلفة).
//   5) تضييق الفروع/الموظفين المرئيين: حذف الصفوف الخارجة من
//      النطاق وتعليق عملياتها.
//   6) التنفيذ متسلسل (قفل واحد) ويعمل من مساري Firestore
//      والتحميل، وحالة سابقة مجهولة = نطاق مسحوب حتى يثبت
//      العكس، بلا نسبة عمليات قديمة لحساب غير مالكها.
// ============================================================

import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import 'permissions_service.dart';

class RevocationService {
  RevocationService._();
  static final RevocationService instance = RevocationService._();

  Future<void> _chain = Future.value();

  /// تنفيذ متسلسل: لا تتداخل انتقالات متزامنة على نفس المفاتيح.
  Future<T> _serialized<T>(Future<T> Function() work) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await work());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ----------------------------------------------------------
  // خرائط النطاق
  // ----------------------------------------------------------

  /// صناديق كاملة لكل قسم (تُحذف منها مفاتيح الشركة عند السحب).
  static const Map<String, List<String>> _sectionBoxes = {
    'حركة الجرد': ['inventory_box'],
    'حسابات الموردين': ['supplier_box'],
    'تسويات الموردين': ['supplier_settlement_box'],
    'المبيعات': ['sales_box', 'commercial_stock_events_box'],
    'المرتجعات': ['sales_returns_box'],
    'التحويلات المخزنية': ['stock_transfers_box'],
    'حسابات العملاء': ['customer_payments_box'],
    'حركة الخزينة': ['daily_transactions_box'],
    'أرصدة خزائن المبيعات': ['daily_transactions_box'],
  };

  /// صندوقا العمليات المعلقة الوحيدان فعلياً في التطبيق
  /// (تأكدنا: لا طوابير offline في inventory/supplier/settlement
  /// /treasury — الحفظ فيها مباشر للخادم).
  static const String _commercialPending = 'commercial_pending_box';
  static const String _hrPending = 'hr_pending_box';

  /// ربط kind في commercial_pending_box بالقسم المالك له.
  static const Map<String, String> _commercialKindSection = {
    'sales': 'المبيعات',
    'sale_returns': 'المرتجعات',
    'customer_payments': 'حسابات العملاء',
    'transfers': 'التحويلات المخزنية',
  };

  /// حقوق التكلفة الحقلية (سحب أي منها يطهر حقول التكلفة).
  static const Map<String, List<String>> _costRights = {
    'التكويد': ['سعر الشراء'],
    'المبيعات': ['عرض سعر الجملة'],
    'رصيد المخزون': ['عرض سعر الجملة'],
  };

  static const List<String> _costFieldsSnake = [
    'wholesale_price', 'profit_margin', 'profit_percent',
  ];
  static const List<String> _costFieldsCamel = [
    'wholesalePrice', 'wholesaleValue',
  ];

  bool _sectionAllowed(Map<String, dynamic>? perms, String section) {
    if (perms == null) return false;
    final raw = perms[section];
    if (raw is! Map) return false;
    return raw.values.any((v) => v == true);
  }

  bool _hasRight(Map<String, dynamic>? perms, String section, String key) =>
      PermissionHierarchy.allows(perms, section, key);

  // ----------------------------------------------------------
  // أدوات مفاتيح وحذف
  // ----------------------------------------------------------

  Future<int> _deleteCompanyKeys(String boxName, String companyCode,
      {bool Function(String key)? filter}) async {
return CachePartitions.run(() async {

    if (!CachePartitions.isBoxOpen(boxName)) return 0;
    final box = CachePartitions.box(boxName);
    final keys = box.keys
        .map((k) => k.toString())
        .where((k) => boxName == 'daily_transactions_box'
            ? JournalCache.belongsToCompany(k, box.get(k), companyCode)
            : k.startsWith('${companyCode}_'))
        .where((k) => filter == null || filter(k))
        .toList();
    for (final k in keys) {
      await box.delete(k);
    }
    return keys.length;
});
}

  /// حذف الصفوف الخارجة عن نطاق الفروع من القوائم المخزنة.
  Future<void> _filterBoxRowsByBranches(
    String boxName,
    String companyCode,
    Set<String> allowed, {
    Set<String> ownCodes = const {},
  }) async {
return CachePartitions.run(() async {

    if (!CachePartitions.isBoxOpen(boxName)) return;
    final box = CachePartitions.box(boxName);
    for (final key in box.keys.toList()) {
      final keyStr = key.toString();
      final v = box.get(key);
      if (boxName == 'daily_transactions_box') {
        if (!JournalCache.belongsToCompany(key, v, companyCode)) continue;
      } else if (!keyStr.startsWith('${companyCode}_')) {
        continue;
      }
      if (v is List) {
        final kept = v.where((row) {
          if (row is! Map) return true;
          if (boxName == 'coding_box' && HRCacheScope.isHRKey(keyStr, companyCode) &&
              ownCodes.contains((row[keyStr == '${companyCode}_employees' ? 'code' : 'employee_code'] ?? '').toString())) return true;
          final b = row['branch_code']?.toString();
          if (b == null || b.isEmpty) return true;
          return allowed.contains(b);
        }).toList();
        if (kept.length != v.length) {
          if (kept.isEmpty) {
            await box.delete(key);
          } else {
            await box.put(key, kept);
          }
        }
      } else if (v is Map) {
        final b = v['branch_code']?.toString();
        if (b != null && b.isNotEmpty && !allowed.contains(b)) {
          await box.delete(key);
        }
      }
    }
});
}

  /// إزالة حقول من كل صفوف القوائم المخزنة في صندوق.
  Future<void> _stripFieldsInBox(
    String boxName,
    String companyCode,
    List<String> fields,
  ) async {
return CachePartitions.run(() async {

    if (!CachePartitions.isBoxOpen(boxName)) return;
    final box = CachePartitions.box(boxName);
    for (final key in box.keys.toList()) {
      final keyStr = key.toString();
      if (!keyStr.startsWith('${companyCode}_')) continue;
      final v = box.get(key);
      // إزالة متكررة: الحقول الحساسة تُنتزع من كل مستوى متداخل
      // (سطور الجرد، تفاصيل الحضور، أسطر التسويات، تقارير المرتب)
      dynamic stripDeep(dynamic node) {
        if (node is Map) {
          final r = <dynamic, dynamic>{};
          node.forEach((k, v) {
            if (fields.contains(k)) return;
            r[k] = stripDeep(v);
          });
          return r;
        }
        if (node is List) {
          return node.map(stripDeep).toList();
        }
        return node;
      }

  Map stripRow(Map row) => stripDeep(row) as Map;

      if (v is List) {
        var changed = false;
        final out = v.map((row) {
          if (row is! Map) return row;
          final r = stripRow(row);
          if (!const DeepEq().equals(r, row)) changed = true;
          return r;
        }).toList();
        if (changed) await box.put(key, out);
      } else if (v is Map) {
        final r = stripRow(v);
        if (!const DeepEq().equals(r, v)) await box.put(key, r);
      }
    }
});
}

  // ----------------------------------------------------------
  // العمليات المعلقة: تعليق موسوم بالقسم والسبب
  // ----------------------------------------------------------

  /// قسم عمليات لم يُصنَّف بعد: لا يُعلَّق مع أي قسم ولا يُرفع
  /// تعليقه تلقائياً أبداً — لا تفويض ضمني بنوع مجهول.
  static const String unclassifiedSection = 'عمليات غير مصنفة';

  /// حقوق كل قسم تجاري بحسب إجراء العملية (المفاتيح الحقيقية
  /// في نظام الصلاحيات). قسم أو إجراء غير مدرَج هنا = فشل
  /// مغلق عند النسب، لا تفويض ضمني.
  static const Map<String, Map<String, List<String>>>
      _sectionActionRights = {
    'المبيعات': {
      'save': ['إضافة', 'تعديل'],
      'delete': ['حذف'],
    },
    'المرتجعات': {
      'save': ['إضافة', 'تعديل'],
      'delete': ['حذف'],
    },
    'التحويلات المخزنية': {
      'save': ['إضافة', 'تعديل'],
      'delete': ['حذف'],
    },
    'حسابات العملاء': {
      'save': ['إضافة تحصيل', 'تعديل تحصيل'],
      'delete': ['حذف تحصيل'],
    },
  };

  String? _opSection(String boxName, String key, Map op) {
    if (boxName == _hrPending) return 'الموارد البشرية';
    if (boxName == _commercialPending) {
      return _commercialKindSection[op['kind']?.toString()] ??
          unclassifiedSection;
    }
    return null;
  }

  bool _ownedBy(Map op, String? ownerUid) {
    if (ownerUid == null || ownerUid.isEmpty) return true;
    final opUid = op['user_uid']?.toString() ?? '';
    // عملية قديمة بلا مالك: لا تُعلَّق ولا تُرفع تلقائياً —
    // تُترك لمسار التسوية (ownership_unverified عند الرفع)
    if (opUid.isEmpty) return false;
    return opUid == ownerUid;
  }

  /// تعليق عمليات قسم معين فقط (لا أقسام أخرى في نفس الصندوق،
  /// ولا عمليات مستخدم آخر).
  Future<void> _holdOps(
    String companyCode,
    String section, {
    bool Function(String key, Map op)? filter,
    String? ownerUid,
  }) async {
return CachePartitions.run(() async {

    for (final boxName in [_commercialPending, _hrPending]) {
      if (!CachePartitions.isBoxOpen(boxName)) continue;
      final box = CachePartitions.box(boxName);
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        final op = Map<dynamic, dynamic>.from(raw);
        if (_opSection(boxName, key.toString(), op) != section) {
          continue;
        }
        final opCompany = op['company_code']?.toString();
        if (opCompany != null && opCompany != companyCode) continue;
        if (opCompany == null &&
            !key.toString().startsWith('${companyCode}_')) {
          continue;
        }
        if (!_ownedBy(op, ownerUid)) continue;
        if (filter != null && !filter(key.toString(), op)) continue;
        if (op['revoked_hold'] == true &&
            op['revoked_hold_section'] == section) {
          continue;
        }
        op['revoked_hold'] = true;
        op['revoked_hold_section'] = section;
        op['hold_reason'] = 'صلاحية القسم مسحوبة حالياً';
        await box.put(key, op);
      }
    }
});
}

  /// رفع التعليق فقط عن عمليات قسم عاد مسموحاً فعلاً،
  /// وفقط عمليات المستخدم الحالي، وبعد تحقق باقي النطاقات:
  /// فرع العملية داخل الفروع المسموحة (لو تقيّدت)، وموظف
  /// عمليات HR داخل قائمة المرئيين (لو تقيّدت).
  Future<void> _unholdOps(
    String companyCode,
    String section, {
    bool Function(String key, Map op)? filter,
    String? ownerUid,
    List<String>? allowedBranches,
    List<String>? viewableEmployees,
  }) async {
return CachePartitions.run(() async {

    Set<String>? branchSet;
    if (allowedBranches != null &&
        !allowedBranches.contains('all') &&
        allowedBranches.isNotEmpty) {
      branchSet = allowedBranches.toSet();
    }
    final viewableSet = viewableEmployees?.toSet();
    for (final boxName in [_commercialPending, _hrPending]) {
      if (!CachePartitions.isBoxOpen(boxName)) continue;
      final box = CachePartitions.box(boxName);
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        final op = Map<dynamic, dynamic>.from(raw);
        // لا يُرفع التعليق إلا عن عمليات معلقة بسبب هذا القسم
        if (op['revoked_hold'] != true) continue;
        if (op['revoked_hold_section'] != section) continue;
        final opCompany = op['company_code']?.toString();
        if (opCompany != null && opCompany != companyCode) continue;
        if (opCompany == null &&
            !key.toString().startsWith('${companyCode}_')) {
          continue;
        }
        if (!_ownedBy(op, ownerUid)) continue;
        if (filter != null && !filter(key.toString(), op)) continue;
        // تحقق الفروع: عملية فرع خارج النطاق تبقى معلقة
        if (branchSet != null) {
          final d = op['data'];
          final b = d is Map ? d['branch_code']?.toString() : null;
          if (b != null && b.isNotEmpty && !branchSet.contains(b)) {
            continue;
          }
        }
        // تحقق المرئيين لعمليات HR المفتاحية بالموظف
        if (viewableSet != null && boxName == _hrPending) {
          final emp =
              _hrEmployeeCodeFromKey(key.toString(), companyCode);
          if (emp != null && !viewableSet.contains(emp)) continue;
        }
        op.remove('revoked_hold');
        op.remove('revoked_hold_section');
        op.remove('hold_reason');
        await box.put(key, op);
      }
    }
});
}

  /// مفتاح HR: company_employeeCode_date — الكود قد يحوي '_'
  /// فيُستخرج بإزالة البادئة ثم آخر مقطع (التاريخ).
  String? _hrEmployeeCodeFromKey(String key, String companyCode) {
    final prefix = '${companyCode}_';
    if (!key.startsWith(prefix)) return null;
    final rest = key.substring(prefix.length);
    final idx = rest.lastIndexOf('_');
    if (idx <= 0) return null;
    return rest.substring(0, idx);
  }

  // ----------------------------------------------------------
  // النقطة الرئيسية
  // ----------------------------------------------------------

  /// يرجع true لو حدث تغيير نطاق يستدعي resync كامل.
  Future<bool> applyTransition({
    required String email,
    required String companyCode,
    required Map<String, dynamic>? oldPerms,
    required Map<String, dynamic>? newPerms,
    List<String>? oldBranches,
    List<String>? newBranches,
    List<String>? oldViewable,
    List<String>? newViewable,
    String? ownerUid,
  }) {
    return _serialized(() => _applyTransition(
          email: email,
          companyCode: companyCode,
          oldPerms: oldPerms,
          newPerms: newPerms,
          oldBranches: oldBranches,
          newBranches: newBranches,
          oldViewable: oldViewable,
          newViewable: newViewable,
          ownerUid: ownerUid,
        ));
  }

  Future<bool> _applyTransition({
    required String email,
    required String companyCode,
    required Map<String, dynamic>? oldPerms,
    required Map<String, dynamic>? newPerms,
    List<String>? oldBranches,
    List<String>? newBranches,
    List<String>? oldViewable,
    List<String>? newViewable,
    String? ownerUid,
  }) async {
return CachePartitions.run(() async {

    var needsResync = false;
    String verifiedEmail = '';
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (ownerUid != null && user?.uid != ownerUid) return false;
      if (user?.uid == ownerUid) verifiedEmail = user?.email ?? '';
    } catch (_) { /* No authenticated email fallback is assumed. */ }
    final ownCodes = HRCacheScope.ownCodes(company: companyCode, uid: ownerUid,
        verifiedEmail: verifiedEmail, permissions: newPerms);
    final hrScopeChanged = !const DeepEq().equals(oldPerms?['الموارد البشرية'], newPerms?['الموارد البشرية']) ||
        !const DeepEq().equals(oldBranches, newBranches) ||
        !const DeepEq().equals(oldViewable, newViewable);
    final notificationScopeChanged = !const DeepEq().equals(oldPerms, newPerms) ||
        !const DeepEq().equals(oldBranches, newBranches) ||
        !const DeepEq().equals(oldViewable, newViewable);
    await NotificationsService.instance.purgeInaccessibleCache(
      companyCode: companyCode,
      ownerUid: ownerUid,
      scopeChanged: notificationScopeChanged,
    );
    // حالة سابقة مجهولة (تثبيت جديد/بقايا حساب سابق):
    // نتعامل كأن كل شيء كان مسموحاً فننظف ما لم يعد مسموحاً.
    final prevKnown = oldPerms != null;
    final newKnown = newPerms != null;

    if (await TreasuryCacheScope.apply(company: companyCode, ownerUid: ownerUid,
        permissions: newPerms, branches: newBranches)) needsResync = true;
    if (_hasRight(oldPerms, 'تحويلات الخزائن', 'معاينة') != _hasRight(newPerms, 'تحويلات الخزائن', 'معاينة') ||
        TreasuryCacheScope.hasEffects(oldPerms) != TreasuryCacheScope.hasEffects(newPerms)) needsResync = true;

    final sections = <String>{
      ..._sectionBoxes.keys,
      'التكويد',
      'الموارد البشرية',
    };

    for (final section in sections) {
      final was = !prevKnown || _sectionAllowed(oldPerms, section);
      final now = newKnown && _sectionAllowed(newPerms, section);
      if (was && !now) {
        await _purgeSection(email, companyCode, section, ownerUid: ownerUid);
        needsResync = true;
      } else if (!was && now) {
        // لا استعادة لكاش قديم: رفع تعليق عمليات القسم فقط بعد
        // تحقق الفروع/المرئيين، والبيانات يجلبها الـ resync.
        await _unholdOps(
          companyCode,
          section,
          ownerUid: ownerUid,
          allowedBranches: newBranches,
          viewableEmployees: newViewable,
        );
        needsResync = true;
      }
    }

    // حقول التكلفة: سحب الحق الحقلي يطهر الحقول من الكاش
    if (prevKnown && newKnown) {
      final hadCost = _costRights.entries.any(
        (e) => e.value.any((k) => _hasRight(oldPerms, e.key, k)),
      );
      if (hadCost && !_costRightNowWith(newPerms)) {
        await _purgeCostFields(companyCode);
        needsResync = true;
      }
      // مبالغ المرتبات
      final hadSalary =
          _hasRight(oldPerms, 'الموارد البشرية', 'canViewSalaryAmounts');
      final hasSalary =
          _hasRight(newPerms, 'الموارد البشرية', 'canViewSalaryAmounts');
      if (hadSalary && !hasSalary) {
        needsResync = true;
      }
    } else if (!prevKnown && newKnown) {
      if (!_costRightNowWith(newPerms)) {
        await _purgeCostFields(companyCode);
      }
    }

    // تضييق الفروع: حذف الصفوف الخارجة + تعليق عملياتها
    if (_branchScopeNarrowed(oldBranches, newBranches)) {
      final allowed = (newBranches ?? const [])
          .where((b) => b != 'all')
          .toSet();
      for (final boxName in const [
        'inventory_box',
        'supplier_box',
        'supplier_settlement_box',
        'daily_transactions_box',
        'sales_box',
        'sales_returns_box',
        'stock_transfers_box',
        'customer_payments_box',
        'commercial_stock_events_box',
        'coding_box',
      ]) {
        await _filterBoxRowsByBranches(boxName, companyCode, allowed, ownCodes: ownCodes);
      }
      // تعليق عمليات commercial خارج النطاق (لا حذف)
      await _holdCommercialOpsOutOfBranches(companyCode, allowed);
      needsResync = true;
    }

    // تضييق الموظفين المرئيين: تعليم pending الخارجين، وحذف
    // بياناتهم المخزنة؛ والعائدون للنطاق يُرفع تعليقهم
    if (newViewable != null && newViewable.isNotEmpty &&
        (oldViewable == null || !_listEq(oldViewable, newViewable))) {
      final allowed = newViewable.toSet();
      await _unholdOps(
        companyCode,
        'الموارد البشرية',
        filter: (key, op) {
          final emp = _hrEmployeeCodeFromKey(key, companyCode);
          return emp != null && allowed.contains(emp);
        },
        ownerUid: ownerUid,
      );
      await _holdOps(
        companyCode,
        'الموارد البشرية',
        filter: (key, op) {
          final emp = _hrEmployeeCodeFromKey(key, companyCode);
          return emp != null && !allowed.contains(emp);
        },
        ownerUid: ownerUid,
      );
      // حذف الصفوف المخزنة للموظفين الخارجين من النطاق
      // (قوائم HR تحمل employee_code في كل سطر)
      if (CachePartitions.isBoxOpen('coding_box')) {
        final box = CachePartitions.box('coding_box');
        for (final key in box.keys.toList()) {
          final keyStr = key.toString();
          if (!HRCacheScope.isHRKey(keyStr, companyCode)) continue;
          final v = box.get(key);
          if (v is! List) continue;
          // إغلاق عند المجهول: سطر بلا employee_code لا يمكن
          // إثبات انتمائه لمرئي — يُحذف مع الخارجين عن النطاق
          final kept = v.where((row) {
            if (row is! Map) return true;
            final ec = row[keyStr == '${companyCode}_employees' ? 'code' : 'employee_code']?.toString();
            if (ec == null || ec.isEmpty) return false;
            return allowed.contains(ec) || ownCodes.contains(ec);
          }).toList();
          if (kept.length != v.length) {
            if (kept.isEmpty) {
              await box.delete(key);
            } else {
              await box.put(key, kept);
            }
          }
        }
      }
      needsResync = true;
    }

    // تسوية عند بدء التشغيل/الدخول: أي عملية معلقة بقسم مسموح
    // حالياً يُرفع تعليقها (للمالك فقط) حتى لا تعلق للأبد
    if (newKnown && ownerUid != null) {
      for (final section in sections) {
        if (_sectionAllowed(newPerms, section)) {
          await _unholdOps(
            companyCode,
            section,
            ownerUid: ownerUid,
            allowedBranches: newBranches,
            viewableEmployees: newViewable,
          );
        }
      }
    }

    if (await HRCacheScope.apply(company: companyCode, uid: ownerUid,
        verifiedEmail: verifiedEmail, permissions: newPerms, branches: newBranches,
        viewable: newViewable, invalidateTotals: hrScopeChanged, compact: hrScopeChanged)) needsResync = true;
    return needsResync;
});
}

  bool _costRightNowWith(Map<String, dynamic>? perms) =>
      perms != null &&
      _costRights.entries.any(
        (e) => e.value.any((k) => _hasRight(perms, e.key, k)),
      );

  Future<void> _purgeSection(
    String email,
    String companyCode,
    String section, {
    String? ownerUid,
  }) async {
return CachePartitions.run(() async {

    for (final boxName in _sectionBoxes[section] ?? const []) {
      await _deleteCompanyKeys(boxName, companyCode);
    }
    if (section == 'التكويد') {
      // نحذف مفاتيح بيانات التكويد فقط — لا مفاتيح HR ولا
      // الصلاحيات. الكتالوج بلا تكلفة يُعاد جلبه عند resync
      // لو قسماً مستهلكاً ما زال مسموحاً.
      await _deleteCompanyKeys('coding_box', companyCode,
          filter: (k) => !k.startsWith('${companyCode}_hr'));
    }
    if (section == 'الموارد البشرية') {
      await _deleteCompanyKeys('coding_box', companyCode,
          filter: (k) =>
              k.startsWith('${companyCode}_hr') ||
              k == '${companyCode}_employees');
    }
    await _holdOps(companyCode, section, ownerUid: ownerUid);
});
}

  Future<void> _purgeCostFields(String companyCode) async {
return CachePartitions.run(() async {

    // الكتالوج المخزن قد يحمل الحقول بالصيغتين
    await _stripFieldsInBox('coding_box', companyCode,
        [..._costFieldsSnake, ..._costFieldsCamel]);
    await _stripFieldsInBox('inventory_box', companyCode,
        [..._costFieldsCamel, 'total_wholesale']);
    // فواتير الموردين المخزنة قبل سحب الحق: تُنتزع منها الأسعار
    // والإجماليات المشتقة (بنداً وفاتورة). القيم الصحيحة على
    // الخادم لا تتأثر، وإعادة منح الحق تعيد جلبها بمزامنة كاملة.
    await _stripFieldsInBox('supplier_box', companyCode, const [
      'price', 'total', 'discountAmount', 'discountRate',
      'total_amount', 'totalAmount',
    ]);
});
}

  Future<void> _holdCommercialOpsOutOfBranches(
    String companyCode,
    Set<String> allowed,
  ) async {
return CachePartitions.run(() async {

    if (!CachePartitions.isBoxOpen(_commercialPending)) return;
    final box = CachePartitions.box(_commercialPending);
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! Map) continue;
      final op = Map<dynamic, dynamic>.from(raw);
      if (op['company_code']?.toString() != companyCode) continue;
      final data = op['data'];
      final b = data is Map ? data['branch_code']?.toString() : null;
      if (b == null || b.isEmpty || allowed.contains(b)) continue;
      if (op['revoked_hold'] == true &&
          op['revoked_hold_section'] == 'نطاق الفروع') {
        continue;
      }
      op['revoked_hold'] = true;
      op['revoked_hold_section'] = 'نطاق الفروع';
      op['hold_reason'] = 'فرع العملية خارج النطاق الحالي';
      await box.put(key, op);
    }
});
}

  bool _branchScopeNarrowed(List<String>? oldB, List<String>? newB) {
    if (newB == null) return false;
    final oldSet = (oldB ?? const ['all']).toSet();
    final newSet = newB.toSet();
    final oldAll = oldSet.isEmpty || oldSet.contains('all');
    final newAll = newSet.isEmpty || newSet.contains('all');
    if (newAll) return false;
    if (oldAll) return true;
    return oldSet.difference(newSet).isNotEmpty ||
        oldSet.length != newSet.length;
  }

  bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final sa = a.toSet();
    for (final x in b) {
      if (!sa.contains(x)) return false;
    }
    return true;
  }

  // ----------------------------------------------------------
  // مسار تسوية مرئي للعمليات مجهولة المالك
  //
  // عملية قديمة بلا user_uid لا تُرفع ولا تُحذف ولا تُنسب
  // تلقائياً. تظهر هنا ليتخذ مدير النظام قراراً صريحاً لكل
  // عملية: نسبها لحسابه (فيُعاد تقييمها بنطاقه) أو حذفها.
  // ----------------------------------------------------------

  bool _opMatchesCompany(
    Map<dynamic, dynamic> raw,
    String keyStr,
    String companyCode,
  ) {
    final opCompany = raw['company_code']?.toString();
    if (opCompany != null && opCompany.isNotEmpty) {
      return opCompany == companyCode;
    }
    return keyStr.startsWith('${companyCode}_');
  }

  /// كل العمليات مجهولة الملكية للشركة الحالية (من الصندوقين).
  /// المستبعدة (discarded) لا تظهر هنا — لها قائمة استرجاع خاصة.
  List<Map<String, dynamic>> listUnverifiedOwnershipOps(
    String companyCode,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final boxName in [_commercialPending, _hrPending]) {
      if (!CachePartitions.isBoxOpen(boxName)) continue;
      final box = CachePartitions.box(boxName);
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        if (raw['discarded'] == true) continue;
        final opUid = raw['user_uid']?.toString() ?? '';
        if (opUid.isNotEmpty) continue;
        final keyStr = key.toString();
        if (!_opMatchesCompany(raw, keyStr, companyCode)) continue;
        out.add(_opSummary(boxName, keyStr, raw));
      }
    }
    return out;
  }

  /// العمليات المستبعدة (قابلة للاسترجاع) للشركة الحالية.
  List<Map<String, dynamic>> listDiscardedOwnershipOps(
    String companyCode,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final boxName in [_commercialPending, _hrPending]) {
      if (!CachePartitions.isBoxOpen(boxName)) continue;
      final box = CachePartitions.box(boxName);
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        if (raw['discarded'] != true) continue;
        final keyStr = key.toString();
        if (!_opMatchesCompany(raw, keyStr, companyCode)) continue;
        final summary = _opSummary(boxName, keyStr, raw);
        summary['discarded_by'] =
            raw['discarded_by']?.toString() ?? '';
        summary['discarded_at'] =
            raw['discarded_at']?.toString() ?? '';
        out.add(summary);
      }
    }
    return out;
  }

  Map<String, dynamic> _opSummary(
    String boxName,
    String keyStr,
    Map<dynamic, dynamic> raw,
  ) {
    final data = raw['data'];
    final dataMap = data is Map ? data : const {};
    return {
      'box': boxName,
      'key': keyStr,
      'section': _opSection(boxName, keyStr, raw),
      'kind': raw['kind']?.toString() ?? '',
      'action': raw['action']?.toString() ?? '',
      'held': raw['revoked_hold'] == true,
      'company_code': raw['company_code']?.toString() ?? '',
      'branch_code':
          (raw['branch_code'] ?? dataMap['branch_code'])
                  ?.toString() ??
              '',
      'date': (raw['date'] ?? dataMap['date'])?.toString() ?? '',
      'endpoint': raw['endpoint']?.toString() ?? '',
    };
  }

  /// نسب عملية مجهولة للحساب الحالي فقط، بقرار صريح من مدير
  /// النظام (البوابة في الصفحة). لا يقبل معرّف حساب خارجياً
  /// أبداً — الهوية تُقرأ من جلسة الدخول نفسها — ويتحقق أن
  /// العملية تخص الشركة الحالية وليست مملوكة لأحد ولا
  /// مستبعدة. يُسجَّل من نسب ومتى لأغراض التدقيق.
  /// هوية الجلسة الحالية — في الاختبارات تُضبط عبر
  /// [debugCurrentUidForTest] لأن FirebaseAuth غير مهيأ.
  static String? debugCurrentUidForTest;

  String get _sessionUid {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null && uid.isNotEmpty) return uid;
    } catch (_) {
      // Firebase غير مهيأ هنا (بيئة الاختبارات)
    }
    return debugCurrentUidForTest ?? '';
  }

  Future<bool> assignPendingOpToUser({
    required String boxName,
    required String key,
    required String companyCode,
  }) async {
return CachePartitions.run(() async {

    final uid = _sessionUid;
    if (uid.isEmpty) return false;
    if (!CachePartitions.isBoxOpen(boxName)) return false;
    final box = CachePartitions.box(boxName);
    final raw = box.get(key);
    if (raw is! Map) return false;
    final opUid = raw['user_uid']?.toString() ?? '';
    if (opUid.isNotEmpty) return false;
    if (raw['discarded'] == true) return false;
    if (!_opMatchesCompany(raw, key, companyCode)) return false;

    // ----------------------------------------------------------
    // تخويل النسب على مستوى الخدمة (الصفحة بوابة عرض فقط):
    // ----------------------------------------------------------

    final perms = PermissionsService();

    // 1) مدير النظام فقط يتخذ قرار التسوية
    if (!perms.canManageUsers) return false;

    // 2) قسم العملية: قسم غير مصنف لا يُنسب أبداً —
    // لا ترقية لعمل مجهول النوع لتجاوز النطاق الحالي.
    final section = _opSection(boxName, key, raw);
    if (section == null || section == unclassifiedSection) {
      return false;
    }

    // 3) حق القسم نفسه بحسب الإجراء: صلاحية إدارة المستخدمين
    // لا تمنح حقوق الأقسام. الإجراء المجهول يفشل مغلقاً.
    final action = raw['action']?.toString() ?? '';
    if (boxName == _hrPending) {
      final hasSectionRight = switch (action) {
        'save' =>
          perms.canAddAttendance || perms.canEditAttendance,
        'delete' => perms.canDeleteAttendance,
        _ => false,
      };
      if (!hasSectionRight) return false;

      // 4) الموظف المقيد ضمن الموظفين المرئيين للمدير فقط
      final viewable = perms.hrViewableEmployees;
      if (viewable != null) {
        final emp = _hrEmployeeCodeFromKey(key, companyCode);
        if (emp != null && !viewable.contains(emp)) return false;
      }
    } else {
      final rights = _sectionActionRights[section]?[action];
      if (rights == null) return false; // قسم/إجراء مجهول
      final hasSectionRight =
          rights.any((r) => perms.hasPermission(section, r));
      if (!hasSectionRight) return false;
    }

    // 5) الفرع: عملية فرع خارج نطاق فروع المدير لا تُنسب
    final opData = raw['data'];
    final opBranch = (opData is Map
            ? opData['branch_code']
            : raw['branch_code'])
        ?.toString();
    if (opBranch != null &&
        opBranch.isNotEmpty &&
        !perms.canAccessBranch(opBranch)) {
      return false;
    }
    final op = Map<dynamic, dynamic>.from(raw);
    op['user_uid'] = uid;
    op['assigned_by'] = uid;
    op['assigned_at'] = DateTime.now().toIso8601String();
    op.remove('ownership_unverified');
    // التحقق أعلاه أعاد تقييم القسم/الفرع/المرئيين لحظة النسب،
    // فالتعليق يُرفع فوراً — لا انتظار لدورة تشغيل قادمة.
    op.remove('revoked_hold');
    op.remove('revoked_hold_section');
    op.remove('hold_reason');
    await box.put(key, op);
    print(
      '[ownership] assigned box=$boxName key=$key '
      'by=$uid at=${op['assigned_at']}',
    );
    return true;
});
}

  /// استبعاد عملية مجهولة بقرار صريح: علامة discarded تجعلها
  /// خارج القوائم وخارج الرفع، لكنها تبقى محفوظة وقابلة
  /// للاسترجاع — لا حذف فعلياً لبيانات معلقة أبداً.
  Future<bool> discardUnverifiedPendingOp({
    required String boxName,
    required String key,
    required String companyCode,
  }) async {
return CachePartitions.run(() async {

    // بوابة الخدمة: الاستبعاد قرار تسوية — مدير النظام فقط،
    // ولعمليات شركته الحالية فقط (نفس ضمانات النسب).
    if (!PermissionsService().canManageUsers) return false;
    if (!CachePartitions.isBoxOpen(boxName)) return false;
    final box = CachePartitions.box(boxName);
    final raw = box.get(key);
    if (raw is! Map) return false;
    final opUid = raw['user_uid']?.toString() ?? '';
    if (opUid.isNotEmpty) return false;
    if (raw['discarded'] == true) return false;
    if (!_opMatchesCompany(raw, key, companyCode)) return false;
    final op = Map<dynamic, dynamic>.from(raw);
    op['discarded'] = true;
    op['discarded_by'] = _sessionUid;
    op['discarded_at'] = DateTime.now().toIso8601String();
    // تبقى معلّقة كي لا تُرفع أبداً وهي مستبعدة
    op['revoked_hold'] = true;
    op['revoked_hold_section'] ??= 'ownership_discarded';
    await box.put(key, op);
    print(
      '[ownership] discarded box=$boxName key=$key '
      'by=${op['discarded_by']} at=${op['discarded_at']}',
    );
    return true;
});
}

  /// استرجاع عملية مستبعدة إلى قائمة التسوية (تبقى مجهولة
  /// الملكية ومعلّقة إلى أن يتخذ المدير قراراً جديداً).
  Future<bool> recoverDiscardedPendingOp({
    required String boxName,
    required String key,
  }) async {
return CachePartitions.run(() async {

    // الاسترجاع قرار تسوية: مدير النظام فقط. العملية المسترجعة
    // تعود مجهولة الملكية ومعلّقة، فلا مسار للرفع من هنا.
    if (!PermissionsService().canManageUsers) return false;
    if (!CachePartitions.isBoxOpen(boxName)) return false;
    final box = CachePartitions.box(boxName);
    final raw = box.get(key);
    if (raw is! Map) return false;
    if (raw['discarded'] != true) return false;
    final op = Map<dynamic, dynamic>.from(raw);
    op.remove('discarded');
    op.remove('discarded_by');
    op.remove('discarded_at');
    if (op['revoked_hold_section'] == 'ownership_discarded') {
      op.remove('revoked_hold');
      op.remove('revoked_hold_section');
    }
    op['ownership_unverified'] = true;
    await box.put(key, op);
    print(
      '[ownership] recovered box=$boxName key=$key '
      'by=$_sessionUid',
    );
    return true;
});
}
}

/// مقارنة بسيطة للخرائط/القوائم المتداخلة بدون حزمة خارجية.
class DeepEq {
  const DeepEq();
  bool equals(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !equals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!equals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
