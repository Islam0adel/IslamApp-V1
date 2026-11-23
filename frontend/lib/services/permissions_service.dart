import 'page_visibility.dart';
import 'cache_partitions.dart';
import 'admin_cache_events.dart';
import 'scope_sync_plan.dart';
import 'dart:convert';
import 'effective_profile_snapshot.dart';
import 'company_permission_policy.dart';
import 'permission_editor_snapshot.dart';
import 'read_authorization_snapshot.dart';
import 'permission_hierarchy.dart';
import 'employee_identity.dart';
import 'treasury_cache_scope.dart';
// lib/services/permissions_service.dart

import 'dart:async';                                   // ← NEW
import 'package:flutter/foundation.dart';              // ← NEW: ChangeNotifier
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'revocation_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/api_service.dart';

class PermissionsService extends ChangeNotifier {      // ← extends ChangeNotifier
  static final PermissionsService _instance =
      PermissionsService._internal();

  factory PermissionsService() => _instance;

  // ============================================================
  // ✅ Firebase Auth State Listener
  //
  // أول ما الـ singleton يتعمل، بنسمع لتغييرات حالة الـ Auth:
  // - login (user موجود)
  // - logout (user = null)
  // - تغيير حساب (user جديد)
  //
  // أي تغيير → reset تلقائي للصلاحيات + إيقاف Firestore listener
  // ============================================================

  PermissionsService._internal() {
    try {
      FirebaseAuth.instance
          .authStateChanges()
          .listen(_onAuthStateChanged);
    } catch (e) {
      print('⚠️ فشل تسجيل auth listener: $e');
    }
  }

  // ============================================================
  // البيانات الحالية للصلاحيات
  // ============================================================

  Map<String, Map<String, bool>>? _permissions;
  List<String>? _allowedBranchCodes;
  String? _defaultBranchCode;
  String? _currentRole;   // ⭐ جديد
  bool _companyPolicyActive = false;
  bool _scopeVerificationPending = false;
  Map<String, dynamic> _delegablePermissions = {};
  List<String> _delegableBranchCodes = [];
  List<String> get delegableBranchCodes =>
      !_scopeVerificationPending && _companyPolicyActive && isAdmin
          ? List<String>.unmodifiable(_delegableBranchCodes) : const [];
  bool canDelegateBranch(String branchCode) => !_scopeVerificationPending &&
      (canBypassPermissions || (isAdmin && _companyPolicyActive &&
        (_delegableBranchCodes.contains('all') || _delegableBranchCodes.contains(branchCode))));
  Future<void>? _serverRefresh;
  int _serverScopeGeneration = 0;
  final Set<String> _pendingSyncModules = {};
  Set<String> takeScopeSyncModules() {
    final result = Set<String>.from(_pendingSyncModules);
    _pendingSyncModules.clear();
    return result;
  }
  void _recordScopeSync(Map<String,dynamic>? before, Map<String,dynamic>? after,
      List<String>? oldBranches,List<String>? branches,List<String>? oldEmployees,List<String>? employees) {
    _pendingSyncModules.addAll(ScopeSyncPlan.between(before:before,after:after,
      oldBranches:oldBranches,branches:branches,oldEmployees:oldEmployees,employees:employees));
  }
  /// Superseded reads stay rejected. The caller joins a NEW current check,
  /// never treats an old response as approved for the new generation.
  Future<void> verifyCurrentEffectiveProfile({bool restrictWhileLoading = true}) async {
return CachePartitions.run(() async {

    final context = await ReadAuthorizationSnapshot.capture();
    for (var attempt=0; attempt<4; attempt++) {
      try {
        final pending = _serverRefresh;
        if(pending != null) { await pending; } else {
          await refreshEffectiveProfile(restrictWhileLoading:restrictWhileLoading);
        }
        if(!context.sameContext) throw const ReadAuthorizationChanged();
        if(_serverRefresh != null && !identical(_serverRefresh,pending)) continue;
        if(_scopeVerificationPending || !_loaded) throw const ReadAuthorizationChanged();
        return;
      } on ReadAuthorizationChanged {
        if(!context.sameContext || attempt==3) rethrow;
      }
    }
    throw const ReadAuthorizationChanged();
});
}
  bool get companyPolicyActive => _companyPolicyActive;
  bool get canBypassPermissions => !_scopeVerificationPending && (isSuperAdmin || (isAdmin && !_companyPolicyActive));
    List<String>? _hrViewableEmployees;

    /// ⭐ كود الموظف الحالي (لو مربوط بحساب Firebase)
  String? _currentEmployeeCode;
  String? _identityProfileUid;
  String? _identityCompany;

  /// ⭐ إيميل المستخدم الحالي (للـ fallback)
  String? _currentUserEmail;

  /// ⭐ SharedPreferences cached (للـ fallback)
  CachePreferences? _cachedPrefs;

  // ============================================================
  // حماية من التحميل المتكرر + تتبع المستخدم
  // ============================================================

  Future<void>? _loadFuture;
  bool _loaded = false;

  /// آخر UID محفوظ — يستخدمه الـ listener لكشف تغيير المستخدم
  String? _cachedUid;

    // ✅ NEW: Firestore snapshot listener
  StreamSubscription<DocumentSnapshot>? _firestoreSub;
  String? _listenedEmail;

  /// ⭐ Hive listener — لإعادة حساب _currentEmployeeCode لما employees تتحمل
  StreamSubscription<BoxEvent>? _employeesHiveSub;

  /// هل الصلاحيات محملة وجاهزة للاستخدام؟
  bool get isLoaded => _loaded;

  // ============================================================
  // ⭐ Role Getters
  // ============================================================

  /// الدور الحالي (super_admin / admin / employee)
  String? get currentRole => _currentRole;

  /// السوبر أدمن (صاحب البرنامج) — كل شيء مفتوح
  bool get isSuperAdmin => !_scopeVerificationPending && _currentRole == 'super_admin';

  /// مدير الشركة — كل شيء مفتوح ما عدا إدارة الشركات
  bool get isAdmin =>
      !_scopeVerificationPending && (_currentRole == 'admin' || _currentRole == 'super_admin');

  /// موظف عادي — Sandbox
  bool get isEmployee =>
      _currentRole == 'employee' || _currentRole == null;

  /// إدارة الشركات (super_admin فقط)
  bool get canManageCompanies => !_scopeVerificationPending && isSuperAdmin;

  /// Legacy role gate used by pending-operation ownership, not user actions.
  bool get canManageUsers => !_scopeVerificationPending && isAdmin;

  static const userManagementActions = <String>[
    'معاينة', 'إضافة', 'تعديل', 'حذف', 'تغيير حالة الحساب',
    'إعادة تهيئة حساب', 'الموافقة على طلب', 'رفض طلب',
  ];

  bool canUserManagementAction(String action) {
    if (_scopeVerificationPending || !userManagementActions.contains(action)) return false;
    if (isSuperAdmin) return true;
    if (!_companyPolicyActive) return isAdmin;
    return hasPermission('إدارة المستخدمين', action);
  }

  bool get canOpenUserManagement =>
      userManagementActions.any(canUserManagementAction);
  bool get canReviewUserRequests => canUserManagementAction('الموافقة على طلب') ||
      canUserManagementAction('رفض طلب');

  /// إدارة الصلاحيات (admin + super_admin)
  bool get canManagePermissions => !_scopeVerificationPending && (canBypassPermissions || (isAdmin && _companyPolicyActive && (CompanyPermissionPolicy.grants(_delegablePermissions).isNotEmpty || _delegableBranchCodes.isNotEmpty)));

  /// تحديث الدور يدوياً (بعد تسجيل دخول أو عند تغييره)
  void setRole(String? role) {
    final normalized = (role ?? '').trim();
    if (_currentRole == normalized) return;
    ReadAuthorizationEpoch.invalidate();
    _currentRole = normalized;
    notifyListeners();
  }

  /// ⭐ تحديث الفروع المسموحة فوراً (بعد login — قبل Firestore listener)
  void setAllowedBranches(List<String>? branches) {
    List<String> effective;
    if (branches == null || branches.isEmpty) {
      effective = ['all'];
    } else {
      effective = branches
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (effective.isEmpty) effective = ['all'];
    }

    if (!const DeepEq().equals(_allowedBranchCodes, effective)) ReadAuthorizationEpoch.invalidate();
    _allowedBranchCodes = effective;

    // حفظ في Hive (للمرات القادمة)
    final email = _currentUserEmail;
    if (email != null && email.isNotEmpty) {
      try {
        CachePartitions.box('coding_box').put('allowed_branches_$email', effective);
      } catch (e) {
        print('⚠️ save allowed_branches to Hive: $e');
      }
    }

    notifyListeners();
  }

  // ============================================================
  // ✅ معالج تغيير حالة الـ Auth
  //
  // بيتنادى:
  // 1. أول ما الـ listener يتسجل (بالقيمة الحالية)
  // 2. كل مرة المستخدم يعمل login أو logout
  //
  // لو الـ UID اتغير → reset تلقائي + إيقاف Firestore listener
  // ============================================================

  void resetForCachePartition() {
    _resetState();
    _stopFirestoreListener();
  }

  void _onAuthStateChanged(User? user) {
    final newUid = user?.uid ?? '';

    // أول نداء — نحفظ الـ UID الحالي بس، من غير reset
    if (_cachedUid == null) {
      _cachedUid = newUid;
      return;
    }

    // نفس المستخدم — مفيش تغيير
    if (_cachedUid == newUid) {
      return;
    }

    // المستخدم اتغير → reset
    print('🔄 تغيير المستخدم: $_cachedUid → $newUid');
    _cachedUid = newUid;
    if (CachePartitions.enabled && CachePartitions.ownerUid != newUid) CachePartitions.suspend();
    _resetState();
    _stopFirestoreListener();                          // ← NEW
    notifyListeners();                                 // ← NEW
  }

  // ============================================================
  // ✅ Firestore snapshot listener — مزامنة لحظية للصلاحيات
  //
  // بيتسجل مرة واحدة بعد تحميل الصلاحيات من Hive.
  // أي تغيير في users/{email} → تحديث _permissions + Hive + UI
  //
  // ✅ NEW: بيفحص is_active — لو المستخدم محظور، بيسجله خروج فورًا
  // ============================================================

  /// يُستدعى عند تضييق نطاق الصلاحيات ليطلب resync كامل
  /// (تعينه main.dart على _forceFullResync).
  void Function()? onScopeNarrowed;

  void _startFirestoreListener(String email) {
    if (_listenedEmail == email && _firestoreSub != null) return;

    _firestoreSub?.cancel();
    _firestoreSub = null;
    _listenedEmail = email;

    print('🎧 بدء الاستماع لصلاحيات $email');
    Map<String, dynamic>? lastObservedScope;

    final listenerUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final listenerGeneration = CachePartitions.generation;
    _firestoreSub = FirebaseFirestore.instance
        .collection('users')
        .doc(email)
        .snapshots()
        .listen(
      (snapshot) async {
        if (!CachePartitions.boundWorkIsCurrent) return;
        if (await handleOwnDocumentAbsence(
            exists: snapshot.exists,
            fromCache: snapshot.metadata.isFromCache,
            uid: listenerUid,
            email: email,
            generation: listenerGeneration)) return;
        if (!snapshot.exists) return;
        final data = snapshot.data();
        if (data == null) return;

        // لقطة سابقة لمقارنة النطاق بعد التطبيق (دورة حياة السحب)
        final prevPerms = _permissions == null
            ? null
            : Map<String, dynamic>.from(_permissions!);
        final prevBranches = _allowedBranchCodes == null
            ? null
            : List<String>.from(_allowedBranchCodes!);
        final prevViewable = _hrViewableEmployees == null
            ? null
            : List<String>.from(_hrViewableEmployees!);

        // ============================================================
        // ✅ NEW: فحص is_active — لو محظور، نسجله خروج فورًا
        //
        // بيحصل لما:
        // - الأدمن يحظر المستخدم وهو داخل
        // - المستخدم يفتح التطبيق بعد ما اتحظر
        //
        // الحماية في login() بتمنع الدخول الجديد،
        // ودي بتمنع الاستمرار لو محظور أثناء الاستخدام.
        // ============================================================
        if (data['is_active'] == false) {
          ReadAuthorizationEpoch.invalidate();
          print('🚫 تم إيقاف حساب $email من الإدارة — جاري تسجيل الخروج');
          _stopFirestoreListener();
          FirebaseAuth.instance.signOut();
          return;
        }

        if (_scopeVerificationPending || _companyPolicyActive || CachePartitions.box('coding_box').containsKey(
            EffectiveProfileSnapshot.cacheKey(FirebaseAuth.instance.currentUser?.uid ?? '', _cachedPrefs?.getString('company_code') ?? ''))) {
          final observedScope = <String, dynamic>{
            for (final key in ['role', 'job_code', 'company_code', 'permissions', 'allowed_branches', 'hr_viewable_employees'])
              key: data[key],
          };
          final knownChange = lastObservedScope != null && !const DeepEq().equals(lastObservedScope, observedScope);
          lastObservedScope = Map<String, dynamic>.from(jsonDecode(jsonEncode(observedScope)));
          // A cached startup event is not a newly confirmed revocation. Do not
          // turn ordinary offline opening into an unresolved permission hold.
          if (snapshot.metadata.isFromCache) return;
          unawaited(refreshEffectiveProfile(restrictWhileLoading: knownChange).catchError((Object error) {
            print('⚠️ Effective profile refresh failed: $error');
          }));
          return;
        }
        bool changed = false;

        final permissionsData = data['permissions'];
        if (permissionsData is Map) {
          final newPerms = _convertToPermissionsMap(permissionsData);
          if (!const DeepEq().equals(_permissions, newPerms)) ReadAuthorizationEpoch.invalidate();
          _permissions = newPerms;
          CachePartitions.box('coding_box').put('permissions_$email', newPerms);
          changed = true;
        }

                final branchesData = data['allowed_branches'];
        if (branchesData != null) {
          final newBranches = _parseBranchList(branchesData) ?? ['all'];
          if (!const DeepEq().equals(_allowedBranchCodes, newBranches)) ReadAuthorizationEpoch.invalidate();
          _allowedBranchCodes = newBranches;
          CachePartitions.box('coding_box').put('allowed_branches_$email', newBranches);
          changed = true;
        }

        // ⭐ جديد: متابعة قائمة الموظفين المرئيين في HR
        if (data.containsKey('hr_viewable_employees')) {
          final rawViewable = data['hr_viewable_employees'];
          List<String>? newViewable;
          if (rawViewable == null) {
            newViewable = null;
          } else if (rawViewable is List) {
            newViewable = rawViewable.map((e) => e.toString()).toList();
          }

          if (!const DeepEq().equals(_hrViewableEmployees, newViewable)) ReadAuthorizationEpoch.invalidate();
          _hrViewableEmployees = newViewable;
          final box = CachePartitions.box('coding_box');
          if (newViewable == null) {
            await box.delete('hr_viewable_employees_$email');
          } else {
            await box.put('hr_viewable_employees_$email', newViewable);
          }
          changed = true;
        }

        if (changed) {
          print('⚡ صلاحيات $email اتحدثت لحظيًا من Firestore');
          notifyListeners();

          // دورة حياة السحب: عزل/استعادة scoped بلا حذف
          final companyCode =
              _cachedPrefs?.getString('company_code') ?? '';
          if (companyCode.isNotEmpty) {
            unawaited(RevocationService.instance
                .applyTransition(
                  email: email,
                  companyCode: companyCode,
                  oldPerms: prevPerms,
                  newPerms: _permissions == null
                      ? null
                      : Map<String, dynamic>.from(_permissions!),
                  oldBranches: prevBranches,
                  newBranches: _allowedBranchCodes == null
                      ? null
                      : List<String>.from(_allowedBranchCodes!),
                  oldViewable: prevViewable,
                  newViewable: _hrViewableEmployees == null
                      ? null
                      : List<String>.from(_hrViewableEmployees!),
                  ownerUid: FirebaseAuth.instance.currentUser?.uid,
                )
                .then((needsResync) async {
              // احفظ اللقطة المطبقة كأساس لمسار التحميل من Hive
              final box = CachePartitions.box('coding_box');
              await box.put(
                'permissions_applied_$email',
                _permissions ?? <String, dynamic>{},
              );
              await box.put('branches_applied_$email',
                  _allowedBranchCodes ?? <String>[]);
              await box.put('viewable_applied_$email',
                  _hrViewableEmployees ?? <String>[]);
              _recordScopeSync(prevPerms,_permissions,prevBranches,_allowedBranchCodes,prevViewable,_hrViewableEmployees);
      if (_pendingSyncModules.isNotEmpty) onScopeNarrowed?.call();
            }));
          }
        }
      },
      onError: (e) => print('⚠️ خطأ في listener الصلاحيات: $e'),
    );
  }

  /// Confirmed server deletion only. Cache misses/offline uncertainty are not
  /// deletion proof. Every continuation stays bound to the original account.
  Future<bool> handleOwnDocumentAbsence(
      {required bool exists,
      required bool fromCache,
      required String uid,
      required String email,
      required int generation}) async {
    if (exists || fromCache) return false;
    bool current() =>
        uid.isNotEmpty &&
        FirebaseAuth.instance.currentUser?.uid == uid &&
        _currentUserEmail?.toLowerCase() == email.toLowerCase() &&
        (!CachePartitions.enabled ||
            (CachePartitions.generation == generation &&
                CachePartitions.ownerUid == uid));
    if (!current()) return true;
    final company = _identityCompany ?? '';
    final oldPermissions = _permissions;
    final oldBranches = _allowedBranchCodes;
    final oldEmployees = _hrViewableEmployees;
    _scopeVerificationPending = true;
    _loaded = false;
    _serverScopeGeneration++;
    ReadAuthorizationEpoch.invalidate();
    _stopFirestoreListener();
    notifyListeners();
    try {
      await RevocationService.instance.applyTransition(
          email: email,
          companyCode: company,
          ownerUid: uid,
          oldPerms: oldPermissions,
          newPerms: null,
          oldBranches: oldBranches,
          newBranches: const [],
          oldViewable: oldEmployees,
          newViewable: const []);
      if (!current()) return true;
      // Forget disposable display and permission snapshots, not unsent work.
      // Partition proxies reject every late write after an account switch.
      for (final name in CachePartitions.boxes.where((name) => !const {
        'commercial_pending_box', 'hr_pending_box',
        'journal_save_intents_box', 'journal_import_batches_box'
      }.contains(name))) {
        if (!current()) return true;
        if (CachePartitions.isBoxOpen(name)) {
          await CachePartitions.box(name).clear();
        }
      }
    } catch (error) {
      // A disk/cleanup failure never restores a deleted account's access.
      debugPrint('Deleted account cache cleanup incomplete: $error');
    }
    if (!current()) return true;
    final prefs = await SharedPreferences.getInstance();
    if (!current()) return true;
    for (final key in const [
      'remember_me',
      'saved_email',
      'saved_password',
      'user_name',
      'company_name',
      'company_code',
      'job_code',
      'job_title',
      'user_email'
    ]) {
      await prefs.remove(key);
      if (!current()) return true;
    }
    _resetState();
    CachePartitions.suspend();
    await FirebaseAuth.instance.signOut();
    if (FirebaseAuth.instance.currentUser == null) onOwnAccountDeleted?.call();
    return true;
  }

  void Function()? onOwnAccountDeleted;

  void _stopFirestoreListener() {
    _firestoreSub?.cancel();
    _firestoreSub = null;
    _listenedEmail = null;
    _stopEmployeesHiveListener();
    print('🔌 إيقاف الاستماع للصلاحيات');
  }
  // ============================================================
  // ⭐ Hive Listener: إعادة حساب _currentEmployeeCode
  //
  // السبب: main.dart بينادي loadPermissions قبل sync،
  // فـ employees مش موجودة في Hive وقت أول حساب.
  //
  // لما employees تتحمل من السيرفر، Hive بيبعت event،
  // فبنعيد الحساب تلقائياً.
  // ============================================================

  void _startEmployeesHiveListener() {
    if (_employeesHiveSub != null) return;

    try {
      _employeesHiveSub = CachePartitions.box('coding_box')
          .watch()
          .listen((event) {
        final key = event.key?.toString() ?? '';

        // نستمع فقط لتغييرات employees
        if (!key.endsWith('_employees')) return;

        print('📦 [Hive] employees تحدثت → إعادة حساب employee_code');

        final previousCode = _currentEmployeeCode;
        _currentEmployeeCode = null;  // ⭐ نعيد الحساب من الأول
        _tryComputeCurrentEmployeeCode();

        // لو حصل ربط جديد، أعلم المستمعين
        if (previousCode != _currentEmployeeCode) {
          if (previousCode != null) ReadAuthorizationEpoch.invalidate();
          print('🎉 تم ربط الحساب بموظف: $_currentEmployeeCode');
          notifyListeners();
          final company = _cachedPrefs?.getString('company_code') ?? '';
          final uid = FirebaseAuth.instance.currentUser?.uid;
          if (company.isNotEmpty && company == _identityCompany && uid == _identityProfileUid) {
            unawaited(RevocationService.instance.applyTransition(
              email: _currentUserEmail ?? '', companyCode: company, ownerUid: uid,
              oldPerms: _permissions, newPerms: _permissions,
              oldBranches: _allowedBranchCodes, newBranches: _allowedBranchCodes,
              oldViewable: _hrViewableEmployees, newViewable: _hrViewableEmployees,
            ).then((changed) { if (changed) onScopeNarrowed?.call(); }).catchError((Object error) {
              print('⚠️ HR identity cache cleanup failed: $error');
            }));
          }
        }
      });
    } catch (e) {
      print('⚠️ فشل تسجيل Hive listener: $e');
    }
  }

  void _stopEmployeesHiveListener() {
    _employeesHiveSub?.cancel();
    _employeesHiveSub = null;
  }
  // ============================================================
  // تصفير الحالة الداخلية (بدون لمس _cachedUid)
  // ============================================================

  void _resetState() {
    _targetCache.clear();
    ReadAuthorizationEpoch.invalidate();
    _loadFuture = null;
    _loaded = false;
    _permissions = null;
    _allowedBranchCodes = null;
    _defaultBranchCode = null;
    _hrViewableEmployees = null;
    _currentEmployeeCode = null;
    _identityProfileUid = null;
    _identityCompany = null;
    _currentUserEmail = null;
    _cachedPrefs = null;
    _currentRole = null;   // ⭐
    _companyPolicyActive = false;
    _scopeVerificationPending = false;
    _delegablePermissions = {};
    _delegableBranchCodes = [];
    _serverScopeGeneration++;
    _serverRefresh = null;
    _pendingSyncModules.clear();
    _stopEmployeesHiveListener();
  }

  // ============================================================
  // تحميل الصلاحيات (idempotent)
  //
  // ✅ لو اتنادت مرة، كل النداءات التالية بترجع نفس الـ Future
  // ✅ لو عايز إعادة تحميل، استخدم refresh()
  //
  // 1) نقرأ من Hive فوراً
  // 2) ثم نحدث من Firestore + نبدأ snapshot listener
  // ============================================================

  Future<void> loadPermissions() {
    return _loadFuture ??= _doLoadPermissions();
  }

  /// Refresh current own scope from the authenticated server. Known scope
  /// changes stay held if verification fails; startup can retain offline scope.
  Future<void> refreshEffectiveProfile({bool restrictWhileLoading = true}) async {
return CachePartitions.run(() async {

    if (_serverRefresh != null && !restrictWhileLoading) return _serverRefresh!;
    if (restrictWhileLoading) {
      _scopeVerificationPending = true;
      _loaded = false;
      _serverScopeGeneration++;
      ReadAuthorizationEpoch.invalidate();
      notifyListeners();
    }
    final generation = _serverScopeGeneration;
    final token = '${DateTime.now().microsecondsSinceEpoch}:$generation';
    final requested = await ReadAuthorizationSnapshot.capture();
    final initialPrefs = await CachePartitions.preferences();
    requested.check();
    final initialUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final initialCompany = initialPrefs.getString('company_code') ?? '';
    final pendingKey = EffectiveProfileSnapshot.pendingKey(initialUid, initialCompany);
    if (restrictWhileLoading) {
      await CachePartitions.box('coding_box').put(pendingKey, token);
      requested.check();
    }
    final previous = _serverRefresh;
    final work = () async {
      try { await previous; } catch (_) {}
      if (!requested.sameContext || generation != _serverScopeGeneration) throw const ReadAuthorizationChanged();
      final prefs = await CachePartitions.preferences();
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final email = (prefs.getString('user_email') ?? '').trim().toLowerCase();
      final company = prefs.getString('company_code') ?? '';
      final request = await ReadAuthorizationSnapshot.capture();
      final raw = await ApiService().getEffectiveProfile();
      request.check();
      final profile = EffectiveProfileSnapshot.parse(raw, uid: uid, email: email, company: company);
      final box = CachePartitions.box('coding_box');
      _scopeVerificationPending = true;
      _loaded = false;
      notifyListeners();
      if (!restrictWhileLoading) await box.put(pendingKey, token);
      request.check();
      if (generation != _serverScopeGeneration) throw const ReadAuthorizationChanged();
      EffectiveProfileSnapshot? prior;
      if(_permissions==null) {
        try { prior=EffectiveProfileSnapshot.parse(box.get(EffectiveProfileSnapshot.cacheKey(uid,company)),uid:uid,email:email,company:company); }
        catch(_) { /* Unknown identity/scope is not borrowed from another user. */ }
      }
      Map<String,dynamic>? priorPermissions=prior?.permissions;
      if(prior!=null && !prior.active){
        priorPermissions=_convertToPermissionsMap(prior.permissions);
        final defaults=_createDefaultPermissions(prior.data['job_code']?.toString() ?? '1',forVerifiedProfile:true);
        defaults.forEach((category,entries){
          priorPermissions!.putIfAbsent(category,()=> <String,bool>{});
          entries.forEach((key,value)=>(priorPermissions![category] as Map).putIfAbsent(key,()=>value));
        });
      }
      final oldPerms = _permissions == null ? priorPermissions : Map<String, dynamic>.from(_permissions!);
      final oldBranches = _allowedBranchCodes == null ? (prior?.data['allowed_branches'] as List?)?.cast<String>() : List<String>.from(_allowedBranchCodes!);
      final oldViewable = _hrViewableEmployees == null ? (prior?.data['hr_viewable_employees'] as List?)?.cast<String>() : List<String>.from(_hrViewableEmployees!);
      _companyPolicyActive = profile.active;
      _currentRole = profile.role;
      _delegablePermissions = Map<String, dynamic>.from(profile.data['delegable_permissions'] ?? {});
      _delegableBranchCodes = List<String>.from(profile.data['delegable_branches'] ?? []);
      final next = _convertToPermissionsMap(profile.permissions);
      if (!profile.active) {
        final defaults = _createDefaultPermissions(profile.data['job_code']?.toString() ?? '1', forVerifiedProfile: true);
        defaults.forEach((category, entries) {
          next.putIfAbsent(category, () => {});
          entries.forEach((key, value) => next[category]!.putIfAbsent(key, () => value));
        });
      }
      _permissions = next;
      _allowedBranchCodes = (profile.data['allowed_branches'] as List).cast<String>().toList();
      _hrViewableEmployees = (profile.data['hr_viewable_employees'] as List?)?.cast<String>().toList();
      _cachedPrefs = prefs;
      _identityCompany = company;
      _identityProfileUid = uid;
      _currentUserEmail = email;
      _tryComputeCurrentEmployeeCode();
      ReadAuthorizationEpoch.invalidate();
      final applied = await ReadAuthorizationSnapshot.capture();
      bool appliedCurrent() => applied.isCurrent && generation == _serverScopeGeneration;
      Future<Never> invalidateApplied() async {
return CachePartitions.run(() async {

        if (box.get(pendingKey) == token) await box.put(pendingKey, 'invalid:$token');
        throw const ReadAuthorizationChanged();
});
}
      await RevocationService.instance.applyTransition(
        email: email, companyCode: company, oldPerms: oldPerms, newPerms: next,
        oldBranches: oldBranches, newBranches: _allowedBranchCodes,
        oldViewable: oldViewable, newViewable: _hrViewableEmployees, ownerUid: uid,
      );
      if (!appliedCurrent()) await invalidateApplied();
      await box.putAll({
        EffectiveProfileSnapshot.cacheKey(uid, company): {...profile.data, '_verification_token': token},
        'permissions_applied_$email': next,
        'branches_applied_$email': _allowedBranchCodes ?? <String>[],
        'viewable_applied_$email': _hrViewableEmployees ?? <String>[],
      });
      if (!appliedCurrent()) await invalidateApplied();
      _scopeVerificationPending = false;
      _loaded = true;
      notifyListeners();
      _recordScopeSync(oldPerms,next,oldBranches,_allowedBranchCodes,oldViewable,_hrViewableEmployees);
      if (_pendingSyncModules.isNotEmpty) onScopeNarrowed?.call();
    }();
    _serverRefresh = work;
    try { await work; } finally {
      if (identical(_serverRefresh, work)) _serverRefresh = null;
    }
});
}

  /// إعادة تحميل الصلاحيات
  Future<void> refresh() {
    _loadFuture = null;
    _loaded = false;
    return loadPermissions();
  }

  /// إعادة تعيين الحالة يدويًا (اختياري — الـ listener بيعملها تلقائيًا)
    void reset() {
    _resetState();
    _stopFirestoreListener();
    _cachedUid = null;
    _currentUserEmail = null;   // ⭐
    _cachedPrefs = null;        // ⭐
    notifyListeners();
  }

  // ============================================================
  // التنفيذ الفعلي للتحميل (private)
  // ============================================================

  Future<void> _doLoadPermissions() async {
return CachePartitions.run(() async {

    ReadAuthorizationEpoch.invalidate();
    final identityUid = FirebaseAuth.instance.currentUser?.uid;
    try {
      final prefs = await CachePartitions.preferences();

      final email =
          prefs.getString('user_email') ?? '';

      final jobCode =
          prefs.getString('job_code') ?? '1';

      // ⭐ اقرأ role من prefs (بيتحفظ وقت login)
      final role = prefs.getString('role');
      _currentRole = (role != null && role.isNotEmpty) ? role : null;

      if (email.isEmpty) {
        print(
          '⚠️ PermissionsService: user_email غير موجود',
        );
        _loaded = true;
        notifyListeners();                             // ← NEW
        return;
      }

      final box =
          CachePartitions.box('coding_box');

      EffectiveProfileSnapshot? cachedEffective;
      final effectiveKey = EffectiveProfileSnapshot.cacheKey(identityUid ?? '', prefs.getString('company_code') ?? '');
      final effectiveRaw = box.get(effectiveKey);
      final pendingToken = box.get(EffectiveProfileSnapshot.pendingKey(identityUid ?? '', prefs.getString('company_code') ?? ''));
      _scopeVerificationPending = pendingToken != null &&
          (effectiveRaw is! Map || effectiveRaw['_verification_token'] != pendingToken);
      if (effectiveRaw != null) {
        try {
          cachedEffective = EffectiveProfileSnapshot.parse(effectiveRaw,
            uid: identityUid ?? '', email: email, company: prefs.getString('company_code') ?? '');
          _companyPolicyActive = cachedEffective.active;
          _currentRole = cachedEffective.role;
          _delegablePermissions = Map<String, dynamic>.from(cachedEffective.data['delegable_permissions'] ?? {});
          _delegableBranchCodes = List<String>.from(cachedEffective.data['delegable_branches'] ?? []);
        } catch (_) {
          _scopeVerificationPending = true;
          _permissions = {};
        }
      }
      final permissionsKey =
          'permissions_$email';

      final branchesKey =
          'allowed_branches_$email';

      // ----------------------------------------------------------
      // الصلاحيات المحلية
      // ----------------------------------------------------------

            final localPermissions = cachedEffective?.data['permissions'] ?? box.get(permissionsKey);

      if (localPermissions is Map) {
        // ⭐ دمج: قيم Hive + القيم الافتراضية للمفاتيح الناقصة
        final fromHive = _convertToPermissionsMap(localPermissions);
        final defaults = _createDefaultPermissions(jobCode);

        defaults.forEach((category, perms) {
          fromHive.putIfAbsent(category, () => {});
          perms.forEach((key, defaultValue) {
            fromHive[category]!.putIfAbsent(key, () => defaultValue);
          });
        });

        _permissions = fromHive;
      } else {
        _permissions =
            _createDefaultPermissions(
          jobCode,
        );
      }

      // ⭐ لو مفيش role محفوظ، احسبه من jobCode
      if (_currentRole == null || _currentRole!.isEmpty) {
        if (jobCode == '99') {
          _currentRole = 'super_admin';
        } else if (jobCode == '201') {
          _currentRole = 'admin';
        } else {
          _currentRole = 'employee';
        }
      }

            // ----------------------------------------------------------
      // الفروع المحلية
      // ----------------------------------------------------------

      final localBranches = cachedEffective?.data['allowed_branches'] ?? box.get(branchesKey);

      if (localBranches is List) {
        _allowedBranchCodes =
            localBranches
                .map((e) => e.toString())
                .toList();
      } else {
        _allowedBranchCodes = ['all'];
      }

            // ----------------------------------------------------------
      // ⭐ جديد: الموظفين المرئيين في HR
      // ----------------------------------------------------------

      final localViewableEmps =
          cachedEffective != null ? cachedEffective.data['hr_viewable_employees'] : box.get('hr_viewable_employees_$email');

      if (localViewableEmps is List) {
        _hrViewableEmployees = localViewableEmps
            .map((e) => e.toString())
            .toList();
      } else {
        _hrViewableEmployees = null;  // كل الموظفين
      }

            // ----------------------------------------------------------
      // ⭐ جديد: كود الموظف الحالي (لو مربوط بحساب Firebase)
      // ----------------------------------------------------------
      _currentUserEmail = email;
      _identityProfileUid = identityUid;
      _identityCompany = prefs.getString('company_code') ?? '';
      _cachedPrefs = prefs;
      _currentEmployeeCode = null;

      _tryComputeCurrentEmployeeCode();

      print(
        '⚡ تم تحميل الصلاحيات والفروع والموظفين المرئيين من Hive',
      );
      if (_currentEmployeeCode != null) {
        print('👤 الموظف المرتبط بالحساب: $_currentEmployeeCode');
      } else {
        print('⚠️ الحساب مش مربوط بموظف (user_email: $email)');
      }

      // ✅ الصلاحيات جاهزة من Hive
      _loaded = true;
      notifyListeners();                               // ← NEW

      // دورة حياة السحب من مسار التحميل أيضاً (يغطي تحديث
      // الـ WS الذي يقرأ من Hive حتى لو listener معطل).
      // prev = آخر لقطة مطبقة محفوظة، والحالية = المحمّلة الآن.
      {
        final transitionCompany =
            _cachedPrefs?.getString('company_code') ?? '';
        if (transitionCompany.isNotEmpty) {
          final prevSnapshot = CachePartitions.box('coding_box')
              .get('permissions_applied_$email');
          final prevPerms = prevSnapshot is Map
              ? Map<String, dynamic>.from(prevSnapshot)
              : null;
          final prevBranchesRaw =
              CachePartitions.box('coding_box').get('branches_applied_$email');
          final prevBranches = prevBranchesRaw is List
              ? prevBranchesRaw.map((e) => e.toString()).toList()
              : null;
          final prevViewableRaw = CachePartitions.box('coding_box')
              .get('viewable_applied_$email');
          final prevViewable = prevViewableRaw is List
              ? prevViewableRaw.map((e) => e.toString()).toList()
              : null;
          final nowPerms = _permissions == null
              ? null
              : Map<String, dynamic>.from(_permissions!);
          unawaited(RevocationService.instance
              .applyTransition(
                email: email,
                companyCode: transitionCompany,
                oldPerms: prevPerms,
                newPerms: nowPerms,
                oldBranches: prevBranches,
                newBranches: _allowedBranchCodes == null
                    ? null
                    : List<String>.from(_allowedBranchCodes!),
                oldViewable: prevViewable,
                newViewable: _hrViewableEmployees == null
                    ? null
                    : List<String>.from(_hrViewableEmployees!),
                ownerUid: FirebaseAuth.instance.currentUser?.uid,
              )
              .then((needsResync) async {
            final box = CachePartitions.box('coding_box');
            await box.put(
                'permissions_applied_$email', nowPerms ?? {});
            await box.put('branches_applied_$email',
                _allowedBranchCodes ?? <String>[]);
            await box.put('viewable_applied_$email',
                _hrViewableEmployees ?? <String>[]);
            _recordScopeSync(prevPerms,nowPerms,prevBranches,_allowedBranchCodes,prevViewable,_hrViewableEmployees);
            if (_pendingSyncModules.isNotEmpty) onScopeNarrowed?.call();
          }));
        }
      }

      // ----------------------------------------------------------
      // تحديث Firestore في الخلفية + بدء snapshot listener
      // ----------------------------------------------------------

            // _refreshFromFirestore(
      //   email,
      //   permissionsKey,
      //   branchesKey,
      // );
      _startFirestoreListener(email);

      // ⭐ الاستماع لتغييرات Hive لإعادة حساب employee_code
      // (لأن employees ممكن تتحمل بعد loadPermissions)
      _startEmployeesHiveListener();

    } catch (e) {
      if (!CachePartitions.boundWorkIsCurrent) rethrow;
      print(
        '❌ خطأ في loadPermissions: $e',
      );

      if (_permissions == null) {
        final prefs =
            await SharedPreferences
                .getInstance();

        CachePartitions.checkBoundWork();
        final jobCode =
            prefs.getString('job_code') ?? '1';

        _permissions =
            _createDefaultPermissions(
          jobCode,
        );

        _allowedBranchCodes = ['all'];
      }

      // ✅ حتى في حالة الخطأ، نعتبرها محملة (بالـ defaults)
      _loaded = true;
      notifyListeners();                               // ← NEW
    }
});
}

    // ============================================================
  // ⭐ Helper: تطبيع الكود (trim + إزالة المسافات)
  // ============================================================

  String _normalizeCode(String code) => code.trim();




  // ============================================================
  // ⭐ Helper: محاولة حساب _currentEmployeeCode من Hive
  //
  // بتتنادى:
  // 1. من _doLoadPermissions (مرة واحدة)
  // 2. من isCurrentEmployee() لو _currentEmployeeCode لسه null
  //
  // الفايدة:
  // - لو employees لسه ما اتحملوش وقت loadPermissions، هيتحسب لاحقاً
  // - لو user_email اتحط بعد التطبيق ما اشتغل، هيتحسب عند أول check
  // ============================================================

  void _tryComputeCurrentEmployeeCode() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty || uid != _identityProfileUid || _cachedPrefs == null) {
      _currentEmployeeCode = null;
      return;
    }
    final company = _cachedPrefs!.getString('company_code') ?? '';
    if (_identityCompany != company) {
      _currentEmployeeCode = null;
      return;
    }
    if (_currentEmployeeCode != null || company.isEmpty || !CachePartitions.isBoxOpen('coding_box')) return;
    final rows = CachePartitions.box('coding_box').get('${company}_employees');
    if (rows is! List) return;
    _currentEmployeeCode = EmployeeIdentity.resolveCode(rows, uid: uid,
        email: FirebaseAuth.instance.currentUser?.email ?? '');
  }

  @visibleForTesting
  void debugSetIdentityForTest({required String email, required SharedPreferences prefs}) {
    _identityProfileUid = FirebaseAuth.instance.currentUser?.uid;
    _currentUserEmail = email;
    _cachedPrefs = CachePreferences(prefs, null);
    _currentEmployeeCode = null;
    _identityCompany = prefs.getString('company_code') ?? '';
    _startEmployeesHiveListener();
  }


  // ============================================================
  // تحديث أولي من Firestore (بيتنفذ مرة واحدة مع التحميل)
  // ============================================================
  // ============================================================
  // تحديث أولي من Firestore (بيتنفذ مرة واحدة مع التحميل)
  // ============================================================

  // Future<void> _refreshFromFirestore(
  //   String email,
  //   String permissionsKey,
  //   String branchesKey,
  // ) async {
  //   try {
  //     final box =
  //         CachePartitions.box('coding_box');

  //     final doc =
  //         await FirebaseFirestore.instance
  //             .collection('users')
  //             .doc(email)
  //             .get();

  //     if (!doc.exists) {
  //       return;
  //     }

  //     final data =
  //         doc.data();

  //     if (data == null) {
  //       return;
  //     }

  //     // ----------------------------------------------------------
  //     // الصلاحيات
  //     // ----------------------------------------------------------

  //     final permissionsData =
  //         data['permissions'];

  //     if (permissionsData is Map) {
  //       final newPermissions =
  //           _convertToPermissionsMap(
  //         permissionsData,
  //       );

  //       _permissions =
  //           newPermissions;

  //       await box.put(
  //         permissionsKey,
  //         newPermissions,
  //       );
  //     }

  //     // ----------------------------------------------------------
  //     // الفروع
  //     // ----------------------------------------------------------

  //     final branches =
  //         _parseBranchList(
  //       data['allowed_branches'],
  //     );

  //     if (branches != null) {
  //       _allowedBranchCodes =
  //           branches;

  //       await box.put(
  //         branchesKey,
  //         branches,
  //       );
  //     }

  //     print(
  //       '🔄 تم تحديث الصلاحيات والفروع من Firestore',
  //     );
  //     notifyListeners();                               // ← NEW
  //   } catch (e) {
  //     print(
  //       '⚠️ فشل تحديث الصلاحيات من Firestore: $e',
  //     );
  //   }
  // }

  // ============================================================
  // تحليل قائمة الفروع
  // ============================================================

  List<String>? _parseBranchList(
    dynamic data,
  ) {
    if (data == null) {
      return null;
    }

    if (data is String &&
        data.toLowerCase() == 'all') {
      return ['all'];
    }

    if (data is List) {
      return data
          .map((e) => e.toString())
          .toList();
    }

    return null;
  }

  // ============================================================
  // Getters - الفروع
  // ============================================================

  List<String>? get allowedBranches =>
      _allowedBranchCodes;

  String? get defaultBranch =>
      _defaultBranchCode;

  bool hasSingleBranch() {
    if (_allowedBranchCodes == null) {
      return false;
    }

    if (_allowedBranchCodes!.contains('all')) {
      return false;
    }

    return _allowedBranchCodes!.length == 1;
  }

  bool canAccessBranch(
    String branchCode,
  ) {
    if (_scopeVerificationPending) return false;
    if (_allowedBranchCodes == null) {
      return true;
    }

    if (_allowedBranchCodes!.contains('all')) {
      return true;
    }

    return _allowedBranchCodes!.contains(
      branchCode,
    );
  }

  // ============================================================
  // حفظ الصلاحيات
  // ============================================================

  final Map<String, ({PermissionTargetDirectory data, int revision})> _targetCache = {};
  Future<PermissionTargetDirectory> loadPermissionTargets(
      String companyCode, {bool forceRefresh = false}) async {
return CachePartitions.run(() async {

    final cached = _targetCache[companyCode];
    final revision = AdminCacheEvents.users.value.revision;
    if (!forceRefresh && cached != null && cached.revision == revision && cached.data.readScope.isCurrent) return cached.data;
    final scope = await ReadAuthorizationSnapshot.capture();
    final value = await ApiService().getPermissionTargets(companyCode);
    scope.check();
    if (value['company_code'] != companyCode || value['users'] is! List)
      throw const FormatException('Invalid permission target scope');
    const fields = {
      'email',
      'uid',
      'name',
      'company_code',
      'company_name',
      'job_code',
      'job_title',
      'role',
      'status',
      'is_active'
    };
    final users = <Map<String, dynamic>>[];
    for (final raw in value['users']) {
      if (raw is! Map ||
          raw['email'] is! String ||
          (raw['email'] as String).isEmpty ||
          raw['uid'] is! String ||
          raw['name'] is! String ||
          raw['role'] is! String ||
          (companyCode.isNotEmpty && raw['company_code'] != companyCode)) {
        throw const FormatException('Invalid permission target record');
      }
      users.add({
        for (final key in fields)
          if (raw.containsKey(key)) key: raw[key]
      });
    }
    scope.check();
    if (revision != AdminCacheEvents.users.value.revision) throw const ReadAuthorizationChanged();
    final result = PermissionTargetDirectory(companyCode, users, scope);
    _targetCache[companyCode] = (data: result, revision: revision);
    return result;
});
}

  Future<PermissionEditorSnapshot> loadPermissionEditor(String email) async {
return CachePartitions.run(() async {

    final scope=await ReadAuthorizationSnapshot.capture();
    final value=await ApiService().getPermissionEditor(email);
    scope.check();
    final result=PermissionEditorSnapshot.fromJson(value);
    if(result.email!=email.trim().toLowerCase()) throw const FormatException('Permission editor identity mismatch');
    return result.withReadScope(scope);
});
}

  Future<void> savePermissions(
    Map<String, Map<String, bool>> permissions, {
    String? targetEmail,
    List<String>? allowedBranches,
    List<String>? hrViewableEmployees,
    bool clearHrViewableEmployees = false,
    String? expectedTargetUid,
    String? expectedProfileVersion,
    int? expectedPolicyRevision,
    String? startupBranchCode,
  }) async {
return CachePartitions.run(() async {

    final scope = await ReadAuthorizationSnapshot.capture();
    final prefs = await CachePartitions.preferences();
    final email = (targetEmail ?? prefs.getString('user_email') ?? '').trim().toLowerCase();
    if (email.isEmpty) throw StateError('No target account for permission save');
    final submitted = permissions.map((category, values) => MapEntry(category, Map<String, bool>.from(values)));
    final branches = allowedBranches == null ? null : List<String>.from(allowedBranches);
    final employees = hrViewableEmployees == null ? null : List<String>.from(hrViewableEmployees);
    try {
      scope.check();
      await ApiService().updatePermissions(
        email, submitted, allowedBranches: branches,
        hrViewableEmployees: employees,
        clearHrViewableEmployees: clearHrViewableEmployees,
        expectedTargetUid: expectedTargetUid,
        expectedProfileVersion: expectedProfileVersion,
        expectedPolicyRevision: expectedPolicyRevision,
        startupBranchCode: startupBranchCode,
      );
      // The server has acknowledged a commit. A changed account/scope must
      // not receive its stale clean-cache state, or a false failed-save result.
      if (!scope.isCurrent) return;
      final box = CachePartitions.box('coding_box');
      await box.put('permissions_$email', submitted);
      if (!scope.isCurrent) return;
      if (branches != null) {
        await box.put('allowed_branches_$email', branches);
        if (!scope.isCurrent) return;
      }
      if (clearHrViewableEmployees) {
        await box.delete('hr_viewable_employees_$email');
        if (!scope.isCurrent) return;
      } else if (employees != null) {
        await box.put('hr_viewable_employees_$email', employees);
        if (!scope.isCurrent) return;
      }
      if (email == prefs.getString('user_email')?.trim().toLowerCase()) {
        ReadAuthorizationEpoch.invalidate();
        _permissions = submitted;
        if (branches != null) _allowedBranchCodes = branches;
        if (clearHrViewableEmployees) {
          _hrViewableEmployees = null;
        } else if (employees != null) {
          _hrViewableEmployees = employees;
        }
        notifyListeners();
      }
    } catch (e) {
      print('⚠️ فشل حفظ الصلاحيات: $e');
      rethrow;
    }
});
}

  // ============================================================
  // تحويل Map الصلاحيات
  // ============================================================

  Map<String, Map<String, bool>>
      _convertToPermissionsMap(
    dynamic data,
  ) {
    final Map<String, Map<String, bool>>
        converted = {};

    if (data is! Map) {
      return converted;
    }

    data.forEach(
      (categoryKey, categoryValue) {
        if (categoryValue is! Map) {
          return;
        }

        final Map<String, bool>
            subMap = {};

        categoryValue.forEach(
          (permKey, permValue) {
            bool value = false;

            if (permValue is bool) {
              value = permValue;
            } else if (permValue is String) {
              value =
                  permValue.toLowerCase() ==
                      'true';
            } else if (permValue is num) {
              value = permValue == 1;
            }

            subMap[
                permKey.toString()] = value;
          },
        );

        converted[
            categoryKey.toString()] = subMap;
      },
    );

    return converted;
  }

  // ============================================================
  // الصلاحيات الافتراضية
  // ============================================================

  Map<String, Map<String, bool>>
      _createDefaultPermissions(
    String jobCode, {bool forVerifiedProfile = false}
  ) {
    // ⭐ لو عندنا role محدث، نستخدمه
    final effectiveRole = _currentRole ??
        (jobCode == '99' ? 'super_admin' : jobCode == '201' ? 'admin' : 'employee');

    final Map<String, Map<String, bool>>
        allPermissions = {
      // ========================================================
      // حركة الخزينة
      // ========================================================

      'حركة الخزينة': {
        'شاشات الارصدة': false,
        'ادخال اذون': false,
        'المعاينة': false,
        'التعديل': false,
        'الحذف': false,
        'استيراد من اكسل': false,
        'تصدير': false,
        'فلترة': false,
      },

      // ========================================================
      // التكويد
      // ========================================================

      'التكويد': {
        'معاينة': false,
        'اضافة صنف': false,
        'سعر الشراء': false,
        'اضافة فرع': false,
        'اضافة خزينة': false,
        'اضافة مورد': false,
        'اضافة مخزن': false,
        'اضافة عملاء': false,
        'اضافة طرق دفع': false,
        'اضافة بنك': false,
        'اضافة موظف': false,
      },

      // ========================================================
      // حسابات الموردين = المشتريات
      // ========================================================

      'حسابات الموردين': {
        'اضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'تصدير': false,
      },

      // ========================================================
      // تسويات الموردين
      // ========================================================

      'تسويات الموردين': {
        'إضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'تصدير': false,
      },

      // ========================================================
      // حركة الجرد
      // ========================================================

      'حركة الجرد': {
        'اضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'استيراد': false,
        'تصدير': false,
      },

      'المبيعات': {
        'إضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'تغيير سعر البيع': false,
        'عرض سعر الجملة': false,
        'طباعة': false,
        'مشاركة': false,
        'تصدير': false,
      },
      'المرتجعات': {
        'إضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'طباعة': false,
      },
      'حسابات العملاء': {
        'معاينة': false,
        'إضافة تحصيل': false,
        'تعديل تحصيل': false,
        'حذف تحصيل': false,
        'عرض الأرصدة': false,
      },
      'التحويلات المخزنية': {
        'إضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'تصدير': false,
      },
      'تحويلات الخزائن': {
        'إضافة': false,
        'معاينة': false,
        'تعديل': false,
        'حذف': false,
      },
      'أرصدة خزائن المبيعات': {
        'معاينة': false,
        'تصدير': false,
      },

      // ========================================================
      // التقارير
      // ========================================================

      'التقارير': {
        'تقرير المبيعات': false,
        'تقرير فترة': false,
        'مشاركة': false,

        'تقرير التدفق النقدي': false,
  'تحليل هيكل المصروفات': false,
  'تحليل المصروفات بالنسبة للمبيعات': false,
  'الربحية الصافية لكل فرع': false,
  'تحليل حجم الفاتورة': false,
  'تحليل الخزائن النقدية': false,
  'الأصناف بطيئة الحركة': false,
  'تحليل دقة الجرد': false,
  'تقييم المخزون و ABC': false,
  'تحليل أداء الموردين': false,
  'تحليل العوائد والخصومات': false,
  'تحليل الاتجاهات الموسمية': false,
  'تحليل هامش الربح الفعلي': false,
  'تحليل تجميع المنتجات': false,
  'التقرير الموسع (صافي الجرد)': false,  // <--- هذا للتقرير الموسع
      },

      // ========================================================
      // رصيد المخزون
      // ========================================================

      'رصيد المخزون': {
        'معاينة': false,
        'عرض سعر الجملة': false,
        'تصدير': false,
      },

      // ========================================================
      // الصلاحيات العامة
      // ========================================================

      'صلاحيات عامة': {
        'تغيير الفرع(صفحة الهوم)': false,
        'صفحة الصلاحيات(الاعدادات)': false,
        'إظهار حركة الخزينة': false,
        'إظهار التكويد': true,
        'إظهار التقارير': false,
        'إظهار حركة الموردين': false,
        'إظهار حركة الجرد': false,
        'إظهار الإشعارات': false,
        'إظهار البحث عن المنتجات': false,
        'إظهار المستخدمين المتصلين': false,
        'إظهار الموارد البشرية': false,
      },

           // ========================================================
      // الموارد البشرية (HR) — نظام جديد (21 صلاحية)
      // ========================================================
      'الموارد البشرية': {
        // ─── A. فتح الصفحات (3) ───
        'canOpenAttendancePage': false,
        'canOpenVacationsPage': false,
        'canOpenReportPage': false,

        // ─── B. عمليات الحضور (3) ───
        'canAddAttendance': false,
        'canEditAttendance': false,
        'canDeleteAttendance': false,

        // ─── C. عمليات الإجازات (3) ───
        'canAddVacation': false,
        'canEditVacation': false,
        'canDeleteVacation': false,

        // ─── D. التسويات (5) ───
        'canViewAdjustments': false,
        'canAddBonus': false,
        'canAddLoan': false,
        'canEditAdjustment': false,
        'canDeleteAdjustment': false,

        // ─── E. الإعدادات (3) ───
        'canEditWeeklyDay': false,
        'canEditWorkSchedule': false,
        'canEditDelayRules': false,

                // ─── F. الخصم والراتب (3) ───
        'canAddDirectDiscount': false,
        'canViewSalaryAmounts': false,
        'canExportReport': false,

                // ─── G. إدارة الموظفين (2) ───
        'canViewEmployees': false,
        'canManageEmployees': false,

               // ─── H. الموظف يشوف بياناته (1) ───
        'canViewOwnHRData': false,

        // ─── I. التقارير المجمعة (1) ⭐ جديد ───
        'canViewBranchSalaryReport': false,
      },
    };

    // ==========================================================
    // super_admin + admin → كل شيء مفتوح
    // ==========================================================

    if (_companyPolicyActive || (_scopeVerificationPending && !forVerifiedProfile)) {
      for (final entries in allPermissions.values) {
        for (final key in entries.keys.toList()) { entries[key] = false; }
      }
    }
    if ((!_scopeVerificationPending || forVerifiedProfile) && (effectiveRole == 'super_admin' || (effectiveRole == 'admin' && !_companyPolicyActive))) {
      for (final category in allPermissions.keys) {
        for (final permission in allPermissions[category]!.keys) {
          allPermissions[category]![permission] = true;
        }
      }
    } else if (!_companyPolicyActive && (!_scopeVerificationPending || forVerifiedProfile)) {
      // ⭐ employee → Sandbox: كل "إظهار X" = true، داخلي = false
      final globalPerms = allPermissions['صلاحيات عامة']!;
      globalPerms['إظهار حركة الخزينة'] = true;
      globalPerms['إظهار التكويد'] = true;
      globalPerms['إظهار التقارير'] = true;
      globalPerms['إظهار حركة الموردين'] = true;
      globalPerms['إظهار حركة الجرد'] = true;
      globalPerms['إظهار الإشعارات'] = true;
      globalPerms['إظهار البحث عن المنتجات'] = true;
      globalPerms['إظهار الموارد البشرية'] = true;

      // HR: يرى صفحته فقط
      final hrPerms = allPermissions['الموارد البشرية']!;
      hrPerms['canViewOwnHRData'] = true;
    }

    return allPermissions;
  }

  // ============================================================
  // فحص صلاحية عامة
  // ============================================================

  bool hasPermission(
    String category,
    String permission,
  ) {
    return !_scopeVerificationPending && PermissionHierarchy.allows(_permissions, category, permission);
  }

  /// منفذ اختبارات فقط: يثبّت خريطة صلاحيات ودوراً بدون
  /// Firestore/شبكة. لا يُستدعى من كود التطبيق.
  @visibleForTesting
  void debugSetPermissionsForTest(
    Map<String, dynamic>? perms, {
    String? role,
    bool? loaded,
    bool companyPolicyActive = false,
    List<String>? branches,
    List<String>? viewableEmployees,
  }) {
    ReadAuthorizationEpoch.invalidate();
    _permissions = perms?.map(
      (k, v) => MapEntry(
        k,
        (v as Map).map(
          (k2, v2) => MapEntry(k2.toString(), v2 == true),
        ),
      ),
    );
    _companyPolicyActive = companyPolicyActive;
    _scopeVerificationPending = false;
    if (loaded != null) _loaded = loaded;
    if (role != null) _currentRole = role;
    if (branches != null) _allowedBranchCodes = branches;
    if (viewableEmployees != null) {
      _hrViewableEmployees = viewableEmployees;
    }
  }

  // ============================================================
  // حركة الخزينة
  // ============================================================

  bool get canViewBalances =>
      hasPermission(
        'حركة الخزينة',
        'شاشات الارصدة',
      );

  bool get canAddTransaction =>
      hasPermission(
        'حركة الخزينة',
        'ادخال اذون',
      );

  bool get canViewTransactions =>
      hasPermission(
        'حركة الخزينة',
        'المعاينة',
      );

  bool get canEditTransaction =>
      hasPermission(
        'حركة الخزينة',
        'التعديل',
      );

  bool get canDeleteTransaction =>
      hasPermission(
        'حركة الخزينة',
        'الحذف',
      );

  bool get canImportExcel =>
      hasPermission(
        'حركة الخزينة',
        'استيراد من اكسل',
      );

  bool get canExport =>
      hasPermission(
        'حركة الخزينة',
        'تصدير',
      );

  bool get canFilter =>
      hasPermission(
        'حركة الخزينة',
        'فلترة',
      );

  // ============================================================
  // التكويد
  // ============================================================

  bool get canViewCoding =>
      hasPermission(
        'التكويد',
        'معاينة',
      );

  bool get canAddCodingItem =>
      hasPermission(
        'التكويد',
        'اضافة صنف',
      );

  bool get canEditCodingItem =>
      hasPermission(
        'التكويد',
        'اضافة صنف',
      );

  bool get canAddBranch =>
      hasPermission(
        'التكويد',
        'اضافة فرع',
      );

  bool get canAddSafe =>
      hasPermission(
        'التكويد',
        'اضافة خزينة',
      );

  bool get canAddSupplier =>
      hasPermission(
        'التكويد',
        'اضافة مورد',
      );

  bool get canAddStore =>
      hasPermission(
        'التكويد',
        'اضافة مخزن',
      );

  bool get canAddCustomer =>
      hasPermission(
        'التكويد',
        'اضافة عملاء',
      );

  bool get canAddPaymentMethod =>
      hasPermission(
        'التكويد',
        'اضافة طرق دفع',
      );

  bool get canAddBank =>
      hasPermission(
        'التكويد',
        'اضافة بنك',
      );

  bool get canAddEmployee =>
      hasPermission(
        'التكويد',
        'اضافة موظف',
      );

  // ============================================================
  // حسابات الموردين = المشتريات
  // ============================================================

  bool get canAddSupplierTransaction =>
      hasPermission(
        'حسابات الموردين',
        'اضافة',
      );

  bool get canEditSupplierTransaction =>
      hasPermission(
        'حسابات الموردين',
        'تعديل',
      );

  bool get canDeleteSupplierTransaction =>
      hasPermission(
        'حسابات الموردين',
        'حذف',
      );

  bool get canViewSupplierHistory =>
      hasPermission(
        'حسابات الموردين',
        'معاينة',
      );

  bool get canExportSupplier =>
      hasPermission(
        'حسابات الموردين',
        'تصدير',
      );

  // ============================================================
  // تسويات الموردين
  // ============================================================

  bool get canAddSupplierSettlement =>
      hasPermission(
        'تسويات الموردين',
        'إضافة',
      );

  bool get canEditSupplierSettlement =>
      hasPermission(
        'تسويات الموردين',
        'تعديل',
      );

  bool get canDeleteSupplierSettlement =>
      hasPermission(
        'تسويات الموردين',
        'حذف',
      );

  bool get canViewSupplierSettlements =>
      hasPermission(
        'تسويات الموردين',
        'معاينة',
      );

  bool get canExportSupplierSettlement =>
      hasPermission(
        'تسويات الموردين',
        'تصدير',
      );

  // إظهار صفحة التسويات
  //
  // السماح بالدخول لو المستخدم عنده
  // معاينة أو إضافة.
  bool get canShowSupplierSettlements =>
      canViewSupplierSettlements ||
      canAddSupplierSettlement;

  // ============================================================
  // حركة الجرد
  // ============================================================

  bool get canAddInventory =>
      hasPermission(
        'حركة الجرد',
        'اضافة',
      );

  bool get canEditInventory =>
      hasPermission(
        'حركة الجرد',
        'تعديل',
      );

  bool get canDeleteInventory =>
      hasPermission(
        'حركة الجرد',
        'حذف',
      );

  bool get canViewInventory =>
      hasPermission(
        'حركة الجرد',
        'معاينة',
      );

  bool get canImportInventory =>
      hasPermission(
        'حركة الجرد',
        'استيراد',
      );

  bool get canExportInventory =>
      hasPermission(
        'حركة الجرد',
        'تصدير',
      );

  // ============================================================
  // التقارير
  // ============================================================

  bool get canViewReportsSales =>
      hasPermission(
        'التقارير',
        'تقرير المبيعات',
      );

  bool get canViewReportsPeriod =>
      hasPermission(
        'التقارير',
        'تقرير فترة',
      );

  bool get canShareReports =>
      hasPermission(
        'التقارير',
        'مشاركة',
      );

  // ============================================================
// التقارير التحليلية (Advanced)
// ============================================================

bool get canViewAdvancedReport1 => hasPermission('التقارير', 'تقرير التدفق النقدي');
bool get canViewAdvancedReport2 => hasPermission('التقارير', 'تحليل هيكل المصروفات');
bool get canViewAdvancedReport3 => hasPermission('التقارير', 'الربحية الصافية لكل فرع');
bool get canViewAdvancedReport4 => hasPermission('التقارير', 'تحليل حجم الفاتورة');
bool get canViewAdvancedReport5 => hasPermission('التقارير', 'تحليل الخزائن النقدية');
bool get canViewAdvancedReport6 => hasPermission('التقارير', 'الأصناف بطيئة الحركة');
bool get canViewAdvancedReport7 => hasPermission('التقارير', 'تحليل دقة الجرد');
bool get canViewAdvancedReport8 => hasPermission('التقارير', 'تقييم المخزون و ABC');
bool get canViewAdvancedReport9 => hasPermission('التقارير', 'تحليل أداء الموردين');
bool get canViewAdvancedReport10 => hasPermission('التقارير', 'تحليل العوائد والخصومات');
bool get canViewAdvancedReport11 => hasPermission('التقارير', 'تحليل الاتجاهات الموسمية');
bool get canViewAdvancedReport12 => hasPermission('التقارير', 'تحليل هامش الربح الفعلي');
bool get canViewAdvancedReport13 => hasPermission('التقارير', 'تحليل تجميع المنتجات');
bool get canViewAdvancedReport14 => hasPermission('التقارير', 'تحليل المصروفات بالنسبة للمبيعات');

// صلاحية التقرير الموسع (صافي الجرد الحالي)
bool get canViewExtendedReport => hasPermission('التقارير', 'التقرير الموسع (صافي الجرد)');

  // ============================================================
  // رصيد المخزون
  // ============================================================

  bool get canShowStock =>
      hasPermission(
        'رصيد المخزون',
        'معاينة',
      );

  bool get canAddSale => hasPermission('المبيعات', 'إضافة');
  bool get canEditSale => hasPermission('المبيعات', 'تعديل');
  bool get canDeleteSale => hasPermission('المبيعات', 'حذف');
  bool get canViewSales => hasPermission('المبيعات', 'معاينة');
  bool get canChangeSellingPrice => hasPermission('المبيعات', 'تغيير سعر البيع');
  bool get canViewWholesaleInSale => hasPermission('المبيعات', 'عرض سعر الجملة');

  /// أي من حقوق التكلفة الثلاثة (مطابق لقاعدة الخادم):
  /// التكويد/سعر الشراء أو المبيعات/عرض سعر الجملة أو
  /// رصيد المخزون/عرض سعر الجملة.
  bool get canViewCostPrices =>
      hasPermission('التكويد', 'سعر الشراء') ||
      canViewWholesaleInSale ||
      canViewStockWholesalePrice;
  bool get canAddSaleReturn => hasPermission('المرتجعات', 'إضافة');
  bool get canViewSaleReturns => hasPermission('المرتجعات', 'معاينة');
  bool get canEditSaleReturn => hasPermission('المرتجعات', 'تعديل');
  bool get canDeleteSaleReturn => hasPermission('المرتجعات', 'حذف');
  bool get canAddCustomerPayment => hasPermission('حسابات العملاء', 'إضافة تحصيل');
  bool get canViewCustomerBalances => hasPermission('حسابات العملاء', 'عرض الأرصدة');
  bool get canViewCustomerPayments => hasPermission('حسابات العملاء', 'معاينة');
  bool get canAddStockTransfer => hasPermission('التحويلات المخزنية', 'إضافة');
  bool get canViewStockTransfers => hasPermission('التحويلات المخزنية', 'معاينة');
  bool get canEditStockTransfer => hasPermission('التحويلات المخزنية', 'تعديل');
  bool get canDeleteStockTransfer => hasPermission('التحويلات المخزنية', 'حذف');
  bool get canAddTreasuryTransfer => canBypassPermissions || hasPermission('تحويلات الخزائن', 'إضافة');
  bool get canViewTreasuryTransfers => canBypassPermissions || hasPermission('تحويلات الخزائن', 'معاينة');
  bool get canEditTreasuryTransfer => canBypassPermissions || hasPermission('تحويلات الخزائن', 'تعديل');
  bool get canDeleteTreasuryTransfer => canBypassPermissions || hasPermission('تحويلات الخزائن', 'حذف');
  bool get canReadTreasuryEffects => !_scopeVerificationPending && (canBypassPermissions || TreasuryCacheScope.hasEffects(_permissions));
  bool get canViewSalesTreasuries => hasPermission('أرصدة خزائن المبيعات', 'معاينة');
  bool pageVisible(String label, {bool fallback = true}) =>
      !_scopeVerificationPending && (canBypassPermissions ||
          PageVisibility.visible(_permissions, label, fallback: fallback));
  bool get canShowSales => pageVisible('المبيعات والعملاء', fallback: _legacyCanShowSales);
  bool get canShowTreasuryTransfers => pageVisible('تحويلات الخزائن',
      fallback: canAddTreasuryTransfer || canViewTreasuryTransfers);
  bool get canShowStockPage => pageVisible('رصيد المخزون', fallback: canShowInventory);
  bool get _legacyCanShowSales => canAddSale || canViewSales || canAddSaleReturn || canViewSaleReturns || canAddCustomerPayment || canViewCustomerBalances || canViewCustomerPayments || canViewSalesTreasuries;

  bool get canViewStockWholesalePrice =>
      hasPermission(
        'رصيد المخزون',
        'عرض سعر الجملة',
      );

  bool get canExportStock =>
      hasPermission(
        'رصيد المخزون',
        'تصدير',
      );

  // ============================================================
  // الصلاحيات العامة
  // ============================================================

  bool get canChangeBranch =>
      hasPermission(
        'صلاحيات عامة',
        'تغيير الفرع(صفحة الهوم)',
      );

  bool get canAccessPermissionsPage =>
      hasPermission(
        'صلاحيات عامة',
        'صفحة الصلاحيات(الاعدادات)',
      );

  bool get canShowTreasury =>
      hasPermission(
        'صلاحيات عامة',
        'إظهار حركة الخزينة',
      );

  bool get canShowCoding =>
      hasPermission(
        'صلاحيات عامة',
        'إظهار التكويد',
      );

  bool get canShowReports =>
      hasPermission(
        'صلاحيات عامة',
        'إظهار التقارير',
      );

  bool get canShowSuppliers =>
      hasPermission(
        'صلاحيات عامة',
        'إظهار حركة الموردين',
      );

  bool get canShowInventory =>
      hasPermission(
        'صلاحيات عامة',
        'إظهار حركة الجرد',
      );
  bool get canShowNotifications {
    // الافتراضي = true لو المفتاح غير موجود في بيانات المستخدم
    // (يغطي المستخدمين القدامى اللي اتسجلوا قبل إضافة الصلاحية)
    return (!_scopeVerificationPending && (_permissions?['صلاحيات عامة']?['إظهار الإشعارات'] ?? !_companyPolicyActive));
  }

  bool get canShowProductLookup {
    // الافتراضي = true لو المفتاح غير موجود في بيانات المستخدم
    // (يغطي المستخدمين القدامى اللي اتسجلوا قبل إضافة الصلاحية)
    return (!_scopeVerificationPending && (_permissions?['صلاحيات عامة']?['إظهار البحث عن المنتجات'] ?? !_companyPolicyActive));
  }
  bool get canShowOnlineUsers {
    // الافتراضي = true لو المفتاح غير موجود (للمستخدمين القدامى)
    return (!_scopeVerificationPending && (_permissions?['صلاحيات عامة']?['إظهار المستخدمين المتصلين'] ?? !_companyPolicyActive));
  }

    // ============================================================
  // الموارد البشرية (HR) — نظام جديد (21 صلاحية + فلترة)
  // ============================================================

  /// هل يظهر قسم HR في القائمة الرئيسية؟
  bool get hrNotificationsEnabled =>
      (!_scopeVerificationPending && (_permissions?['صلاحيات عامة']?['إظهار الموارد البشرية'] ?? !_companyPolicyActive));

  bool get canShowHR =>
      hasPermission('صلاحيات عامة', 'إظهار الموارد البشرية');

  // ─────────────────────────────────────────────────────────
  // A. فتح الصفحات (3)
  // ─────────────────────────────────────────────────────────

  bool get canOpenAttendancePage =>
      hasPermission('الموارد البشرية', 'canOpenAttendancePage');

  bool get canOpenVacationsPage =>
      hasPermission('الموارد البشرية', 'canOpenVacationsPage');

  bool get canOpenReportPage =>
      hasPermission('الموارد البشرية', 'canOpenReportPage');

  // ─────────────────────────────────────────────────────────
  // B. عمليات الحضور (3)
  // ─────────────────────────────────────────────────────────

  bool get canAddAttendance =>
      hasPermission('الموارد البشرية', 'canAddAttendance');

  bool get canEditAttendance =>
      hasPermission('الموارد البشرية', 'canEditAttendance');

  bool get canDeleteAttendance =>
      hasPermission('الموارد البشرية', 'canDeleteAttendance');

  // ─────────────────────────────────────────────────────────
  // C. عمليات الإجازات (3)
  // ─────────────────────────────────────────────────────────

  bool get canAddVacation =>
      hasPermission('الموارد البشرية', 'canAddVacation');

  bool get canEditVacation =>
      hasPermission('الموارد البشرية', 'canEditVacation');

  bool get canDeleteVacation =>
      hasPermission('الموارد البشرية', 'canDeleteVacation');

  // ─────────────────────────────────────────────────────────
  // D. التسويات (5)
  // ─────────────────────────────────────────────────────────

  bool get canViewAdjustments =>
      hasPermission('الموارد البشرية', 'canViewAdjustments');

  bool get canAddBonus =>
      hasPermission('الموارد البشرية', 'canAddBonus');

  bool get canAddLoan =>
      hasPermission('الموارد البشرية', 'canAddLoan');

  bool get canEditAdjustment =>
      hasPermission('الموارد البشرية', 'canEditAdjustment');

  bool get canDeleteAdjustment =>
      hasPermission('الموارد البشرية', 'canDeleteAdjustment');

  // ─────────────────────────────────────────────────────────
  // E. الإعدادات (3)
  // ─────────────────────────────────────────────────────────

  bool get canEditWeeklyDay =>
      hasPermission('الموارد البشرية', 'canEditWeeklyDay');

  bool get canEditWorkSchedule =>
      hasPermission('الموارد البشرية', 'canEditWorkSchedule');

  bool get canEditDelayRules =>
      hasPermission('الموارد البشرية', 'canEditDelayRules');

  // ─────────────────────────────────────────────────────────
  // F. الخصم والراتب (3)
  // ─────────────────────────────────────────────────────────

  bool get canAddDirectDiscount =>
      hasPermission('الموارد البشرية', 'canAddDirectDiscount');

  bool get canViewSalaryAmounts =>
      hasPermission('الموارد البشرية', 'canViewSalaryAmounts');

    bool get canExportReport =>
      hasPermission('الموارد البشرية', 'canExportReport');

    // ─────────────────────────────────────────────────────────
  // G. إدارة الموظفين (2)
  // ─────────────────────────────────────────────────────────

  /// عرض قائمة الموظفين والبروفايل (read-only)
  bool get canViewEmployees =>
      hasPermission('الموارد البشرية', 'canViewEmployees');

  /// إدارة الموظفين (إضافة/تعديل/حذف)
  bool get canManageEmployees =>
      hasPermission('الموارد البشرية', 'canManageEmployees');

  // ─────────────────────────────────────────────────────────
  // H. الموظف يشوف بياناته (1) ⭐ جديد
  // ─────────────────────────────────────────────────────────

  /// الموظف يشوف بياناته هو فقط (بروفايل + راتب + حضور + إجازات + سلف)
  /// - يشتغل فقط لو مربوط بحساب Firebase (user_email)
  /// - بيسمح له بالوصول حتى لو canViewSalaryAmounts / canViewEmployees = false
  bool get canViewOwnHRData =>
      hasPermission('الموارد البشرية', 'canViewOwnHRData');

    /// ⭐ عرض تقرير إجمالي الرواتب لكل فرع
  bool get canViewBranchSalaryReport =>
      hasPermission('الموارد البشرية', 'canViewBranchSalaryReport');
    /// كود الموظف المرتبط بالحساب الحالي (null لو مش مربوط)
  ///
  /// ⭐ fallback: لو لسه ما اتحسبش، بيحاول يحسبه دلوقتي
  bool isCurrentIdentityForCompany(String company) =>
      company == _identityCompany && company == _cachedPrefs?.getString('company_code') &&
      FirebaseAuth.instance.currentUser?.uid == _identityProfileUid;

  String? get currentEmployeeCode {
    _tryComputeCurrentEmployeeCode();
    return _currentEmployeeCode;
  }

  bool isCurrentEmployee(String employeeCode) {
    final code = currentEmployeeCode;
    return code != null && _normalizeCode(code) == _normalizeCode(employeeCode);
  }

  // ─────────────────────────────────────────────────────────
  // I. فلترة الموظفين
  // ─────────────────────────────────────────────────────────

  /// قائمة الموظفين المرئيين (null = الكل في الفروع المسموحة)
  String get hrCoverageScope => jsonEncode([
    FirebaseAuth.instance.currentUser?.uid, _currentRole, _companyPolicyActive,
    _permissions?['الموارد البشرية'], _allowedBranchCodes, _hrViewableEmployees
  ]);
  List<String>? get hrViewableEmployees => _hrViewableEmployees;

  /// هل يمكن رؤية موظف معين؟
  ///
  /// الأولويات:
  /// 1) ⭐ لو الموظف هو نفسه + canViewOwnHRData = true → نعم (دائماً)
  /// 2) لو canViewEmployees = false → لا (إلا لو هو نفسه من البند 1)
  /// 3) تحقق من الفرع المسموح
  /// 4) تحقق من قائمة الموظفين المحددة
  bool canViewEmployee(String employeeCode, String? branchCode) {
    // 1) الموظف نفسه + canViewOwnHRData
    if (canViewOwnHRData && isCurrentEmployee(employeeCode)) {
      return true;
    }

    // 2) canViewEmployees = false → لا يشوف حد تاني
    if (!canViewEmployees) {
      return false;
    }

    // 3) تحقق من الفرع
    if (branchCode != null && !canAccessBranch(branchCode)) {
      return false;
    }

    // 4) تحقق من قائمة الموظفين المحددة
    final viewable = _hrViewableEmployees;
    if (viewable != null && viewable.isNotEmpty) {
      return viewable.contains(employeeCode);
    }

    return true;
  }

  /// ⭐ هل يمكن رؤية الراتب/المبالغ المالية لهذا الموظف؟
  ///
  /// المنطق:
  /// 1) لو الموظف هو نفسه + canViewOwnHRData = true → نعم (دائماً)
  /// 2) غير كده → يعتمد على canViewSalaryAmounts
  bool canSeeEmployeeSalary(String employeeCode) {
    // الموظف نفسه + canViewOwnHRData
    if (canViewOwnHRData && isCurrentEmployee(employeeCode)) {
      return true;
    }

    // otherwise — الصلاحية العامة
    return canViewSalaryAmounts;
  }



}
