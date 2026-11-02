// lib/services/presence_service.dart

import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'permissions_service.dart';

class PresenceService {
  static final PresenceService instance = PresenceService._();
  PresenceService._();

  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  StreamSubscription<DatabaseEvent>? _connectedSubscription;
  DatabaseReference? _userStatusRef;
  bool _started = false;

  Future<String> _resolveBranch() async {
    final prefs = await SharedPreferences.getInstance();
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
  }

  Future<String> _resolveBranchName(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final companyCode = prefs.getString('company_code') ?? '';
    try {
      final box = Hive.box('coding_box');
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
  }

  Future<Map<String, dynamic>> _buildPayload() async {
    final user = _auth.currentUser;
    if (user == null) return {};

    final prefs = await SharedPreferences.getInstance();
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
  }

  Future<void> start() async {
    if (_started) return;

    final user = _auth.currentUser;
    if (user == null) return;

    _started = true;
    _userStatusRef = _database.ref('presence/${user.uid}');

    _connectedSubscription =
        _database.ref('.info/connected').onValue.listen((event) async {
      final connected = event.snapshot.value as bool? ?? false;
      if (!connected) return;

      // ✅ onDisconnect: update فقط — بيحافظ على current_branch/name/email
      await _userStatusRef!.onDisconnect().update({
        'state': 'offline',
        'last_changed': ServerValue.timestamp,
      });

      // set كامل عند الاتصال
      final payload = await _buildPayload();
      if (payload.isNotEmpty) {
        await _userStatusRef!.set(payload);
        print('🟢 Presence: متصل — ${payload['name']} (${payload['current_branch']})');
      }
    });
  }

  Future<void> refresh() async {
    if (!_started) {
      await start();
      return;
    }
    if (_userStatusRef == null) return;

    try {
      final payload = await _buildPayload();
      if (payload.isEmpty) return;
      await _userStatusRef!.set(payload);
      print('🟢 Presence: refresh → ${payload['current_branch']}');
    } catch (e) {
      print('⚠️ Presence refresh: $e');
    }
  }

  Future<void> stop() async {
    await _connectedSubscription?.cancel();
    _connectedSubscription = null;

    final user = _auth.currentUser;
    if (user != null && _userStatusRef != null) {
      try {
        // ✅ update فقط — البيانات بتفضل في RTDB
        await _userStatusRef!.update({
          'state': 'offline',
          'last_changed': ServerValue.timestamp,
        });
        print('🔴 Presence: offline (البيانات محفوظة)');
      } catch (e) {
        print('⚠️ Presence stop: $e');
      }
    }

    _userStatusRef = null;
    _started = false;
  }

  // ============================================================
  // ✅ NEW: حذف مستخدم من RTDB عن طريق الإيميل
  //
  // للأدمن من صفحة الصلاحيات.
  // - يبحث في presence عن مستخدم بنفس الإيميل
  // - يحذف الـ node بالكامل (node = presence/{uid})
  // - لو المستخدم رجع يسجل دخول، هيتسجل من جديد تلقائيًا
  //
  // آمن: بيحذف من RTDB فقط (الحضور)، مش من Firestore/Auth
  // ============================================================
  Future<bool> removeUserByEmail(String email) async {
    if (email.isEmpty) return false;

    try {
      final snapshot = await _database.ref('presence').once();
      final data = snapshot.snapshot.value;
      if (data is! Map) return false;

      final targetEmail = email.toLowerCase().trim();

      for (final entry in data.entries) {
        final v = entry.value;
        if (v is! Map) continue;

        final u = Map<String, dynamic>.from(
          v.map((k, val) => MapEntry(k.toString(), val)),
        );

        final userEmail = (u['email'] ?? '').toString().toLowerCase().trim();
        if (userEmail == targetEmail) {
          await _database.ref('presence/${entry.key}').remove();
          print('🗑️ Presence: تم حذف $email من RTDB (uid: ${entry.key})');
          return true;
        }
      }

      print('ℹ️ Presence: $email مش موجود في RTDB');
      return false;
    } catch (e) {
      print('⚠️ Presence removeUserByEmail: $e');
      return false;
    }
  }
}