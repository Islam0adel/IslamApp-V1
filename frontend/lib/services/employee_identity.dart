// frontend/lib/services/employee_identity.dart
// Explicit employee/account links. A UID is authoritative when present.
// فئة مطابقة هوية الموظف مع صفوف البيانات
class EmployeeIdentity {
  // يحدد هل الصف يخص المستخدم والبريد المحددين
  static bool matches(Map row, {required String uid, required String email}) {
    if (row['is_deleted'] == true) return false;
    final linkedUid = (row['user_uid'] ?? '').toString();
    if (linkedUid.isNotEmpty) return uid.isNotEmpty && linkedUid == uid;
    final linkedEmail =
        (row['user_email'] ?? '').toString().trim().toLowerCase();
    return email.trim().isNotEmpty && linkedEmail == email.trim().toLowerCase();
  }

  // يستخرج كود الموظف من الصفوف المطابقة
  static String? resolveCode(Iterable rows,
      {required String uid, required String email}) {
    final active = rows
        .whereType<Map>()
        .where((row) => row['is_deleted'] != true)
        .toList();
    final exact = active
        .where((row) =>
            uid.isNotEmpty && (row['user_uid'] ?? '').toString() == uid)
        .toList();
    String? unique(Iterable<Map> candidates) {
      final list = candidates.toList();
      if (list.length != 1) return null;
      final code = (list.single['code'] ?? '').toString().trim();
      return code.isEmpty ? null : code;
    }

    if (exact.isNotEmpty) return unique(exact);
    return unique(active.where((row) => matches(row, uid: uid, email: email)));
  }
}
