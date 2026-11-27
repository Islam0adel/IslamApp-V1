// frontend/lib/services/presence_service.dart
import 'cache_partitions.dart';

import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'permissions_service.dart';
// import 'package:cloud_firestore/cloud_firestore.dart';
// import 'package:http/http.dart' as http;
// import 'dart:convert';
import '../core/constants.dart';
import 'auth_http.dart';

// خدمة حالة الاتصال (التواجد) للمستخدم
class PresenceService {
  static final PresenceService instance = PresenceService._();
  PresenceService._();

  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  StreamSubscription<DatabaseEvent>? _connectedSubscription;
  DatabaseReference? _userStatusRef;
  bool _started = false;

  // ⭐ timeout لكل عملية RTDB — يمنع التعليق
  static const Duration _rtdbTimeout = Duration(seconds: 4);

  // يحدد فرع المستخدم الحالي
  Future<String> _resolveBranch() async {
    return CachePartitions.run(() async {
      final prefs = await CachePartitions.preferences();
      final selected = prefs.getString('selected_branch_code') ?? 'all';

      if (selected != 'all' && selected != 'none' && selected.isNotEmpty) {
        return selected;
      }

      final allowed = PermissionsService().allowedBranches;
      if (allowed != null) {
        for (final b in allowed) {
          if (b != 'all' && b != 'none' && b.isNotEmpty) return b;
        }
      }
      return '1';
    });
  }

  // يعيد اسم الفرع من الكود
  Future<String> _resolveBranchName(String code) async {
    return CachePartitions.run(() async {
      final prefs = await CachePartitions.preferences();
      final companyCode = prefs.getString('company_code') ?? '';
      try {
        final box = CachePartitions.box('coding_box');
        final list = box.get('${companyCode}_branches', defaultValue: []);
        if (list is List) {
          for (final item in list) {
            if (item is Map && item['code']?.toString() == code) {
              return item['name']?.toString() ?? code;
            }
          }
        }
      } catch (_) {}
      return code == 'all' ? 'كل الفروع' : code;
    });
  }

  // يبني بيانات حالة التواجد المرسلة
  Future<Map<String, dynamic>> _buildPayload() async {
    return CachePartitions.run(() async {
      final user = _auth.currentUser;
      if (user == null) return {};

      final prefs = await CachePartitions.preferences();
      final name = prefs.getString('user_name') ?? user.email ?? 'مستخدم';
      final email = prefs.getString('user_email') ?? user.email ?? '';
      final companyCode = prefs.getString('company_code') ?? '';
      final currentBranch = await _resolveBranch();
      final branchName = await _resolveBranchName(currentBranch);
      final allowed = PermissionsService().allowedBranches ?? <String>['all'];
      final hasAll = allowed.contains('all');

      return {
        'state': 'online',
        'last_changed': ServerValue.timestamp,
        'name': name,
        'email': email,
        'company_code': companyCode,
        'current_branch': currentBranch,
        'current_branch_name': branchName,
        'has_all_branches': hasAll,
        'uid': user.uid,
      };
    });
  }

  // ============================================================
  // ✅ start — آمن، مفيش تعليق
  // ============================================================
  // يبدأ نشر حالة التواجد
  Future<void> start() async {
    return CachePartitions.run(() async {
      if (_started) return;

      final user = _auth.currentUser;
      if (user == null) {
        print('⚠️ Presence: skipped — no current user');
        return;
      }

      _started = true;
      _userStatusRef = _database.ref('presence/${user.uid}');

      try {
        _connectedSubscription =
            _database.ref('.info/connected').onValue.listen((event) {
          try {
            final connected = event.snapshot.value as bool? ?? false;
            if (!connected) return;

            // ⭐ fire-and-forget — مش بنستنى، عشان ما يتعلقش
            _registerOnDisconnect();
            _publishOnline();
          } catch (e) {
            print('⚠️ Presence listener error: $e');
          }
        });
      } catch (e) {
        print('⚠️ Presence start failed: $e');
        _started = false;
      }
    });
  }

  // ⭐ تسجيل onDisconnect بدون await — fire-and-forget
  // يسجّل إجراء عند انقطاع الاتصال
  void _registerOnDisconnect() {
    final ref = _userStatusRef;
    if (ref == null) return;

    try {
      ref
          .onDisconnect()
          .update({
            'state': 'offline',
            'last_changed': ServerValue.timestamp,
          })
          .timeout(_rtdbTimeout)
          .then((_) {
            print('✅ Presence: onDisconnect registered');
          })
          .catchError((e) {
            print('⚠️ Presence onDisconnect skipped: $e');
          });
    } catch (e) {
      print('⚠️ Presence onDisconnect setup failed: $e');
    }
  }

  // ⭐ نشر الحالة online — fire-and-forget
  // ينشر حالة الاتصال
  Future<void> _publishOnline() async {
    return CachePartitions.run(() async {
      final ref = _userStatusRef;
      if (ref == null) return;

      try {
        final payload = await _buildPayload();
        if (payload.isEmpty) return;

        await ref.set(payload).timeout(_rtdbTimeout);

        print(
          '🟢 Presence: متصل — ${payload['name']} (${payload['current_branch']})',
        );
      } catch (e) {
        // ⭐ لو فشل، ما نوقفش التطبيق
        print('⚠️ Presence publish skipped: $e');
      }
    });
  }

  // ============================================================
  // ✅ refresh — آمن
  // ============================================================
  // يحدّث بيانات التواجد
  Future<void> refresh() async {
    return CachePartitions.run(() async {
      if (!_started) {
        await start();
        return;
      }
      if (_userStatusRef == null) return;

      try {
        final payload = await _buildPayload();
        if (payload.isEmpty) return;
        await _userStatusRef!.set(payload).timeout(_rtdbTimeout);
        print('🟢 Presence: refresh → ${payload['current_branch']}');
      } catch (e) {
        print('⚠️ Presence refresh: $e');
      }
    });
  }

  // ============================================================
  // ✅ stop — آمن
  // ============================================================
  // يوقف نشر حالة التواجد
  Future<void> stop() async {
    return CachePartitions.run(() async {
      try {
        await _connectedSubscription?.cancel();
      } catch (_) {}
      _connectedSubscription = null;

      final user = _auth.currentUser;
      if (user != null && _userStatusRef != null) {
        try {
          await _userStatusRef!.update({
            'state': 'offline',
            'last_changed': ServerValue.timestamp,
          }).timeout(_rtdbTimeout);
          print('🔴 Presence: offline (البيانات محفوظة)');
        } catch (e) {
          print('⚠️ Presence stop skipped: $e');
        }
      }

      _userStatusRef = null;
      _started = false;
    });
  }

  // ============================================================
  // ✅ حذف مستخدم من RTDB عن طريق الإيميل
  // ============================================================
  // يزيل المستخدم من قائمة المتصلين بالبريد
  Future<bool> removeUserByEmail(String email) async {
    return CachePartitions.run(() async {
      final targetEmail = email.trim().toLowerCase();
      if (targetEmail.isEmpty) return false;
      try {
        final response = await AuthHttp.delete(
          Uri.parse(
              '${ApiConstants.baseUrl}/auth/admin/presence/${Uri.encodeComponent(targetEmail)}'),
        ).timeout(_rtdbTimeout);
        if (response.statusCode == 200) return true;
        print('⚠️ حذف الحضور فشل (${response.statusCode}): ${response.body}');
        return false;
      } catch (e) {
        print('⚠️ طلب حذف الحضور فشل: $e');
        return false;
      }
    });
  }
}
