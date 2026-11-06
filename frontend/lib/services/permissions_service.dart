// lib/services/permissions_service.dart

import 'dart:async';                                   // ← NEW
import 'package:flutter/foundation.dart';              // ← NEW: ChangeNotifier
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
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
    List<String>? _hrViewableEmployees;

    /// ⭐ كود الموظف الحالي (لو مربوط بحساب Firebase)
  String? _currentEmployeeCode;

  /// ⭐ إيميل المستخدم الحالي (للـ fallback)
  String? _currentUserEmail;

  /// ⭐ SharedPreferences cached (للـ fallback)
  SharedPreferences? _cachedPrefs;

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
  // ✅ معالج تغيير حالة الـ Auth
  //
  // بيتنادى:
  // 1. أول ما الـ listener يتسجل (بالقيمة الحالية)
  // 2. كل مرة المستخدم يعمل login أو logout
  //
  // لو الـ UID اتغير → reset تلقائي + إيقاف Firestore listener
  // ============================================================

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

  void _startFirestoreListener(String email) {
    if (_listenedEmail == email && _firestoreSub != null) return;

    _firestoreSub?.cancel();
    _firestoreSub = null;
    _listenedEmail = email;

    print('🎧 بدء الاستماع لصلاحيات $email');

    _firestoreSub = FirebaseFirestore.instance
        .collection('users')
        .doc(email)
        .snapshots()
        .listen(
      (snapshot) async {
        if (!snapshot.exists) return;
        final data = snapshot.data();
        if (data == null) return;

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
          print('🚫 تم إيقاف حساب $email من الإدارة — جاري تسجيل الخروج');
          _stopFirestoreListener();
          FirebaseAuth.instance.signOut();
          return;
        }

        bool changed = false;

        final permissionsData = data['permissions'];
        if (permissionsData is Map) {
          final newPerms = _convertToPermissionsMap(permissionsData);
          _permissions = newPerms;
          Hive.box('coding_box').put('permissions_$email', newPerms);
          changed = true;
        }

                final branchesData = data['allowed_branches'];
        if (branchesData != null) {
          final newBranches = _parseBranchList(branchesData) ?? ['all'];
          _allowedBranchCodes = newBranches;
          Hive.box('coding_box').put('allowed_branches_$email', newBranches);
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

          _hrViewableEmployees = newViewable;
          final box = Hive.box('coding_box');
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
        }
      },
      onError: (e) => print('⚠️ خطأ في listener الصلاحيات: $e'),
    );
  }

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
      _employeesHiveSub = Hive.box('coding_box')
          .watch()
          .listen((event) {
        final key = event.key?.toString() ?? '';

        // نستمع فقط لتغييرات employees
        if (!key.endsWith('_employees')) return;

        print('📦 [Hive] employees تحدثت → إعادة حساب employee_code');

        final wasNull = _currentEmployeeCode == null;
        _currentEmployeeCode = null;  // ⭐ نعيد الحساب من الأول
        _tryComputeCurrentEmployeeCode();

        // لو حصل ربط جديد، أعلم المستمعين
        if (wasNull && _currentEmployeeCode != null) {
          print('🎉 تم ربط الحساب بموظف: $_currentEmployeeCode');
          notifyListeners();
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
    _loadFuture = null;
    _loaded = false;
    _permissions = null;
    _allowedBranchCodes = null;
    _defaultBranchCode = null;
    _hrViewableEmployees = null;
    _currentEmployeeCode = null;
    _currentUserEmail = null;
    _cachedPrefs = null;
    _stopEmployeesHiveListener();   // ⭐
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
    try {
      final prefs = await SharedPreferences.getInstance();

      final email =
          prefs.getString('user_email') ?? '';

      final jobCode =
          prefs.getString('job_code') ?? '1';

      if (email.isEmpty) {
        print(
          '⚠️ PermissionsService: user_email غير موجود',
        );
        _loaded = true;
        notifyListeners();                             // ← NEW
        return;
      }

      final box =
          Hive.box('coding_box');

      final permissionsKey =
          'permissions_$email';

      final branchesKey =
          'allowed_branches_$email';

      // ----------------------------------------------------------
      // الصلاحيات المحلية
      // ----------------------------------------------------------

            final localPermissions =
          box.get(permissionsKey);

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

            // ----------------------------------------------------------
      // الفروع المحلية
      // ----------------------------------------------------------

      final localBranches =
          box.get(branchesKey);

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
          box.get('hr_viewable_employees_$email');

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
      print(
        '❌ خطأ في loadPermissions: $e',
      );

      if (_permissions == null) {
        final prefs =
            await SharedPreferences
                .getInstance();

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
  }

    // ============================================================
  // ⭐ Helper: تطبيع الكود (trim + إزالة المسافات)
  // ============================================================

  String _normalizeCode(String code) => code.trim();

  String _normalizeEmail(String email) => email.trim().toLowerCase();


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
    if (_currentEmployeeCode != null) return;
    if (_currentUserEmail == null || _currentUserEmail!.isEmpty) return;
    if (_cachedPrefs == null) return;

    try {
      final companyCode = _cachedPrefs!.getString('company_code') ?? '';
      if (companyCode.isEmpty) return;

      final box = Hive.box('coding_box');
      final employeesRaw = box.get('${companyCode}_employees');
      if (employeesRaw is! List) {
        print('⚠️ [_tryComputeCurrentEmployeeCode] employees مش محمّلين في Hive بعد');
        return;
      }

      final normalizedEmail = _normalizeEmail(_currentUserEmail!);

      for (final item in employeesRaw) {
        if (item is! Map) continue;
        if (item['is_deleted'] == true) continue;
        final userEmail = _normalizeEmail(
          item['user_email']?.toString() ?? '',
        );
        if (userEmail.isNotEmpty && userEmail == normalizedEmail) {
          _currentEmployeeCode = _normalizeCode(
            item['code']?.toString() ?? '',
          );
          print('✅ [_tryComputeCurrentEmployeeCode] ربط: ${_currentEmployeeCode}');
          return;
        }
      }

      print('⚠️ [_tryComputeCurrentEmployeeCode] مفيش موظف مطابق لـ $normalizedEmail');
    } catch (e) {
      print('❌ [_tryComputeCurrentEmployeeCode] $e');
    }
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
  //         Hive.box('coding_box');

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

    Future<void> savePermissions(
    Map<String, Map<String, bool>> permissions, {
    String? targetEmail,
    List<String>? allowedBranches,
    List<String>? hrViewableEmployees,  // ⭐ جديد
    bool clearHrViewableEmployees = false,  // ⭐ جديد
  }) async {
    final prefs =
        await SharedPreferences.getInstance();

    final email =
        targetEmail ??
            prefs.getString('user_email');

    if (email == null ||
        email.isEmpty) {
      print(
        '⚠️ لا يوجد بريد إلكتروني مستهدف للحفظ',
      );
      return;
    }

    try {
      final box =
          Hive.box('coding_box');

      final permissionsKey =
          'permissions_$email';

      final branchesKey =
          'allowed_branches_$email';

      // ----------------------------------------------------------
      // حفظ الصلاحيات محلياً أولاً
      // ----------------------------------------------------------

      await box.put(
        permissionsKey,
        permissions,
      );

      if (allowedBranches != null) {
        await box.put(
          branchesKey,
          allowedBranches,
        );

        if (email ==
            prefs.getString('user_email')) {
          _allowedBranchCodes =
              List<String>.from(
            allowedBranches,
          );
        }
      }

      if (email ==
          prefs.getString('user_email')) {
        _permissions =
            permissions;
        notifyListeners();                             // ← NEW
      }

            // ----------------------------------------------------------
      // ⭐ جديد: حفظ الموظفين المرئيين في HR
      // ----------------------------------------------------------

      if (clearHrViewableEmployees) {
        await box.delete('hr_viewable_employees_$email');

        if (email == prefs.getString('user_email')) {
          _hrViewableEmployees = null;
        }
      } else if (hrViewableEmployees != null) {
        await box.put(
          'hr_viewable_employees_$email',
          hrViewableEmployees,
        );

        if (email == prefs.getString('user_email')) {
          _hrViewableEmployees =
              List<String>.from(hrViewableEmployees);
        }
      }

      // ----------------------------------------------------------
      // حفظ على السيرفر
      // ----------------------------------------------------------

      await ApiService().updatePermissions(
        email,
        permissions,
        allowedBranches: allowedBranches,
        hrViewableEmployees: hrViewableEmployees,
        clearHrViewableEmployees: clearHrViewableEmployees,
      );

      print(
        '✅ تم حفظ صلاحيات $email بنجاح',
      );
    } catch (e) {
      print(
        '⚠️ فشل حفظ الصلاحيات: $e',
      );

      rethrow;
    }
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
    String jobCode,
  ) {
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
    // المدير / الأدمن
    // ==========================================================

    if (jobCode == '99' ||
        jobCode == '200') {
      for (final category
          in allPermissions.keys) {
        for (final permission
            in allPermissions[
                    category]!
                .keys) {
          allPermissions[category]![
              permission] = true;
        }
      }
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
    return _permissions?[category]?[permission] ??
        false;
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
    return _permissions?['صلاحيات عامة']?['إظهار الإشعارات'] ?? true;
  }

  bool get canShowProductLookup {
    // الافتراضي = true لو المفتاح غير موجود في بيانات المستخدم
    // (يغطي المستخدمين القدامى اللي اتسجلوا قبل إضافة الصلاحية)
    return _permissions?['صلاحيات عامة']?['إظهار البحث عن المنتجات'] ?? true;
  }
  bool get canShowOnlineUsers {
    // الافتراضي = true لو المفتاح غير موجود (للمستخدمين القدامى)
    return _permissions?['صلاحيات عامة']?['إظهار المستخدمين المتصلين'] ?? true;
  }

    // ============================================================
  // الموارد البشرية (HR) — نظام جديد (21 صلاحية + فلترة)
  // ============================================================

  /// هل يظهر قسم HR في القائمة الرئيسية؟
  bool get canShowHR =>
      _permissions?['صلاحيات عامة']?['إظهار الموارد البشرية'] ?? false;

  // ─────────────────────────────────────────────────────────
  // A. فتح الصفحات (3)
  // ─────────────────────────────────────────────────────────

  bool get canOpenAttendancePage =>
      _permissions?['الموارد البشرية']?['canOpenAttendancePage'] ?? false;

  bool get canOpenVacationsPage =>
      _permissions?['الموارد البشرية']?['canOpenVacationsPage'] ?? false;

  bool get canOpenReportPage =>
      _permissions?['الموارد البشرية']?['canOpenReportPage'] ?? false;

  // ─────────────────────────────────────────────────────────
  // B. عمليات الحضور (3)
  // ─────────────────────────────────────────────────────────

  bool get canAddAttendance =>
      _permissions?['الموارد البشرية']?['canAddAttendance'] ?? false;

  bool get canEditAttendance =>
      _permissions?['الموارد البشرية']?['canEditAttendance'] ?? false;

  bool get canDeleteAttendance =>
      _permissions?['الموارد البشرية']?['canDeleteAttendance'] ?? false;

  // ─────────────────────────────────────────────────────────
  // C. عمليات الإجازات (3)
  // ─────────────────────────────────────────────────────────

  bool get canAddVacation =>
      _permissions?['الموارد البشرية']?['canAddVacation'] ?? false;

  bool get canEditVacation =>
      _permissions?['الموارد البشرية']?['canEditVacation'] ?? false;

  bool get canDeleteVacation =>
      _permissions?['الموارد البشرية']?['canDeleteVacation'] ?? false;

  // ─────────────────────────────────────────────────────────
  // D. التسويات (5)
  // ─────────────────────────────────────────────────────────

  bool get canViewAdjustments =>
      _permissions?['الموارد البشرية']?['canViewAdjustments'] ?? false;

  bool get canAddBonus =>
      _permissions?['الموارد البشرية']?['canAddBonus'] ?? false;

  bool get canAddLoan =>
      _permissions?['الموارد البشرية']?['canAddLoan'] ?? false;

  bool get canEditAdjustment =>
      _permissions?['الموارد البشرية']?['canEditAdjustment'] ?? false;

  bool get canDeleteAdjustment =>
      _permissions?['الموارد البشرية']?['canDeleteAdjustment'] ?? false;

  // ─────────────────────────────────────────────────────────
  // E. الإعدادات (3)
  // ─────────────────────────────────────────────────────────

  bool get canEditWeeklyDay =>
      _permissions?['الموارد البشرية']?['canEditWeeklyDay'] ?? false;

  bool get canEditWorkSchedule =>
      _permissions?['الموارد البشرية']?['canEditWorkSchedule'] ?? false;

  bool get canEditDelayRules =>
      _permissions?['الموارد البشرية']?['canEditDelayRules'] ?? false;

  // ─────────────────────────────────────────────────────────
  // F. الخصم والراتب (3)
  // ─────────────────────────────────────────────────────────

  bool get canAddDirectDiscount =>
      _permissions?['الموارد البشرية']?['canAddDirectDiscount'] ?? false;

  bool get canViewSalaryAmounts =>
      _permissions?['الموارد البشرية']?['canViewSalaryAmounts'] ?? false;

    bool get canExportReport =>
      _permissions?['الموارد البشرية']?['canExportReport'] ?? false;

    // ─────────────────────────────────────────────────────────
  // G. إدارة الموظفين (2)
  // ─────────────────────────────────────────────────────────

  /// عرض قائمة الموظفين والبروفايل (read-only)
  bool get canViewEmployees =>
      _permissions?['الموارد البشرية']?['canViewEmployees'] ?? false;

  /// إدارة الموظفين (إضافة/تعديل/حذف)
  bool get canManageEmployees =>
      _permissions?['الموارد البشرية']?['canManageEmployees'] ?? false;

  // ─────────────────────────────────────────────────────────
  // H. الموظف يشوف بياناته (1) ⭐ جديد
  // ─────────────────────────────────────────────────────────

  /// الموظف يشوف بياناته هو فقط (بروفايل + راتب + حضور + إجازات + سلف)
  /// - يشتغل فقط لو مربوط بحساب Firebase (user_email)
  /// - بيسمح له بالوصول حتى لو canViewSalaryAmounts / canViewEmployees = false
  bool get canViewOwnHRData =>
      _permissions?['الموارد البشرية']?['canViewOwnHRData'] ?? false;

    /// ⭐ عرض تقرير إجمالي الرواتب لكل فرع
  bool get canViewBranchSalaryReport =>
      _permissions?['الموارد البشرية']?['canViewBranchSalaryReport'] ??
      false;
    /// كود الموظف المرتبط بالحساب الحالي (null لو مش مربوط)
  ///
  /// ⭐ fallback: لو لسه ما اتحسبش، بيحاول يحسبه دلوقتي
  String? get currentEmployeeCode {
    if (_currentEmployeeCode == null) {
      _tryComputeCurrentEmployeeCode();
    }
    return _currentEmployeeCode;
  }

  /// هل الموظف ده هو المستخدم الحالي؟
  ///
  /// ⭐ fallback: لو _currentEmployeeCode لسه null، بيحاول يحسبه
  /// ⭐ trim للمقارنة (يمنع مشاكل المسافات)
  bool isCurrentEmployee(String employeeCode) {
    if (_currentEmployeeCode == null) {
      _tryComputeCurrentEmployeeCode();
    }

    if (_currentEmployeeCode == null) return false;

    return _normalizeCode(_currentEmployeeCode!) ==
        _normalizeCode(employeeCode);
  }

  // ─────────────────────────────────────────────────────────
  // I. فلترة الموظفين
  // ─────────────────────────────────────────────────────────

  /// قائمة الموظفين المرئيين (null = الكل في الفروع المسموحة)
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