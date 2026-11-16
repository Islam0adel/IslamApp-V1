// lib/services/user_service.dart

import 'package:hive_flutter/hive_flutter.dart';
import 'api_service.dart';
import 'package:flutter/foundation.dart';

/// خدمة المستخدمين — تدار عبر Hive + Sync
///
/// - Super Admin: يشوف مستخدمي كل الشركات أو شركة محددة
/// - Admin: يشوف مستخدمي شركته فقط
/// - العمليات (add/edit/delete) تُرسل للـ API ثم تُحدّث Hive
class UserService {
  static final UserService _instance = UserService._();
  factory UserService() => _instance;
  UserService._();

  static const String _boxName = 'users_box';
  static const String _allUsersKey = 'all_users';
  static const String _requestsKey = 'requests_pending';

  final ApiService _api = ApiService();

  Box get _box => Hive.box(_boxName);

  String _companyKey(String? code) =>
      (code == null || code.isEmpty) ? _allUsersKey : 'company_$code';

  // ============================================================
  // 1. قراءة من Hive
  // ============================================================

  List<Map<String, dynamic>> getUsersFromHive({String? companyCode}) {
    try {
      final raw = _box.get(_companyKey(companyCode));
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      print('❌ [UserService] قراءة المستخدمين من Hive فشلت: $e');
    }
    return [];
  }

  List<Map<String, dynamic>> getRequestsFromHive() {
    try {
      final raw = _box.get(_requestsKey);
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      print('❌ [UserService] قراءة الطلبات من Hive فشلت: $e');
    }
    return [];
  }

  ValueListenable<Box> get usersListenable => _box.listenable();

  // ============================================================
  // 2. جلب كل المستخدمين من السيرفر
  // ============================================================

  Future<void> fetchAllUsers({String? companyCode}) async {
    final key = _companyKey(companyCode);
    print('📥 [Users] بدء FULL SYNC (company=$companyCode)...');

    try {
      final List<dynamic> data =
          await _api.getCompanyUsers(companyCode: companyCode);

      final List<Map<String, dynamic>> users = [];
      for (final item in data) {
        if (item is! Map) continue;
        users.add(Map<String, dynamic>.from(item));
      }

      // ترتيب: pending أولاً
      users.sort((a, b) {
        final order = {'pending': 0, 'active': 1, 'suspended': 2};
        final aOrder = order[a['status']?.toString() ?? 'active'] ?? 3;
        final bOrder = order[b['status']?.toString() ?? 'active'] ?? 3;
        if (aOrder != bOrder) return aOrder.compareTo(bOrder);
        return (a['name']?.toString() ?? '')
            .compareTo(b['name']?.toString() ?? '');
      });

      await _box.put(key, users);
      print('✅ [Users] تم حفظ ${users.length} مستخدم في Hive');
    } catch (e) {
      print('❌ [Users] فشل FULL SYNC: $e');
      rethrow;
    }
  }

  // ============================================================
  // 3. طلبات الانضمام
  // ============================================================

  Future<void> fetchPendingRequests() async {
    print('📥 [Users] جلب طلبات الانضمام المعلقة...');

    try {
      final List<dynamic> data =
          await _api.getRegistrationRequests(status: 'pending');

      final List<Map<String, dynamic>> requests = [];
      for (final item in data) {
        if (item is! Map) continue;
        requests.add(Map<String, dynamic>.from(item));
      }

      await _box.put(_requestsKey, requests);
      print('✅ [Users] ${requests.length} طلب معلق محفوظ في Hive');
    } catch (e) {
      print('❌ [Users] فشل جلب الطلبات: $e');
      rethrow;
    }
  }

  // ============================================================
  // 4. العمليات (Add/Edit/Delete/Reset)
  // ============================================================

  Future<void> addUser({
    required String name,
    required String phoneNumber,
    required String branchCode,
    required String role,
    String? companyCode,
    String? email,
    String? username,
  }) async {
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
    await fetchAllUsers(companyCode: companyCode);
  }

  Future<void> editUser({
    required String email,
    String? name,
    String? phoneNumber,
    String? branchCode,
    String? role,
    String? username,
    String? status,
    String? companyCode,
  }) async {
    await _api.adminEditUser(
      email: email,
      name: name,
      phoneNumber: phoneNumber,
      branchCode: branchCode,
      role: role,
      username: username,
      status: status,
    );
    await fetchAllUsers(companyCode: companyCode);
  }

  Future<void> deleteUser({
    required String email,
    String? companyCode,
  }) async {
    await _api.adminDeleteUser(email: email);
    await fetchAllUsers(companyCode: companyCode);
  }

  Future<void> resetPendingUser({
    required String email,
    String? companyCode,
  }) async {
    await _api.adminResetPendingUser(email: email);
    await fetchAllUsers(companyCode: companyCode);
  }

  // ============================================================
  // 5. عمليات الطلبات
  // ============================================================

  Future<void> approveRequest({
    required String requestId,
    required String role,
    String? branchCode,
    String? companyCode,
  }) async {
    await _api.approveRegistrationRequest(
      requestId: requestId,
      role: role,
      branchCode: branchCode,
      companyCode: companyCode,
    );
    // حدّث الطلبات + المستخدمين
    await fetchPendingRequests();
    await fetchAllUsers(companyCode: companyCode);
  }

  Future<void> rejectRequest({required String requestId}) async {
    await _api.rejectRegistrationRequest(requestId: requestId);
    await fetchPendingRequests();
  }

  // ============================================================
  // 6. مسح الـ Cache
  // ============================================================

  Future<void> clearCache() async {
    await _box.clear();
  }
}