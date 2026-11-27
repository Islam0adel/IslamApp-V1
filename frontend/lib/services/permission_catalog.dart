// frontend/lib/services/permission_catalog.dart
import 'page_visibility.dart';

// Explicit action catalog, no default grants.
// يعيد كتالوج صلاحيات فارغًا بكل الفئات والمفاتيح
Map<String, Map<String, bool>> emptyPermissionCatalog() {
  return {
    'إدارة المستخدمين': {
      'معاينة': false,
      'إضافة': false,
      'تعديل': false,
      'حذف': false,
      'تغيير حالة الحساب': false,
      'إعادة تهيئة حساب': false,
      'الموافقة على طلب': false,
      'رفض طلب': false,
    },
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
    'تسويات الموردين': {
      'إضافة': false,
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
      'طباعة': false
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
      'تصدير': false
    },
    'تحويلات الخزائن': {
      'إضافة': false,
      'معاينة': false,
      'تعديل': false,
      'حذف': false
    },
    'أرصدة خزائن المبيعات': {'معاينة': false, 'تصدير': false},
    'التقارير': {
      'تقرير المبيعات': false,
      'تقرير فترة': false,
      'مشاركة': false,
      'تقرير التدفق النقدي': false,
      'تحليل المصروفات بالنسبة للمبيعات': false,
      'تحليل هيكل المصروفات': false,
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
      'التقرير الموسع (صافي الجرد)': false,
    },
    'رصيد المخزون': {
      'معاينة': false,
      'عرض سعر الجملة': false,
      'تصدير': false,
    },
    'صلاحيات عامة': {
      for (final key in PageVisibility.keys) key: false,
      'تغيير الفرع(صفحة الهوم)': false,
      'صفحة الصلاحيات(الاعدادات)': false,
      'إظهار حركة الخزينة': false,
      'إظهار التكويد': false,
      'إظهار التقارير': false,
      'إظهار حركة الموردين': false,
      'إظهار حركة الجرد': false,
      'إظهار الإشعارات': false,
      'إظهار البحث عن المنتجات': false,
      'إظهار المستخدمين المتصلين': false,
      'إظهار الموارد البشرية': false,
    },
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
      'canViewEmployees': false, 'canViewOwnHRData': false,
      'canManageEmployees': false, 'canViewBranchSalaryReport': false,
    },
  };
}

// يعيد الاسم المعروض للصلاحية حسب الفئة والمفتاح
String permissionDisplayLabel(String category, String key) {
  if (category != 'الموارد البشرية') return key;
  const labels = {
    // A
    'canOpenAttendancePage': 'فتح صفحة الحضور',
    'canOpenVacationsPage': 'فتح صفحة الإجازات',
    'canOpenReportPage': 'فتح صفحة التقارير',
    // B
    'canAddAttendance': 'تسجيل حضور',
    'canEditAttendance': 'تعديل حضور',
    'canDeleteAttendance': 'حذف حضور',
    // C
    'canAddVacation': 'إضافة إجازة',
    'canEditVacation': 'تعديل إجازة',
    'canDeleteVacation': 'حذف إجازة',
    // D
    'canViewAdjustments': 'عرض التسويات',
    'canAddBonus': 'إضافة مكافأة',
    'canAddLoan': 'إضافة سلفة',
    'canEditAdjustment': 'تعديل تسوية',
    'canDeleteAdjustment': 'حذف تسوية',
    // E
    'canEditWeeklyDay': 'تعديل يوم الإجازة الأسبوعي',
    'canEditWorkSchedule': 'تعديل مواعيد العمل',
    'canEditDelayRules': 'تعديل إعدادات التأخير',
    // F
    'canAddDirectDiscount': 'إضافة خصم مباشر',
    'canViewSalaryAmounts': 'إظهار المبالغ المالية',
    'canExportReport': 'تصدير تقرير الراتب',
    // G
    'canViewEmployees': 'عرض الموظفين',
    'canManageEmployees': 'إدارة الموظفين (إضافة/تعديل/حذف)',
    // H
    'canViewOwnHRData': 'إظهار بيانات الموظف لنفسه (بروفايله + راتبه)',
    // I
    'canViewBranchSalaryReport': 'عرض تقرير إجمالي الرواتب لكل فرع',
  };
  return labels[key] ?? key;
}
