// lib/core/hr_constants.dart

/// ثوابت الموارد البشرية (HR)
///
/// ⚠️ مهم جداً:
/// القيم هنا **لازم** تطابق القيم في:
///   backend/app/services/hr_salary_calculator.py
///
/// أي اختلاف = حسابات رواتب مختلفة بين الفرونت والباك.
class HRConstants {
  HRConstants._(); // منع الإنشاء (utility class)

  // ============================================================
  // 1. قواعد التأخير والغياب الافتراضية
  //
  // ⚠️ القيم دي **حرجة** — لازم تطابق الباك:
  //    backend/app/services/hr_salary_calculator.py
  //    DEFAULT_DELAY_RULES
  //
  // كل قيمة = عدد أيام الخصم
  // مثال: delay_15min = 0.25 → خصم ربع يوم
  // ============================================================

  static const Map<String, double> defaultDelayRules = {
    'delay_10min': 0.0,                 // حتى 10 دقائق → بدون خصم
    'delay_15min': 0.25,                // 10-30 دقيقة → ربع يوم
    'delay_30min': 0.5,                 // 30-60 دقيقة → نصف يوم
    'delay_60min': 1.0,                 // 60-120 دقيقة → يوم كامل
    'delay_120min': 2.0,                // أكثر من 120 دقيقة → يومان
    'absence': 3.0,                     // غياب بدون إذن → 3 أيام
    'absence_with_permission': 1.0,     // غياب بإذن → يوم كامل
  };

  // ============================================================
  // 2. تسميات قواعد التأخير (للعرض في الإعدادات)
  // ============================================================

  static const Map<String, String> delayRuleLabels = {
    'delay_10min': 'التأخير حتى 10 دقائق',
    'delay_15min': 'التأخير من 10 إلى 30 دقيقة',
    'delay_30min': 'التأخير من 30 إلى 60 دقيقة',
    'delay_60min': 'التأخير من 60 إلى 120 دقيقة',
    'delay_120min': 'التأخير أكثر من 120 دقيقة',
    'absence': 'الغياب بدون إذن',
    'absence_with_permission': 'الغياب بإذن',
  };

  // ============================================================
  // 3. أسماء أيام الأسبوع (بالعربي)
  //
  // الفهرس: 0 = الأحد، 1 = الاثنين، ... 6 = السبت
  // (نفس ترتيب weekly_vacation_day في الباك)
  // ============================================================

  static const List<String> weekdayNamesAr = [
    'الأحد',
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
  ];

  // ============================================================
  // 4. أسماء الشهور (بالعربي)
  //
  // الفهرس: 1 = يناير، 2 = فبراير، ... 12 = ديسمبر
  // ============================================================

  static const List<String> monthNamesAr = [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ];

  // ============================================================
  // 5. ثوابت محسوبة
  // ============================================================

  /// عدد أيام الشهر الثابت لحساب قيمة اليوم
  /// (مطابق لـ DEFAULT_DAYS_PER_MONTH في الباك)
  static const int daysPerMonth = 30;

  /// فترة السماح الافتراضية للتأخير (دقائق)
  /// (مطابق لـ DEFAULT_LATE_GRACE_MINUTES في الباك)
  static const int defaultGraceMinutes = 15;

  /// ساعات العمل الافتراضية في اليوم
  /// (مطابق لـ DEFAULT_WORK_HOURS_PER_DAY في الباك)
  static const double defaultWorkHoursPerDay = 8.0;

  /// معامل الإضافي الافتراضي
  /// (مطابق لـ DEFAULT_OVERTIME_MULTIPLIER في الباك)
  static const double defaultOvertimeMultiplier = 1.5;

  /// يوم الراحة الأسبوعي الافتراضي
  /// 5 = الجمعة (مطابق لـ DEFAULT_WEEKLY_VACATION_DAY)
  static const int defaultWeeklyVacationDay = 5;

  // ============================================================
  // 6. Helpers لتواريخ
  // ============================================================

  /// إرجاع اسم الشهر بالعربي من رقمه (1-12)
  static String monthNameAr(int month) {
    if (month < 1 || month > 12) return '';
    return monthNamesAr[month - 1];
  }

  /// إرجاع اسم اليوم بالعربي من رقمه (0-6)
  static String weekdayNameAr(int weekday) {
    if (weekday < 0 || weekday > 6) return '';
    return weekdayNamesAr[weekday];
  }

  /// تنسيق التاريخ كنص ISO: YYYY-MM-DD
  static String dateToStr(DateTime dt) {
    return '${dt.year}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  /// تنسيق الشهر كنص ISO: YYYY-MM
  static String monthToStr(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
  }

  /// هل التاريخ ده إجازة أسبوعية؟
  ///
  /// [weeklyDay] = 0 (الأحد) ... 5 (الجمعة) ... 6 (السبت)
  /// أو null (مفيش إجازة أسبوعية)
  static bool isWeeklyVacation(DateTime date, int? weeklyDay) {
    if (weeklyDay == null) return false;

    // DateTime.weekday: 1 = الاثنين، 7 = الأحد
    // تحويله لفهرسنا (0 = الأحد)
    final ourDay = date.weekday % 7; // 0 = الأحد، 1 = الاثنين، ... 6 = السبت
    return ourDay == weeklyDay;
  }

  /// عدد أيام الشهر
  static int daysInMonth(DateTime month) {
    return DateTime(month.year, month.month + 1, 0).day;
  }
}