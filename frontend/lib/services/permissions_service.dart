import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/api_service.dart';

class PermissionsService {
  static final PermissionsService _instance = PermissionsService._internal();
  factory PermissionsService() => _instance;
  PermissionsService._internal();

  Map<String, Map<String, bool>>? _permissions;
  // ❌ حذف: String? _userId;
  int? _lastUpdate;

  List<String>? _allowedBranchCodes;
  String? _defaultBranchCode;

  Future<void> loadPermissions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_email') ?? '';
      if (userId.isEmpty) {
        print("⚠️ PermissionsService: user_email غير موجود في SharedPreferences");
        return;
      }
      // نستخدم userId محلياً دون تخزينه في متغير
      final jobCode = prefs.getString('job_code') ?? '1';
      print("📂 تحميل صلاحيات للمستخدم: $userId، jobCode: $jobCode");

      final box = Hive.box('coding_box');
      final key = 'permissions_$userId';
      final lastUpdateKey = 'permissions_last_update_$userId';
      final branchKey = 'allowed_branches_$userId';

      _lastUpdate = box.get(lastUpdateKey);

      int? firestoreUpdate;
      Map<String, dynamic>? firestoreData;
      try {
        var doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
        if (doc.exists) {
          var data = doc.data()!;
          if (data.containsKey('updated_at') && data['updated_at'] != null) {
            firestoreUpdate = (data['updated_at'] as Timestamp).millisecondsSinceEpoch;
          }
          if (data.containsKey('permissions') && data['permissions'] != null) {
            firestoreData = data['permissions'] as Map<String, dynamic>;
          }
          // ========== قراءة الفروع المسموح بها ==========
          if (data.containsKey('allowed_branches')) {
            _allowedBranchCodes = _parseBranchList(data['allowed_branches']);
          }
          if (data.containsKey('default_branch')) {
            _defaultBranchCode = data['default_branch']?.toString();
          }
        }
      } catch (e) {
        print("⚠️ فشل قراءة من Firestore: $e");
      }

      bool needFetch = false;
      if (_lastUpdate == null || firestoreUpdate == null) {
        needFetch = true;
      } else if (firestoreUpdate > _lastUpdate!) {
        needFetch = true;
        print("🔄 يوجد تحديث جديد في Firestore (${DateTime.fromMillisecondsSinceEpoch(firestoreUpdate)})");
      }

      if (needFetch && firestoreData != null) {
        _permissions = _convertToPermissionsMap(firestoreData);
        await box.put(key, _permissions);
        if (firestoreUpdate != null) {
          await box.put(lastUpdateKey, firestoreUpdate);
          _lastUpdate = firestoreUpdate;
        }
        if (_allowedBranchCodes != null) {
          await box.put(branchKey, _allowedBranchCodes);
        }
        print("✅ تم جلب الصلاحيات من Firestore وحفظها في Hive");
        return;
      }

      // محاولة استخدام Hive
      if (box.containsKey(key)) {
        var rawData = box.get(key);
        if (rawData != null && rawData is Map) {
          _permissions = _convertToPermissionsMap(rawData);
          var savedBranches = box.get(branchKey);
          if (savedBranches != null && savedBranches is List) {
            _allowedBranchCodes = savedBranches.map((e) => e.toString()).toList();
          } else {
            _allowedBranchCodes = ['all'];
          }
          print("✅ تم تحميل الصلاحيات من Hive (محلياً)");
          return;
        }
      }

      // إنشاء صلاحيات افتراضية
      print("📡 إنشاء صلاحيات افتراضية وحفظها في Firestore و Hive...");
      _permissions = _createDefaultPermissions(jobCode);
      _allowedBranchCodes = ['all'];
      _defaultBranchCode = null;

      await box.put(key, _permissions);
      await box.put(branchKey, _allowedBranchCodes);
      int now = DateTime.now().millisecondsSinceEpoch;
      await box.put(lastUpdateKey, now);
      _lastUpdate = now;

      try {
        await FirebaseFirestore.instance.collection('users').doc(userId).set({
          'permissions': _permissions,
          'allowed_branches': _allowedBranchCodes,
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        print("✅ تم حفظ الصلاحيات الافتراضية في Firestore");
      } catch (e) {
        print("⚠️ فشل حفظ الصلاحيات في Firestore: $e");
      }

      print("✅ تم إنشاء صلاحيات افتراضية وحفظها محلياً وسحابياً");
    } catch (e) {
      print("❌ خطأ في loadPermissions: $e");
      try {
        final prefs = await SharedPreferences.getInstance();
        final jobCode = prefs.getString('job_code') ?? '1';
        _permissions = _createDefaultPermissions(jobCode);
        _allowedBranchCodes = ['all'];
      } catch (_) {
        _permissions = _createDefaultPermissions('1');
        _allowedBranchCodes = ['all'];
      }
    }
  }

  // ========== دالة مساعدة لتحويل بيانات الفروع ==========
  List<String>? _parseBranchList(dynamic data) {
    if (data == null) return null;
    if (data is String && data == 'all') return ['all'];
    if (data is List) {
      return data.map((e) => e.toString()).toList();
    }
    return null;
  }

  // ========== Getters للفروع ==========
  List<String>? get allowedBranches => _allowedBranchCodes;
  String? get defaultBranch => _defaultBranchCode;

  bool hasSingleBranch() {
    if (_allowedBranchCodes == null) return false;
    if (_allowedBranchCodes!.contains('all')) return false;
    return _allowedBranchCodes!.length == 1;
  }

  bool canAccessBranch(String branchCode) {
    if (_allowedBranchCodes == null) return true;
    if (_allowedBranchCodes!.contains('all')) return true;
    return _allowedBranchCodes!.contains(branchCode);
  }

  // ========== حفظ الصلاحيات مع allowed_branches ==========
  Future<void> savePermissions(
    Map<String, Map<String, bool>> permissions, {
    String? targetEmail,
    List<String>? allowedBranches,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final email = targetEmail ?? prefs.getString('user_email');
    if (email == null || email.isEmpty) {
      print("⚠️ لا يوجد بريد إلكتروني مستهدف للحفظ");
      return;
    }

    try {
      final box = Hive.box('coding_box');
      final key = 'permissions_$email';
      final lastUpdateKey = 'permissions_last_update_$email';
      final branchKey = 'allowed_branches_$email';

      await box.put(key, permissions);
      if (allowedBranches != null) {
        await box.put(branchKey, allowedBranches);
        if (email == prefs.getString('user_email')) {
          _allowedBranchCodes = allowedBranches;
        }
      }
      int now = DateTime.now().millisecondsSinceEpoch;
      await box.put(lastUpdateKey, now);

      if (email == prefs.getString('user_email')) {
        _permissions = permissions;
        _lastUpdate = now;
      }

      await ApiService().updatePermissions(email, permissions, allowedBranches: allowedBranches);
      print("✅ تم حفظ صلاحيات $email في Firestore عبر API بنجاح");
    } catch (e) {
      print("⚠️ فشل حفظ الصلاحيات في Firestore عبر API: $e");
    }
  }

  // ========== تحويل البيانات إلى خريطة الصلاحيات ==========
  Map<String, Map<String, bool>> _convertToPermissionsMap(dynamic data) {
    Map<String, Map<String, bool>> converted = {};
    data.forEach((categoryKey, categoryValue) {
      if (categoryValue is Map) {
        Map<String, bool> subMap = {};
        categoryValue.forEach((permKey, permValue) {
          bool boolValue = false;
          if (permValue is bool) {
            boolValue = permValue;
          } else if (permValue is String) {
            boolValue = permValue.toLowerCase() == 'true';
          } else if (permValue is int) {
            boolValue = permValue == 1;
          }
          subMap[permKey.toString()] = boolValue;
        });
        converted[categoryKey.toString()] = subMap;
      }
    });
    return converted;
  }

  // ========== إنشاء الصلاحيات الافتراضية ==========
  Map<String, Map<String, bool>> _createDefaultPermissions(String jobCode) {
    var allPermissions = {
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
      'حسابات الموردين': {
        'اضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'تصدير': false,
      },
      'حركة الجرد': {
        'اضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'استيراد': false,
        'تصدير': false,
      },
      'التقارير': {
        'تقرير المبيعات': false,
        'تقرير فترة': false,
        'مشاركة': false,
      },
      'صلاحيات عامة': {
        'تغيير الفرع(صفحة الهوم)': false,
        'صفحة الصلاحيات(الاعدادات)': false,
        'إظهار حركة الخزينة': true,
        'إظهار التكويد': true,
        'إظهار التقارير': true,
        'إظهار حركة الموردين': true,
        'إظهار حركة الجرد': true,
      },
      'رصيد المخزون': {
        'معاينة': false,
        'عرض سعر الجملة': false,
        'تصدير': false,
      },
    };

    if (jobCode == '99' || jobCode == '200') {
      allPermissions.forEach((category, perms) {
        perms.forEach((key, _) {
          allPermissions[category]![key] = true;
        });
      });
    }
    return allPermissions;
  }

  // ========== دوال مساعدة للصلاحيات الأساسية (getters) ==========
  bool hasPermission(String category, String permission) {
    if (_permissions == null) {
      print("⚠️ hasPermission: _permissions is null");
      return false;
    }
    return _permissions?[category]?[permission] ?? false;
  }

  bool get canViewBalances => hasPermission('حركة الخزينة', 'شاشات الارصدة');
  bool get canAddTransaction => hasPermission('حركة الخزينة', 'ادخال اذون');
  bool get canViewTransactions => hasPermission('حركة الخزينة', 'المعاينة');
  bool get canEditTransaction => hasPermission('حركة الخزينة', 'التعديل');
  bool get canDeleteTransaction => hasPermission('حركة الخزينة', 'الحذف');
  bool get canImportExcel => hasPermission('حركة الخزينة', 'استيراد من اكسل');
  bool get canExport => hasPermission('حركة الخزينة', 'تصدير');
  bool get canFilter => hasPermission('حركة الخزينة', 'فلترة');

  bool get canViewCoding => hasPermission('التكويد', 'معاينة');
  bool get canAddCodingItem => hasPermission('التكويد', 'اضافة صنف');
  bool get canEditCodingItem => hasPermission('التكويد', 'اضافة صنف');
  bool get canAddBranch => hasPermission('التكويد', 'اضافة فرع');
  bool get canAddSafe => hasPermission('التكويد', 'اضافة خزينة');
  bool get canAddSupplier => hasPermission('التكويد', 'اضافة مورد');
  bool get canAddStore => hasPermission('التكويد', 'اضافة مخزن');
  bool get canAddCustomer => hasPermission('التكويد', 'اضافة عملاء');
  bool get canAddPaymentMethod => hasPermission('التكويد', 'اضافة طرق دفع');
  bool get canAddBank => hasPermission('التكويد', 'اضافة بنك');
  bool get canAddEmployee => hasPermission('التكويد', 'اضافة موظف');

  bool get canViewReportsSales => hasPermission('التقارير', 'تقرير المبيعات');
  bool get canViewReportsPeriod => hasPermission('التقارير', 'تقرير فترة');
  bool get canShareReports => hasPermission('التقارير', 'مشاركة');

  bool get canChangeBranch => hasPermission('صلاحيات عامة', 'تغيير الفرع(صفحة الهوم)');
  bool get canAccessPermissionsPage => hasPermission('صلاحيات عامة', 'صفحة الصلاحيات(الاعدادات)');
  bool get canShowTreasury => hasPermission('صلاحيات عامة', 'إظهار حركة الخزينة');
  bool get canShowCoding => hasPermission('صلاحيات عامة', 'إظهار التكويد');
  bool get canShowReports => hasPermission('صلاحيات عامة', 'إظهار التقارير');
  bool get canShowSuppliers => hasPermission('صلاحيات عامة', 'إظهار حركة الموردين');
  bool get canShowInventory => hasPermission('صلاحيات عامة', 'إظهار حركة الجرد');

  bool get canAddInventory => hasPermission('حركة الجرد', 'اضافة');
  bool get canEditInventory => hasPermission('حركة الجرد', 'تعديل');
  bool get canDeleteInventory => hasPermission('حركة الجرد', 'حذف');
  bool get canViewInventory => hasPermission('حركة الجرد', 'معاينة');
  bool get canImportInventory => hasPermission('حركة الجرد', 'استيراد');
  bool get canExportInventory => hasPermission('حركة الجرد', 'تصدير');

  bool get canShowStock => hasPermission('رصيد المخزون', 'معاينة');
  bool get canViewStockWholesalePrice => hasPermission('رصيد المخزون', 'عرض سعر الجملة');
  bool get canExportStock => hasPermission('رصيد المخزون', 'تصدير');

  bool get canAddSupplierTransaction => hasPermission('حسابات الموردين', 'اضافة');
  bool get canEditSupplierTransaction => hasPermission('حسابات الموردين', 'تعديل');
  bool get canDeleteSupplierTransaction => hasPermission('حسابات الموردين', 'حذف');
  bool get canViewSupplierHistory => hasPermission('حسابات الموردين', 'معاينة');
  bool get canExportSupplier => hasPermission('حسابات الموردين', 'تصدير');
}