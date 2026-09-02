// lib/services/permissions_service.dart

import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/api_service.dart';

class PermissionsService {
  static final PermissionsService _instance =
      PermissionsService._internal();

  factory PermissionsService() => _instance;

  PermissionsService._internal();

  // ============================================================
  // البيانات الحالية للصلاحيات
  // ============================================================

  Map<String, Map<String, bool>>? _permissions;
  List<String>? _allowedBranchCodes;
  String? _defaultBranchCode;

  // ============================================================
  // تحميل الصلاحيات
  //
  // 1) نقرأ من Hive فوراً
  // 2) ثم نحدث من Firestore في الخلفية
  // ============================================================

  Future<void> loadPermissions() async {
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
        _permissions =
            _convertToPermissionsMap(
          localPermissions,
        );
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

      print(
        '⚡ تم تحميل الصلاحيات والفروع من Hive',
      );

      // ----------------------------------------------------------
      // تحديث Firestore في الخلفية
      // ----------------------------------------------------------

      _refreshFromFirestore(
        email,
        permissionsKey,
        branchesKey,
      );
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
    }
  }

  // ============================================================
  // تحديث الصلاحيات من Firestore
  // ============================================================

  Future<void> _refreshFromFirestore(
    String email,
    String permissionsKey,
    String branchesKey,
  ) async {
    try {
      final box =
          Hive.box('coding_box');

      final doc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(email)
              .get();

      if (!doc.exists) {
        return;
      }

      final data =
          doc.data();

      if (data == null) {
        return;
      }

      // ----------------------------------------------------------
      // الصلاحيات
      // ----------------------------------------------------------

      final permissionsData =
          data['permissions'];

      if (permissionsData is Map) {
        final newPermissions =
            _convertToPermissionsMap(
          permissionsData,
        );

        _permissions =
            newPermissions;

        await box.put(
          permissionsKey,
          newPermissions,
        );
      }

      // ----------------------------------------------------------
      // الفروع
      // ----------------------------------------------------------

      final branches =
          _parseBranchList(
        data['allowed_branches'],
      );

      if (branches != null) {
        _allowedBranchCodes =
            branches;

        await box.put(
          branchesKey,
          branches,
        );
      }

      print(
        '🔄 تم تحديث الصلاحيات والفروع من Firestore',
      );
    } catch (e) {
      print(
        '⚠️ فشل تحديث الصلاحيات من Firestore: $e',
      );
    }
  }

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
      }

      // ----------------------------------------------------------
      // حفظ على السيرفر
      // ----------------------------------------------------------

      await ApiService().updatePermissions(
        email,
        permissions,
        allowedBranches:
            allowedBranches,
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
        'إظهار حركة الخزينة': true,
        'إظهار التكويد': true,
        'إظهار التقارير': true,
        'إظهار حركة الموردين': true,
        'إظهار حركة الجرد': true,
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
}