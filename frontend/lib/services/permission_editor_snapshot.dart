// frontend/lib/services/permission_editor_snapshot.dart
import 'page_visibility.dart';
import 'company_permission_policy.dart';
import 'branch_scope.dart';
import 'read_authorization_snapshot.dart';

// لقطة محرر الصلاحيات: قراءة واحدة حالية من الخادم
/// One current server read. Neither cached job codes nor operating access
/// can supply delegation or a write version.
class PermissionEditorSnapshot {
  PermissionEditorSnapshot._(this.data, [this.readScope]);
  final Map<String, dynamic> data;
  final ReadAuthorizationSnapshot? readScope;

  // ينشئ نسخة من اللقطة مرتبطة بنطاق القراءة
  PermissionEditorSnapshot withReadScope(ReadAuthorizationSnapshot scope) {
    scope.check();
    if (readScope != null && !identical(readScope, scope)) {
      throw StateError(
          'An editor read cannot be rebound to a later authorization scope');
    }
    return PermissionEditorSnapshot._(data, scope);
  }

  // ينشئ كائنًا من بيانات JSON
  factory PermissionEditorSnapshot.fromJson(Map<String, dynamic> value) {
    if (value['email'] is! String ||
        value['uid'] is! String ||
        value['profile_version'] is! String ||
        value['company_policy_active'] is! bool) {
      throw const FormatException('تعذر التحقق من بيانات محرر الصلاحيات');
    }
    CompanyPermissionPolicy.validateMap(value['permissions']);
    if (value['company_policy_active'] == true) {
      if (value['company_policy_revision'] is! int ||
          (value['company_policy_revision'] as int) < 1 ||
          (value['profile_version'] as String).isEmpty ||
          (value['uid'] as String).isEmpty) {
        throw const FormatException('تعذر التحقق من إصدار الصلاحيات');
      }
      CompanyPermissionPolicy.validateMap(value['company_permissions']);
      CompanyPermissionPolicy.validateMap(value['delegable_permissions']);
      BranchScope.validate(value['delegable_branches']);
    }
    return PermissionEditorSnapshot._(Map<String, dynamic>.from(value));
  }

  // يعيد بريد المستخدم
  String get email => data['email'];

  // يعيد معرّف المستخدم
  String get uid => data['uid'];

  // يعيد إصدار الملف
  String get version => data['profile_version'];

  // يعيد رقم مراجعة سياسة الشركة
  int? get revision => data['company_policy_revision'];

  // يحدد هل سياسة الشركة مفعّلة
  bool get active => data['company_policy_active'] == true;

  // يحدد هل المستخدم مدير المنصة
  bool get root => data['platform_admin'] == true;

  // يعيد خريطة الصلاحيات الحالية
  Map<String, Map<String, bool>> get permissions => (data['permissions'] as Map)
      .map((k, v) => MapEntry(k.toString(), Map<String, bool>.from(v)));

  // يعيد الصلاحيات القابلة للتفويض
  Set<PermissionRight> get delegated =>
      CompanyPermissionPolicy.grants(data['delegable_permissions']);

  // يعيد الفروع القابلة للتفويض
  List<String> get branchDelegation =>
      List<String>.from(data['delegable_branches'] ?? []);

  // يعيد الفروع المسموح بها للمستخدم
  List<String> get branches {
    final raw = data['allowed_branches'];
    if (raw is List && raw.every((v) => v is String)) {
      if (raw.isEmpty && !active) return ['all'];
      return List<String>.from(raw);
    }
    if (raw == 'all' || (!active && raw == null)) return ['all'];
    return [];
  }

  // يعيد الموظفين الذين يحق عرضهم
  List<String>? get employees => data['hr_viewable_employees'] is List
      ? List<String>.from(data['hr_viewable_employees'])
      : null;

  // يعيد فرع البدء الافتراضي
  String get startup => (data['startup_branch_code'] ?? '').toString();

  // يعيد خيارات الحقل المحدد
  List<Map<String, String>> choices(String field) =>
      (data[field] as List? ?? [])
          .map((v) => Map<String, String>.from(v))
          .toList();

  // يحدد هل النطاق ضمن الفروع المفوضة
  bool _inside(List<String> scope) =>
      branchDelegation.contains('all') ||
      (scope.isNotEmpty &&
          !scope.contains('all') &&
          scope.every(branchDelegation.contains));

  // يحدد هل الصلاحية مقيدة بالنطاق
  bool _scoped(PermissionRight right) =>
      right.category != 'صلاحيات عامة' &&
      right != (category: 'الموارد البشرية', key: 'canViewOwnHRData');

  // يعيد الصلاحيات المعروضة للمحرر
  Set<PermissionRight> _exposed(dynamic current) =>
      CompanyPermissionPolicy.grants(
              CompanyPermissionPolicy.effectivePermissions(
                  data['company_permissions'], permissions))
          .union(CompanyPermissionPolicy.grants(current))
          .where(_scoped)
          .toSet();

  // يحدد هل يمكن تبديل الصلاحية للقيمة الجديدة
  bool canToggle(String category, String key, bool next, dynamic current,
      List<String> draftBranches) {
    if (!active) return true;
    final changed = {
      for (final e in (current as Map).entries)
        e.key: Map<String, bool>.from(e.value)
    };
    (changed[category] ??= {})[key] = next;
    final before = CompanyPermissionPolicy.grants(current),
        after = CompanyPermissionPolicy.grants(changed);
    final delta = before.difference(after).union(after.difference(before));
    if (category == 'صلاحيات عامة' &&
        PageVisibility.keys.contains(key) &&
        (current[category] is Map ? current[category][key] : null) != next) {
      delta.add((category: category, key: key));
    }
    if (next &&
        !(root && data['role'] == 'super_admin') &&
        !after.difference(before).every(
            CompanyPermissionPolicy.grants(data['company_permissions'])
                .contains)) return false;
    if (root) return true;
    return delta.every(delegated.contains) &&
        (!delta.any(_scoped) || (_inside(branches) && _inside(draftBranches)));
  }

  // يحدد هل يمكن تعديل الفرع
  bool canEditBranch(String code, dynamic current) {
    if (!active || root) return true;
    return (branchDelegation.contains('all') ||
            branchDelegation.contains(code)) &&
        _exposed(current).every(delegated.contains);
  }

  // يحدد هل يمكن تعديل الموظفين المسموح بهم
  bool canEditEmployees(dynamic current, List<String> draftBranches) =>
      !active ||
      root ||
      (_inside(branches) &&
          _inside(draftBranches) &&
          _exposed(current)
              .where((r) => r.category == 'الموارد البشرية')
              .every(delegated.contains));

  // يقارن مجموعتين من النصوص
  static bool sameSet(Iterable<String>? a, Iterable<String>? b) {
    final x = (a ?? []).toSet(), y = (b ?? []).toSet();
    return x.length == y.length && x.containsAll(y);
  }

  // يحدد هل اللقطة تطابق المصدر المعطى
  bool matchesSource(Map<String, dynamic> source) {
    try {
      CompanyPermissionPolicy.validateMap(source['permissions']);
    } catch (_) {
      return false;
    }
    if (source['allowed_branches'] is List &&
        (source['allowed_branches'] as List).any((v) => v is! String))
      return false;
    if (source['hr_viewable_employees'] is List &&
        (source['hr_viewable_employees'] as List).any((v) => v is! String))
      return false;
    final a = CompanyPermissionPolicy.grants(source['permissions']);
    final b = CompanyPermissionPolicy.grants(
        data['source_permissions'] ?? permissions);
    final raw = source['allowed_branches'];
    final sourceBranches = raw is List
        ? (raw.isEmpty && !active ? ['all'] : raw.whereType<String>().toList())
        : (raw == 'all' || (!active && raw == null) ? ['all'] : <String>[]);
    final rawEmployees = source['hr_viewable_employees'];
    final sourceEmployees =
        rawEmployees is List ? rawEmployees.whereType<String>().toList() : null;
    dynamic updated = source['updated_at'];
    if (updated != null && updated is! String) {
      try {
        updated = updated.toDate().toUtc().toIso8601String();
      } catch (_) {
        updated = null;
      }
    }
    final oldTime = DateTime.tryParse(data['source_updated_at'] ?? '');
    final newTime = DateTime.tryParse(updated ?? '');
    return source['uid'] == uid &&
        source['company_code'] == data['company_code'] &&
        source['role'] == data['source_role'] &&
        source['job_code'] == data['source_job_code'] &&
        source['status'] == data['source_status'] &&
        (source['is_active'] != false) == (data['is_active'] != false) &&
        (source['branch_code'] ?? '').toString() == startup &&
        a.length == b.length &&
        a.containsAll(b) &&
        sameSet(sourceBranches, branches) &&
        sameSet(sourceEmployees, employees) &&
        oldTime == newTime;
  }
}

// دليل أهداف الصلاحيات المرتبط بالنطاق المحدد
/// A minimal selector result bound to the exact read that fetched it.
class PermissionTargetDirectory {
  PermissionTargetDirectory(this.companyCode, this.users, this.readScope);
  final String companyCode;
  final List<Map<String, dynamic>> users;
  final ReadAuthorizationSnapshot readScope;
}
