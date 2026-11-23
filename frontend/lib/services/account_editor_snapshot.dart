import 'read_authorization_snapshot.dart';

/// The same authorization snapshot accompanies loading and saving this editor.
class AccountEditorSnapshot {
  AccountEditorSnapshot._(
      this.scope,
      this.documentId,
      this.uid,
      this.profileVersion,
      this.policyRevision,
      this.companyCode,
      this.canEdit,
      this.canChangeStatus,
      this.canChangeRole,
      this.data,
      this.branches);
  final ReadAuthorizationSnapshot scope;
  final String documentId, uid, profileVersion, companyCode;
  final int? policyRevision;
  final bool canEdit, canChangeStatus, canChangeRole;
  final Map<String, dynamic> data;
  final List<Map<String, String>> branches;
  bool get isCurrent => scope.isCurrent;

  factory AccountEditorSnapshot.fromServer(Map<String, dynamic> value,
      String requestedId, ReadAuthorizationSnapshot scope) {
    scope.check();
    String text(String key, {bool empty = true}) {
      final item = value[key];
      if (item is! String || (!empty && item.isEmpty)) {
        throw FormatException('Invalid account editor field: $key');
      }
      return item;
    }

    bool flag(String key) {
      final item = value[key];
      if (item is! bool)
        throw FormatException('Invalid account editor flag: $key');
      return item;
    }

    final documentId = text('document_id', empty: false);
    if (documentId != requestedId.trim().toLowerCase()) {
      throw const FormatException('Account editor target changed');
    }
    final uid = text('uid'), company = text('company_code', empty: false);
    final version = text('profile_version', empty: false);
    final active = flag('company_policy_active');
    final revision = value['company_policy_revision'];
    if ((revision != null && revision is! int) ||
        (active && (revision is! int || revision < 1))) {
      throw const FormatException('Invalid account policy version');
    }
    final edit = flag('can_edit'), status = flag('can_change_status');
    final role = flag('can_change_role');
    if (!edit && !status && !role) {
      throw const FormatException('Account editor has no available action');
    }
    final data = <String, dynamic>{
      'email': documentId,
      'uid': uid,
      'company_code': company,
      'name': text('name'),
      'role': text('role'),
      'status': text('status'),
      'is_active': flag('is_active'),
    };
    final choices = <Map<String, String>>[];
    if (edit) {
      final branches = value['branch_choices'];
      final allowed = value['allowed_branches'];
      if (branches is! List ||
          allowed is! List ||
          allowed.any((item) => item is! String)) {
        throw const FormatException('Invalid account branch choices');
      }
      final seen = <String>{};
      for (final item in branches) {
        if (item is! Map ||
            item['code'] is! String ||
            item['name'] is! String ||
            (item['code'] as String).isEmpty ||
            !seen.add(item['code'] as String)) {
          throw const FormatException('Invalid account branch choice');
        }
        choices.add(Map.unmodifiable(
            {'code': item['code'] as String, 'name': item['name'] as String}));
      }
      data.addAll({
        'invitation_email': value['invitation_email'] is String ? value['invitation_email'] : '',
        'can_set_invitation_email': value['can_set_invitation_email'] == true,
        'phone_number': text('phone_number'),
        'username': text('username'),
        'startup_branch_code': text('startup_branch_code'),
        'allowed_branches': List<String>.unmodifiable(allowed.cast<String>())
      });
    }
    return AccountEditorSnapshot._(
        scope,
        documentId,
        uid,
        version,
        revision as int?,
        company,
        edit,
        status,
        role,
        Map.unmodifiable(data),
        List.unmodifiable(choices));
  }
}

class UserSavedRefreshFailed implements Exception {
  const UserSavedRefreshFailed();
  @override
  String toString() =>
      'تم حفظ التعديل، لكن تعذر تحديث قائمة المستخدمين. أعد تحميل القائمة ولا تكرر الحفظ.';
}
