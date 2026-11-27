// frontend/lib/services/effective_profile_snapshot.dart
import 'dart:convert';
import 'company_permission_policy.dart';
import 'branch_scope.dart';

// لقطة الملف الفعلي لحساب وشركة محددين
/// An effective scope returned for one authenticated account and company.
class EffectiveProfileSnapshot {
  EffectiveProfileSnapshot._(this.data);
  final Map<String, dynamic> data;

  // يحسب مفتاح تخزين اللقطة
  static String cacheKey(String uid, String company) =>
      'effective_profile_${jsonEncode([uid, company])}';

  // يحسب مفتاح التحقق المعلق
  static String pendingKey(String uid, String company) =>
      '${cacheKey(uid, company)}_verification';

  // يحدد هل سياسة الشركة مفعّلة
  bool get active => data['company_policy_active'] == true;

  // يعيد خريطة الصلاحيات
  Map<String, dynamic> get permissions =>
      Map<String, dynamic>.from(data['permissions']);

  // يعيد دور المستخدم
  String get role => data['role'] as String;

  // يحلل استجابة الخادم إلى لقطة
  static EffectiveProfileSnapshot parse(
    dynamic raw, {
    required String uid,
    required String email,
    required String company,
  }) {
    if (raw is! Map) throw const FormatException('Missing effective profile');
    final data = Map<String, dynamic>.from(raw);
    final globalRoot =
        data['role'] == 'super_admin' && data['company_policy_active'] == false;
    if (uid.isEmpty ||
        email.isEmpty ||
        (!globalRoot && company.isEmpty) ||
        data['uid'] != uid ||
        data['email']?.toString().trim().toLowerCase() !=
            email.trim().toLowerCase() ||
        (!globalRoot && data['company_code'] != company)) {
      throw const FormatException('Effective profile identity mismatch');
    }
    if (!['admin', 'super_admin', 'employee'].contains(data['role']) ||
        data['company_policy_active'] is! bool ||
        data['is_active'] == false) {
      throw const FormatException('Invalid effective profile state');
    }
    if (globalRoot) data['company_code'] = company;
    data['permissions'] = data['permissions'] ?? <String, dynamic>{};
    CompanyPermissionPolicy.validateMap(data['permissions']);
    final branches = data['allowed_branches'];
    if (branches == null && data['company_policy_active'] != true) {
      data['allowed_branches'] = ['all'];
    } else if (branches == 'all') {
      data['allowed_branches'] = ['all'];
    } else if (branches is! List ||
        branches.isEmpty ||
        branches.any((v) => v is! String || v.trim().isEmpty)) {
      throw const FormatException('Invalid branch scope');
    }
    final viewable = data['hr_viewable_employees'];
    if (viewable != null &&
        (viewable is! List || viewable.any((v) => v is! String))) {
      throw const FormatException('Invalid employee scope');
    }
    if (data['company_policy_active'] == true) {
      BranchScope.validate(data['allowed_branches'], allowEmpty: false);
      final branchDelegation = data.containsKey('delegable_branches')
          ? data['delegable_branches']
          : <String>[];
      BranchScope.validate(branchDelegation);
      if (data['role'] != 'admin' && branchDelegation.isNotEmpty) {
        throw const FormatException(
            'Only a company admin has branch delegation');
      }
      data['delegable_branches'] = branchDelegation;
      final revision = data['company_policy_revision'];
      if (revision is! int || revision < 1)
        throw const FormatException('Invalid policy revision');
      for (final key in [
        'company_permissions',
        'assigned_permissions',
        'delegable_permissions'
      ]) {
        CompanyPermissionPolicy.validateMap(data[key]);
      }
      final expected = CompanyPermissionPolicy.effectivePermissions(
          data['company_permissions'], data['assigned_permissions']);
      if (!CompanyPermissionPolicy.grants(data['permissions'])
              .containsAll(CompanyPermissionPolicy.grants(expected)) ||
          !CompanyPermissionPolicy.grants(expected).containsAll(
              CompanyPermissionPolicy.grants(data['permissions']))) {
        throw const FormatException(
            'Effective rights do not match company bounds');
      }
      if (!CompanyPermissionPolicy.grants(data['company_permissions'])
          .containsAll(
              CompanyPermissionPolicy.grants(data['delegable_permissions']))) {
        throw const FormatException('Delegation exceeds company bounds');
      }
    } else {
      // Raw legacy account fields are not delegation authority.
      data.remove('delegable_branches');
    }
    // Deep copy, so an editor cannot later mutate the saved server snapshot.
    return EffectiveProfileSnapshot._(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(data))));
  }
}
