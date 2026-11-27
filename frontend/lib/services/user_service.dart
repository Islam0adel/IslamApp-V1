// frontend/lib/services/user_service.dart
import 'cache_partitions.dart';
import 'admin_cache_events.dart';

import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';
import 'api_service.dart';
import 'account_editor_snapshot.dart';
import 'package:flutter/foundation.dart';

// خدمة المستخدمين: تُدار عبر التخزين المحلي والمزامنة
/// خدمة المستخدمين — تدار عبر Hive + Sync
///
/// - Super Admin: يشوف مستخدمي كل الشركات أو شركة محددة
/// - Admin: يشوف مستخدمي شركته فقط
/// - العمليات (add/edit/delete) تُرسل للـ API ثم تُحدّث Hive
class UserService {
  static final UserService _instance = UserService._();

  // يعيد النسخة الوحيدة من الخدمة
  factory UserService() => _instance;

  // منشئ خاص يربط مستمع تغيّر الصلاحيات
  UserService._() {
    PermissionsService().addListener(_authorizationChanged);
    ReadAuthorizationEpoch.changes.addListener(_authorizationChanged);
    AdminCacheEvents.users.addListener(_directoryChanged);
    _authorizationChanged();
  }

  // يستجيب لتغيّر دليل المستخدمين
  void _directoryChanged() {
    final company = AdminCacheEvents.users.value.company;
    for (final key in [_allUsersKey, _requestsKey, _companyKey(company)]) {
      _verifiedReads.remove(key);
      _readVersions[key] = (_readVersions[key] ?? 0) + 1;
    }
  }

  // يحدد هل توجد لقطة محققة للمستخدمين
  bool hasUsersSnapshot({String? companyCode}) =>
      _verifiedReads[_companyKey(companyCode)]?.isCurrent == true &&
      PermissionsService().canOpenUserManagement;

  // يحدد هل توجد لقطة محققة للطلبات
  bool get hasRequestsSnapshot =>
      _verifiedReads[_requestsKey]?.isCurrent == true &&
      PermissionsService().canReviewUserRequests;
  final Map<String, Future<void>> _ensureWork = {};

  // يضمن تحميل البيانات بالمفتاح المحدد
  Future<void> _ensure(String key, Future<void> Function() fetch) {
    final token = '$key:${_readVersions[key] ?? 0}';
    final pending = _ensureWork[token];
    if (pending != null) return pending;
    final work = fetch();
    // The fetch reserves its new read version synchronously before first I/O.
    final reserved = '$key:${_readVersions[key] ?? 0}';
    _ensureWork[reserved] = work;
    return work.whenComplete(() {
      if (identical(_ensureWork[reserved], work)) _ensureWork.remove(reserved);
    });
  }

  // يضمن تحميل المستخدمين
  Future<void> ensureUsers({String? companyCode}) async {
    if (!hasUsersSnapshot(companyCode: companyCode)) {
      await _ensure(_companyKey(companyCode),
          () => fetchAllUsers(companyCode: companyCode));
    }
  }

  // يضمن تحميل الطلبات
  Future<void> ensureRequests() async {
    if (!hasRequestsSnapshot) await _ensure(_requestsKey, fetchPendingRequests);
  }

  final Map<String, ReadAuthorizationSnapshot> _verifiedReads = {};
  final Map<String, int> _readVersions = {};
  Future<void> _cacheWork = Future<void>.value();
  bool _cachePurgeQueued = false;

  // ينفذ عملية تخزين مؤقت بالتتابع
  Future<void> _cache(Future<void> Function() work) {
    final operation = _cacheWork.then((_) => work());
    _cacheWork = operation.catchError((Object error) {
      debugPrint('User cache update failed: $error');
    });
    return operation;
  }

  // يستجيب لتغيّر التفويض
  void _authorizationChanged() {
    if (_verifiedReads.isNotEmpty &&
        PermissionsService().canOpenUserManagement &&
        _verifiedReads.values.every((scope) => scope.isCurrent)) return;
    _verifiedReads.clear();
    _readVersions.updateAll((key, value) => value + 1);
    if (_cachePurgeQueued) return;
    _cachePurgeQueued = true;
    unawaited(_cache(() async {
      try {
        if (!CachePartitions.isBoxOpen(_boxName)) return;
        if (_box.isNotEmpty) {
          await _box.clear();
          await _box.compact();
        }
      } finally {
        _cachePurgeQueued = false;
      }
    }));
  }

  // يشترط صلاحية الوصول لدليل المستخدمين
  void _requireDirectoryAccess() {
    if (!PermissionsService().canOpenUserManagement)
      throw StateError('Current user-directory access is unavailable');
  }

  // يشترط صلاحية تنفيذ الإجراء على المستخدمين
  void _requireUserAction(String action) {
    if (!PermissionsService().canUserManagementAction(action)) {
      throw StateError('This account-management action is unavailable');
    }
  }

  // يقرأ البيانات المحققة بالمفتاح
  List<Map<String, dynamic>> _readVerified(String key) {
    final scope = _verifiedReads[key];
    if (!PermissionsService().canOpenUserManagement ||
        scope == null ||
        !scope.isCurrent) return [];
    try {
      final raw = _box.get(key);
      if (raw is! List) return [];
      return raw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // يجلب دليل المستخدمين من الخادم
  Future<void> _fetchDirectory(
      String key, Future<List<dynamic>> Function() fetch,
      {bool sortUsers = false, String? companyCode}) async {
    return CachePartitions.run(() async {
      final scope = await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      final version = (_readVersions[key] ?? 0) + 1;
      _readVersions[key] = version;
      _verifiedReads.remove(key);
      await _cache(() async {
        scope.check();
        if (_readVersions[key] == version) await _box.delete(key);
      });
      scope.check();
      _requireDirectoryAccess();
      if (_readVersions[key] != version) return;
      final data = await fetch();
      scope.check();
      _requireDirectoryAccess();
      if (_readVersions[key] != version) return;
      if (data.any((item) => item is! Map))
        throw const FormatException('Invalid account-directory record');
      final rows =
          data.map((item) => Map<String, dynamic>.from(item as Map)).toList();
      if (companyCode != null &&
          companyCode.isNotEmpty &&
          rows.any((row) => row['company_code'] != companyCode)) {
        throw const FormatException(
            'Account directory does not match the requested company');
      }
      if (sortUsers)
        rows.sort((a, b) {
          const order = {'pending': 0, 'active': 1, 'suspended': 2};
          final difference = (order[a['status'] ?? 'active'] ?? 3)
              .compareTo(order[b['status'] ?? 'active'] ?? 3);
          return difference != 0
              ? difference
              : (a['name'] ?? '')
                  .toString()
                  .compareTo((b['name'] ?? '').toString());
        });
      await _cache(() async {
        scope.check();
        _requireDirectoryAccess();
        if (_readVersions[key] != version) return;
        _verifiedReads[key] = scope;
        try {
          // Bind before the synchronous Hive event, never after an awaited write.
          await _box.put(key, rows);
          if (!scope.isCurrent ||
              !PermissionsService().canOpenUserManagement ||
              _readVersions[key] != version) {
            _verifiedReads.remove(key);
            await _box.delete(key);
            scope.check();
            _requireDirectoryAccess();
          }
        } catch (_) {
          _verifiedReads.remove(key);
          await _box.delete(key);
          rethrow;
        }
      });
    });
  }

  static const String _boxName = 'users_box';
  static const String _allUsersKey = 'all_users';
  static const String _requestsKey = 'requests_pending';

  final ApiService _api = ApiService();

  // يعيد صندوق المستخدمين المحلي
  Box get _box => CachePartitions.box(_boxName);

  // يبني مفتاح الشركة
  String _companyKey(String? code) =>
      (code == null || code.isEmpty) ? _allUsersKey : 'company_$code';

  // ============================================================
  // 1. قراءة من Hive
  // ============================================================

  // يعيد المستخدمين من التخزين المحلي
  List<Map<String, dynamic>> getUsersFromHive({String? companyCode}) =>
      _readVerified(_companyKey(companyCode));

  // يعيد الطلبات من التخزين المحلي
  List<Map<String, dynamic>> getRequestsFromHive() =>
      _readVerified(_requestsKey);

  // يوفر مستمعًا لتحديث الواجهة عند تغيّر المستخدمين
  ValueListenable<Box> get usersListenable => _box.listenable();

  // ============================================================
  // 2. جلب كل المستخدمين من السيرفر
  // ============================================================

  // يجلب كل المستخدمين من الخادم
  Future<void> fetchAllUsers({String? companyCode}) => _fetchDirectory(
      _companyKey(companyCode),
      () => _api.getCompanyUsers(companyCode: companyCode),
      sortUsers: true,
      companyCode: companyCode);

  // يجلب طلبات الانضمام المعلقة
  Future<void> fetchPendingRequests() {
    if (!PermissionsService().canReviewUserRequests) {
      throw StateError('Registration request review is unavailable');
    }
    return _fetchDirectory(
        _requestsKey, () => _api.getRegistrationRequests(status: 'pending'));
  }

  // ============================================================
  // 4. العمليات (Add/Edit/Delete/Reset)
  // ============================================================

  // يضيف مستخدمًا
  Future<void> addUser({
    required String name,
    required String phoneNumber,
    required String branchCode,
    required String role,
    String? companyCode,
    String? email,
    String? username,
  }) async {
    return CachePartitions.run(() async {
      final scope = await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      _requireUserAction('إضافة');
      scope.check();
      await _api.adminAddUser(
        name: name,
        phoneNumber: phoneNumber,
        branchCode: branchCode,
        role: role,
        companyCode: companyCode,
        email: email,
        username: username,
      );
      // حدّث Hive بعد الإضافة
      if (!scope.isCurrent || !PermissionsService().canOpenUserManagement)
        return;
      await fetchAllUsers(companyCode: companyCode);
    });
  }

  // يحمّل بيانات محرر الحساب
  Future<AccountEditorSnapshot> loadAccountEditor(String documentId) async {
    return CachePartitions.run(() async {
      final scope = await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      scope.check();
      final value = await _api.getAccountEditor(documentId);
      scope.check();
      _requireDirectoryAccess();
      final editor = AccountEditorSnapshot.fromServer(value, documentId, scope);
      if (!PermissionsService().isSuperAdmin &&
          editor.companyCode !=
              (await CachePartitions.preferences()).getString('company_code')) {
        throw StateError('Account editor company changed');
      }
      scope.check();
      return editor;
    });
  }

  // يعدّل بيانات مستخدم
  Future<void> editUser({
    required String email,
    String? name,
    String? invitationEmail,
    String? phoneNumber,
    String? branchCode,
    String? role,
    String? username,
    String? status,
    bool? isActive,
    String? companyCode,
    AccountEditorSnapshot? editor,
  }) async {
    return CachePartitions.run(() async {
      final scope = editor?.scope ?? await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      scope.check();
      if (editor != null) {
        if (editor.documentId != email.trim().toLowerCase() ||
            (companyCode != null &&
                companyCode.isNotEmpty &&
                companyCode != editor.companyCode)) {
          throw StateError('Account editor target or company changed');
        }
        if (!editor.canEdit &&
            [name, phoneNumber, branchCode, username, invitationEmail]
                .any((value) => value != null)) {
          throw StateError('Account metadata edit is unavailable');
        }
        if (((status != null || isActive != null) && !editor.canChangeStatus) ||
            (role != null && !editor.canChangeRole)) {
          throw StateError('Account role or status edit is unavailable');
        }
      }
      await _api.adminEditUser(
        email: email,
        name: name,
        invitationEmail: invitationEmail,
        phoneNumber: phoneNumber,
        branchCode: branchCode,
        role: role,
        username: username,
        status: status,
        isActive: isActive,
        expectedTargetUid: editor?.uid,
        expectedProfileVersion: editor?.profileVersion,
        expectedPolicyRevision: editor?.policyRevision,
      );
      if (!scope.isCurrent || !PermissionsService().canOpenUserManagement)
        return;
      try {
        await fetchAllUsers(companyCode: companyCode);
      } catch (_) {
        throw const UserSavedRefreshFailed();
      }
    });
  }

  // يحذف مستخدمًا
  Future<void> deleteUser({
    required String email,
    String? companyCode,
  }) async {
    return CachePartitions.run(() async {
      final scope = await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      _requireUserAction('حذف');
      scope.check();
      await _api.adminDeleteUser(email: email);
      if (!scope.isCurrent || !PermissionsService().canOpenUserManagement)
        return;
      await fetchAllUsers(companyCode: companyCode);
    });
  }

  // يعيد تعيين مستخدم معلق
  Future<void> resetPendingUser({
    required String email,
    String? companyCode,
  }) async {
    return CachePartitions.run(() async {
      final scope = await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      _requireUserAction('إعادة تهيئة حساب');
      scope.check();
      await _api.adminResetPendingUser(email: email);
      if (!scope.isCurrent || !PermissionsService().canOpenUserManagement)
        return;
      await fetchAllUsers(companyCode: companyCode);
    });
  }

  // ============================================================
  // 5. عمليات الطلبات
  // ============================================================

  // يوافق على طلب انضمام
  Future<void> approveRequest({
    required String requestId,
    required String role,
    String? branchCode,
    String? companyCode,
  }) async {
    return CachePartitions.run(() async {
      final scope = await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      _requireUserAction('الموافقة على طلب');
      scope.check();
      await _api.approveRegistrationRequest(
        requestId: requestId,
        role: role,
        branchCode: branchCode,
        companyCode: companyCode,
      );
      // حدّث الطلبات + المستخدمين
      if (!scope.isCurrent || !PermissionsService().canOpenUserManagement)
        return;
      await fetchPendingRequests();
      if (!scope.isCurrent || !PermissionsService().canOpenUserManagement)
        return;
      await fetchAllUsers(companyCode: companyCode);
    });
  }

  // يرفض طلب انضمام
  Future<void> rejectRequest({required String requestId}) async {
    return CachePartitions.run(() async {
      final scope = await ReadAuthorizationSnapshot.capture();
      _requireDirectoryAccess();
      _requireUserAction('رفض طلب');
      scope.check();
      await _api.rejectRegistrationRequest(requestId: requestId);
      if (!scope.isCurrent || !PermissionsService().canOpenUserManagement)
        return;
      await fetchPendingRequests();
    });
  }

  // ============================================================
  // 6. مسح الـ Cache
  // ============================================================

  // يمسح الذاكرة المؤقتة للمستخدمين
  Future<void> clearCache() async {
    return CachePartitions.run(() async {
      _verifiedReads.clear();
      _readVersions.updateAll((key, value) => value + 1);
      await _cache(() async {
        await _box.clear();
        await _box.compact();
      });
    });
  }
}
