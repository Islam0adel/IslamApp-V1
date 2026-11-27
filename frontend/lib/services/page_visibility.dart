// frontend/lib/services/page_visibility.dart
// يحدد ظهور عناصر القائمة (لا يمنح صلاحية بيانات)
/// Menu choices only. Never supplies a data or operation permission.
class PageVisibility {
  static const keys = <String>{
    'إظهار المبيعات والعملاء',
    'إظهار تحويلات الخزائن',
    'إظهار رصيد المخزون',
    'إظهار فاتورة مبيعات',
    'إظهار معاينة المبيعات',
    'إظهار مرتجع مبيعات',
    'إظهار معاينة المرتجعات',
    'إظهار تحصيل من عميل',
    'إظهار معاينة تحصيلات العملاء',
    'إظهار أرصدة العملاء',
    'إظهار أرصدة خزائن المبيعات',
    'إظهار المشتريات',
    'إظهار معاينة المشتريات',
    'إظهار تسويات الموردين',
    'إظهار معاينة التسويات',
    'إظهار التحويلات المخزنية',
    'إظهار معاينة التحويلات المخزنية',
    'إظهار إدارة الموظفين',
    'إظهار الحضور والانصراف',
    'إظهار الإجازات والإعدادات',
    'إظهار تقرير الراتب الشهري',
    'إظهار إجمالي الرواتب',
    'إظهار تقرير المبيعات',
    'إظهار تقرير الفترة',
    'إظهار التقرير المالي الموسع / صافي الجرد الحالي',
    'إظهار بيان التدفق النقدي',
    'إظهار تحليل المصروفات بالنسبة للمبيعات',
    'إظهار تحليل هيكل المصروفات',
    'إظهار الربحية الصافية لكل فرع',
    'إظهار صافي ربح الفترة',
    'إظهار تحليل حجم الفاتورة',
    'إظهار تحليل الخزائن النقدية',
    'إظهار الأصناف بطيئة الحركة',
    'إظهار تحليل دقة الجرد',
    'إظهار تقييم المخزون و ABC',
    'إظهار تحليل أداء الموردين',
    'إظهار تحليل العوائد والخصومات',
    'إظهار تحليل الاتجاهات الموسمية',
    'إظهار تحليل هامش الربح الفعلي',
    'إظهار تحليل تجميع المنتجات',
  };

  // يحدد هل عنصر القائمة ظاهر
  static bool visible(Map? permissions, String label, {bool fallback = true}) {
    final general = permissions?['صلاحيات عامة'];
    final value = general is Map ? general['إظهار $label'] : null;
    return value is bool ? value : fallback;
  }

  // يجهّز خريطة الصلاحيات للحفظ
  /// Untouched compatibility defaults are display-only, never new assignments.
  static Map<String, Map<String, bool>> forSave(
      Map<String, Map<String, bool>> draft,
      Map<String, Map<String, bool>> source,
      Map<String, Map<String, bool>> displayed) {
    final result = draft.map((c, v) => MapEntry(c, Map<String, bool>.from(v)));
    for (final key in keys) {
      if (!(source['صلاحيات عامة']?.containsKey(key) ?? false) &&
          draft['صلاحيات عامة']?[key] == displayed['صلاحيات عامة']?[key]) {
        result['صلاحيات عامة']?.remove(key);
      }
    }
    return result;
  }
}
