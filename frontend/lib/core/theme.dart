import 'package:flutter/material.dart';

/// ============================================================================
///  AppTheme  —  المرجع الوحيد لألوان التطبيق (النصوص / الأيقونات / الحالات / الخلفيات)
/// ============================================================================
///  القاعدة:
///   • أي لون في صفحات الداش بورد لازم يتغير من هنا (theme.dart).
///   • الكروت الزجاجية والتأثيرات (شفافيات - حدود - فواصل - تمويه) في ملف glass_card.dart.
///   • الثوابت للألوان الثابتة، ودوال For(context) للألوان التي تتبدل مع Light/Dark.
///     غيّر درجات الألوان هنا لتتحدث الواجهات المرتبطة بها تلقائيًا.
///
///  الأقسام:
///   1) ألوان الثيم الأساسية (فاتح / داكن)          2) دوال الألوان حسب الوضع (فاتح/داكن)
///   3) تدرجات خلفيات الصفحات                        4) ألوان النصوص والأيقونات
///   5) ألوان المميز والحالات (نجاح - خطر - تحذير)   6) خلفيات النوافذ والقوائم والأبار
///   7) ألوان خاصة (منتقي التاريخ - نص الإصدار)       8) ThemeData الفاتح والداكن
/// ============================================================================
class AppTheme {
  // ==========================================================================
  // 1) ألوان الثيم الأساسية
  // ==========================================================================

  /// اللون الأساسي للتطبيق في الوضع الفاتح (الأزرار الرئيسية - التبويبات - النصوص التفاعلية).
  static const primaryLight = Color(0xFF1A237E);

  /// اللون الأساسي للتطبيق في الوضع الداكن (الأزرار الرئيسية - primaryColor).
  static const primaryDark = Color(0xFF3949AB);

  /// خلفية الشاشة (Scaffold) في الوضع الفاتح.
  static const lightBackground = Color(0xFFF3F6FA);

  /// لون الأسطح البيضاء في الوضع الفاتح (الكروت - AppBar - القوائم).
  static const lightSurface = Color(0xFFFFFFFF);

  /// لون السطح البديل في الوضع الفاتح (خلفية الـ Chip - الصناديق الثانوية).
  static const lightSurfaceAlt = Color(0xFFE9EEF5);

  /// لون النص الأساسي في الوضع الفاتح.
  static const lightText = Color(0xFF172B4D);

  /// لون النص الثانوي (الوصف - التلميحات) في الوضع الفاتح.
  static const lightTextSecondary = Color(0xFF52647A);

  /// لون الحدود والفواصل في الوضع الفاتح.
  static const lightBorder = Color(0xFFD5DEE9);

  /// اللون الثانوي (secondary) في ColorScheme الفاتح.
  static const lightSecondary = Color(0xFF526F9D);

  /// لون الـ Chip عند اختياره في الوضع الفاتح.
  static const lightChipSelected = Color(0xFFD9E4F5);

  /// خلفية الشاشة (Scaffold) في الوضع الداكن.
  static const darkBackground = Color(0xFF0D1117);

  /// لون النص الأساسي في الوضع الداكن.
  static const darkText = Color(0xFFF5F7FA);

  /// لون النص الثانوي في الوضع الداكن.
  static const darkTextSecondary = Color(0xFFB8C2D0);

  /// لون الأسطح (الكروت العادية) في الوضع الداكن.
  static const darkSurface = Color(0xFF161D27);

  /// لون السطح البديل في الوضع الداكن.
  static const darkSurfaceAlt = Color(0xFF202938);

  /// لون الحدود في الوضع الداكن.
  static const darkBorder = Color(0xFF354052);

  // ==========================================================================
  // 2) دوال الألوان حسب الوضع (فاتح / داكن) — بتاخد context
  // ==========================================================================

  /// هل التطبيق الآن في الوضع الداكن؟
  static bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  /// النص الأساسي حسب الوضع.
  static Color textPrimary(BuildContext context) => isDark(context) ? darkText : lightText;

  /// النص الثانوي حسب الوضع.
  static Color textSecondary(BuildContext context) => isDark(context) ? darkTextSecondary : lightTextSecondary;

  /// لون السطح (الكروت) حسب الوضع.
  static Color surface(BuildContext context) => isDark(context) ? darkSurface : lightSurface;

  /// لون السطح البديل حسب الوضع.
  static Color surfaceAlt(BuildContext context) => isDark(context) ? darkSurfaceAlt : lightSurfaceAlt;

  /// لون الحدود حسب الوضع.
  static Color border(BuildContext context) => isDark(context) ? darkBorder : lightBorder;

  // ألوان الواجهة التكيفية: استخدمها داخل الصفحات بدل الألوان الثابتة.
  // في Light Mode النصوص كحلي/رمادي غامق، وفي Dark Mode تحتفظ بدرجاتها الفاتحة.
  static Color textMainFor(BuildContext context) => isDark(context) ? Colors.white : lightText;
  static Color textStrongFor(BuildContext context) => isDark(context) ? const Color(0xCCFFFFFF) : const Color(0xFF243B5A);
  static Color textSoftFor(BuildContext context) => isDark(context) ? Colors.white70 : lightTextSecondary;
  static Color textMutedFor(BuildContext context) => isDark(context) ? Colors.white60 : const Color(0xFF65758B);
  static Color textHintFor(BuildContext context) => isDark(context) ? Colors.white54 : const Color(0xFF687A90);
  static Color textFaintFor(BuildContext context) => isDark(context) ? Colors.white38 : const Color(0xFF8492A5);
  static Color accentFor(BuildContext context) => isDark(context) ? Colors.cyanAccent : const Color(0xFF2457A7);
  static Color accentAltFor(BuildContext context) => isDark(context) ? Colors.cyan : const Color(0xFF3569A8);
  static Color onAccentFor(BuildContext context) => isDark(context) ? Colors.black : Colors.white;
  // ألوان حقول الدخول: نص غامق على سطح فاتح، ونص فاتح على سطح داكن.
  static Color inputFill(BuildContext context) => isDark(context) ? Colors.white.withOpacity(0.05) : lightSurface;
  static Color inputBorder(BuildContext context) => isDark(context) ? Colors.white.withOpacity(0.10) : lightBorder;
  static Color inputFocus(BuildContext context) => isDark(context) ? Colors.white : primaryLight;
  static Color buttonOverlay(BuildContext context) => isDark(context) ? Colors.white.withOpacity(0.20) : primaryLight.withOpacity(0.08);
  // خلفية أزرار شاشات الدخول: نحافظ على الشفافية الداكنة، ونستخدم كحلي واضح في الوضع الفاتح.
  static Color authActionBackground(BuildContext context) => isDark(context) ? Colors.white.withOpacity(0.20) : primaryLight;
  static Color checkboxActive(BuildContext context) => isDark(context) ? Colors.white : primaryLight;
  static Color checkboxCheck(BuildContext context) => isDark(context) ? Colors.black : Colors.white;

  // ألوان الحالات: درجات زاهية في Dark Mode ودرجات أهدأ وأوضح في Light Mode.
  static Color successFor(BuildContext context) => isDark(context) ? success : const Color(0xFF23804A);
  static Color successStrongFor(BuildContext context) => isDark(context) ? successStrong : const Color(0xFF176B3A);
  static Color successDeepFor(BuildContext context) => isDark(context) ? successDeep : const Color(0xFF176B3A);
  static Color dangerFor(BuildContext context) => isDark(context) ? danger : const Color(0xFFC62828);
  static Color dangerStrongFor(BuildContext context) => isDark(context) ? dangerStrong : const Color(0xFFB42318);
  static Color dangerSoftFor(BuildContext context) => isDark(context) ? dangerSoft : const Color(0xFFCF5555);
  static Color warningFor(BuildContext context) => isDark(context) ? warning : const Color(0xFF946200);
  static Color warningOrangeFor(BuildContext context) => isDark(context) ? warningOrange : const Color(0xFFB45309);
  static Color warningOrangeSoftFor(BuildContext context) => isDark(context) ? warningOrangeSoft : const Color(0xFFC56A14);
  static Color infoFor(BuildContext context) => isDark(context) ? info : const Color(0xFF2457A7);
  static Color infoSoftFor(BuildContext context) => isDark(context) ? infoSoft : const Color(0xFF3569A8);
  static Color extraPurpleFor(BuildContext context) => isDark(context) ? extraPurple : const Color(0xFF7450A6);
  static Color extraPurpleDeepFor(BuildContext context) => isDark(context) ? extraPurpleDeep : const Color(0xFF6741A5);
  static Color extraTealFor(BuildContext context) => isDark(context) ? extraTeal : const Color(0xFF147D76);
  static Color extraBlueGreyFor(BuildContext context) => isDark(context) ? extraBlueGrey : const Color(0xFF52677D);
  static Color neutralFor(BuildContext context) => isDark(context) ? neutral : const Color(0xFF64748B);

  // تدرج موحد لشاشات الدخول، حتى تتغير ألوانه من هذا الملف فقط.
  static List<Color> authGradient(BuildContext context) => isDark(context)
      ? const [Colors.black, Color(0xFF1A237E), Colors.black]
      : const [Color(0xFFF7F9FC), Color(0xFFE7EDF5), Color(0xFFF4F7FB)];

  // شاشة التسجيل كان لها تدرج داكن من نقطتين؛ نحافظ عليه كما هو في Dark Mode.
  static List<Color> registerGradient(BuildContext context) => isDark(context)
      ? const [Color(0xFF1A237E), Colors.black]
      : const [Color(0xFFF7F9FC), Color(0xFFE7EDF5), Color(0xFFF4F7FB)];

  // ==========================================================================
  // 3) تدرجات خلفيات الصفحات
  // ==========================================================================

  /// تدرج خلفية الصفحات "الفاتحة فعلاً" (بيستخدمه المخزون وأرصدة المخزون والموردين).
  static const List<Color> lightPageGradient = [Color(0xFFF3F6FA), Color(0xFFE7EDF6), Color(0xFFF7F9FC)];

  /// تدرج خلفية الصفحات "الداكنة" (أسود ← نيلي ← أسود).
  static const List<Color> darkPageGradient = [Colors.black, Color(0xFF1A237E), Colors.black];

  /// تدرج خلفية صفحات المخزون وأرصدة المخزون والموردين (فاتح / داكن).
  static List<Color> pageGradient(BuildContext context) => isDark(context) ? darkPageGradient : lightPageGradient;

  // ---- تدرجات صفحات الداش بورد ----

  /// تدرج الوضع الفاتح للداش بورد (درجات هادئة من الأبيض والرمادي المزرق).
  /// ده نفس اللون اللي كان مكرر في كل صفحة.
  static const List<Color> dashLightGradient = [Color(0xFFF7F9FC), Color(0xFFEAF0F7), Color(0xFFF4F7FB)];

  /// التدرج الداكن الرئيسي (أسود ← نيلي ← أسود) — التقارير، المورّدين، الكودينج، اليومية.
  static const List<Color> dashDarkGradientMain = [Colors.black, Color(0xFF1A237E), Colors.black];

  /// التدرج الداكن "الأزرق" — صفحة التقارير وصفحة تحويل الخزينة.
  static const List<Color> dashDarkGradientBlue = [darkBackground, Color.fromARGB(238, 48, 98, 248)];

  /// التدرج الداكن (نيلي ← أسود) — صفحة شركات الأدمن وصفحة إعادة الضبط.
  static const List<Color> dashDarkGradientIndigo = [Color(0xFF1A237E), Colors.black];

  /// التدرج الداكن العميق (كحلي غامق ← أزرق ← كحلي غامق) — الصفحة الرئيسية ولوحة الموردين.
  static const List<Color> dashDarkGradientDeep = [Color(0xFF020617), Color.fromARGB(255, 47, 54, 190), Color(0xFF020617)];

  /// تدرج الوضع الداكن لصفحتي الصلاحيات والإعدادات.
  static const List<Color> dashDarkGradientSoft = [Color.fromARGB(255, 33, 31, 147), Color(0xFF161B22)];

  /// تدرج الوضع الفاتح لصفحة الصلاحيات.
  static const List<Color> permissionsLightGradient = [Color(0xFFF7F9FC), Color(0xFFE8EEF6)];

  /// تدرج الوضع الفاتح لصفحة الإعدادات.
  static const List<Color> settingsLightGradient = [Color(0xFFF7F9FC), Color(0xFFE8EEF6)];

  /// خلفية الداش بورد الرئيسية (التقارير - الموردين - الكودينج - اليومية - المخزون التاريخي...).
  static List<Color> dashGradientMain(BuildContext context) => isDark(context) ? dashDarkGradientMain : dashLightGradient;

  /// خلفية الداش بورد الزرقاء (صفحة التقارير - تحويل الخزينة).
  static List<Color> dashGradientBlue(BuildContext context) => isDark(context) ? dashDarkGradientBlue : dashLightGradient;

  /// خلفية الداش بورد (نيلي ← أسود) — شركات الأدمن وإعادة الضبط.
  static List<Color> dashGradientIndigo(BuildContext context) => isDark(context) ? dashDarkGradientIndigo : dashLightGradient;

  /// خلفية الداش بورد العميقة — الصفحة الرئيسية ولوحة الموردين.
  static List<Color> dashGradientDeep(BuildContext context) => isDark(context) ? dashDarkGradientDeep : dashLightGradient;

  /// خلفية صفحة الصلاحيات.
  static List<Color> permissionsGradient(BuildContext context) => isDark(context) ? dashDarkGradientSoft : permissionsLightGradient;

  /// خلفية صفحة الإعدادات.
  static List<Color> settingsGradient(BuildContext context) => isDark(context) ? dashDarkGradientSoft : settingsLightGradient;

  // ==========================================================================
  // 4) ألوان النصوص والأيقونات (فوق خلفيات الداش بورد الداكنة)
  // ==========================================================================

  /// النص/الأيقونة الأساسي (أبيض كامل): العناوين - الأرقام - أيقونات الأزرار - مؤشر التحميل داخل الزر.
  static const Color textMain = Colors.white;

  /// نص أبيض قوي (شفافية 80%): نصوص مميزة قليلاً أقل من الأساسي.
  static const Color textStrong = Color(0xCCFFFFFF);

  /// النص الثانوي (أبيض 70%): عناوين الحقول - تسميات الصفوف - بيانات الجداول.
  static const Color textSoft = Colors.white70;

  /// النص الخافت (أبيض 60%): الوصف التوضيحي - ملاحظات صغيرة - عناوين فرعية.
  static const Color textMuted = Colors.white60;

  /// نص التلميح (أبيض 54%): hint - التبويبات غير المختارة - نصوص ثانوية جداً.
  static const Color textHint = Colors.white54;

  /// النص الباهت جداً (أبيض 38%): نصوص معطّلة أو شبه مخفية.
  static const Color textFaint = Colors.white38;

  /// أيقونة باهتة (أبيض 30%): أيقونات الحالة الفارغة / المعطلة.
  static const Color iconFaint = Colors.white30;

  /// أيقونة شبه شفافة (أبيض 24%): أيقونات زخرفية خفيفة جداً.
  static const Color iconGhost = Colors.white24;

  /// لون النص/الأيقونة فوق الخلفيات الفاتحة (أسود): نص الزر الأصفر/السماوي - علامة الصح في الـ Checkbox - التبويب المختار.
  static const Color onAccent = Colors.black;

  // ==========================================================================
  // 5) اللون المميز وألوان الحالات
  // ==========================================================================

  /// اللون المميز الأساسي للتطبيق (سماوي فاتح): العناوين المهمة - الأيقونات النشطة - Switch - التبويب المختار - حدود التركيز.
  static const Color accent = Colors.cyanAccent;

  /// السماوي الأغمق: رؤوس الجداول - أزرار الإجراءات الثانوية - عناوين فرعية.
  static const Color accentAlt = Colors.cyan;

  /// السماوي العميق (درجة 700): زر رئيسي بخلفية سماوية داكنة.
  static const Color accentDeep = Color(0xFF0097A7); // = Colors.cyan.shade700

  /// النجاح / الإيراد / الموجب (أخضر فاتح): المبالغ الموجبة - أزرار الحفظ - Switch المفعّل.
  static const Color success = Colors.greenAccent;

  /// النجاح القوي (أخضر): رسائل النجاح في SnackBar - أيقونات التأكيد.
  static const Color successStrong = Colors.green;

  /// النجاح العميق (درجة 700): زر أخضر داكن.
  static const Color successDeep = Color(0xFF00C853); // = Colors.greenAccent.shade700

  /// الخطر / المصروف / السالب (أحمر فاتح): المبالغ السالبة - الحذف - الأيقونات التحذيرية - العدّاد.
  static const Color danger = Colors.redAccent;

  /// الخطر القوي (أحمر): رسائل الخطأ في SnackBar - أزرار الحذف / إعادة الضبط.
  static const Color dangerStrong = Colors.red;

  /// الخطر الناعم (أحمر فاتح جداً): نص تنبيه خفيف.
  static const Color dangerSoft = Color(0xFFFF8A80); // = Colors.redAccent.shade100

  /// التحذير / قيد الانتظار (أصفر كهرماني): الإجماليات - الأيقونات المميزة - زر التعديل - تبويب مختار.
  static const Color warning = Colors.amber;

  /// التحذير البرتقالي: رسائل التحذير في SnackBar - أيقونات التنبيه.
  static const Color warningOrange = Colors.orange;

  /// البرتقالي الفاتح: عناصر قوائم ثانوية - مؤشرات تنبيه خفيفة.
  static const Color warningOrangeSoft = Colors.orangeAccent;

  /// المعلومات (أزرق فاتح): أيقونات المعلومات - إجماليات الحالة.
  static const Color info = Colors.blueAccent;

  /// المعلومات الفاتحة (أزرق سماوي): عناصر ثانوية في القوائم والكروت.
  static const Color infoSoft = Colors.lightBlueAccent;

  /// بنفسجي مميز: عناصر الإجماليات والقوائم الإضافية.
  static const Color extraPurple = Colors.purpleAccent;

  /// بنفسجي غامق: أيقونة واحدة مميزة.
  static const Color extraPurpleDeep = Colors.purple;

  /// تركواز فاتح: عنصر قائمة إضافي.
  static const Color extraTeal = Colors.tealAccent;

  /// رمادي مزرق: عنصر قائمة إضافي.
  static const Color extraBlueGrey = Colors.blueGrey;

  /// الرمادي المحايد: Switch غير المفعّل - الحالات المعطلة - النصوص المحايدة.
  static const Color neutral = Colors.grey;

  // ==========================================================================
  // 6) خلفيات النوافذ والقوائم والأبار
  // ==========================================================================

  // ألوان النوافذ والقوائم المتوافقة مع الثيم. استخدم هذه الدوال في الواجهات.
  static Color dialogBackground(BuildContext context) => isDark(context) ? dialogBg : lightSurface;
  static Color dropdownBackground(BuildContext context) => isDark(context) ? dropdownBgNavy : lightSurface;
  static Color sheetBackground(BuildContext context) => isDark(context) ? sheetBgNavy : lightSurface;
  
  
  /// خلفية نافذة الحوار AlertDialog (نيلي غامق).
  static const Color dialogBg = Color(0xFF1A237E);

  /// خلفية نافذة حوار داكنة (كحلي غامق جداً) — نوافذ الحذف والتأكيد.
  static const Color dialogBgDark = Color(0xFF0F172A);

  /// خلفية القوائم المنسدلة Dropdown (نيلي غامق).
  static const Color dropdownBg = Color(0xFF1A237E);

  /// خلفية قائمة منسدلة بلون كحلي.
  static const Color dropdownBgNavy = Color.fromARGB(255, 11, 20, 78);

  /// خلفية قائمة منسدلة بلون رمادي بنفسجي (صفحة الصلاحيات).
  static const Color dropdownBgAlt = Color(0xFF2D2D44);

  /// خلفية الـ BottomSheet (نيلي غامق).
  static const Color sheetBgIndigo = Color(0xFF1A237E);

  /// خلفية BottomSheet بلون كحلي.
  static const Color sheetBgNavy = Color.fromARGB(255, 11, 20, 78);

  /// خلفية BottomSheet شفافة (الشكل بيجي من الكارت الزجاجي جواها).
  static const Color sheetBgTransparent = Colors.transparent;

  /// خلفية لوحة داخلية نيلي غامق (BoxDecoration).
  static const Color panelDeepBg = Color(0xFF1A237E);
  static Color modalPanelFor(BuildContext context) =>
    isDark(context) ? panelDeepBg : lightSurface;

  /// خلفية زر رئيسي نيلي (ElevatedButton).
  static const Color buttonPrimaryBg = Color(0xFF1A237E);

  /// خلفية الـ AppBar (شفافة فوق التدرج).
  static const Color appBarBg = Colors.transparent;

  /// خلفية AppBar بلون كحلي شبه شفاف.
  static const Color appBarBgTint = Color.fromARGB(149, 5, 15, 76);

  /// خلفية AppBar بنفسجية شفافة جداً (صفحة الإعدادات).
  static const Color appBarBgGlass = Color.fromARGB(24, 75, 42, 194);

  // ==========================================================================
  // 7) ألوان خاصة
  // ==========================================================================

  /// اللون الأساسي في منتقي التاريخ (DatePicker).
  static const Color datePickerPrimary = Colors.blueAccent;

  /// لون النص فوق اللون الأساسي في منتقي التاريخ.
  static const Color datePickerOnPrimary = Colors.white;

  /// لون النص على سطح منتقي التاريخ.
  static const Color datePickerOnSurface = Colors.white;

  /// خلفية منتقي التاريخ.
  static const Color datePickerSurface = Color.fromARGB(255, 30, 30, 30);

  /// لون نص الإصدار "IslamApp V1.0" أعلى الصفحة الرئيسية (أخضر شفاف).
  static const Color brandVersionText = Color.fromARGB(213, 123, 248, 51);

  // ==========================================================================
  // 8) ThemeData
  // ==========================================================================

  /// الثيم الفاتح الكامل للتطبيق.
  static final lightTheme = ThemeData(
    brightness: Brightness.light,
    // اللون الأساسي
    primaryColor: primaryLight,
    // مخطط الألوان: primary للأزرار/التفاعل، surface للأسطح، secondary للثانوي، onXXX للنصوص فوقها
    colorScheme: ColorScheme.light(primary: primaryLight, onPrimary:lightText, surface: lightSurface, onSurface: lightText, secondary: lightSecondary, onSecondary: Colors.white),
    // خلفية الشاشة
    scaffoldBackgroundColor: lightBackground,
    // خلفية القوائم والنوافذ
    canvasColor: lightSurface,
    fontFamily: 'Cairo',
    // شريط العنوان: خلفية + لون النص + لون الأيقونات
    appBarTheme: const AppBarTheme(backgroundColor: lightSurface, foregroundColor: lightText, elevation: 0, iconTheme: IconThemeData(color: lightText)),
    // ألوان النصوص العامة
    textTheme: const TextTheme(bodyLarge: TextStyle(color: lightText), bodyMedium: TextStyle(color: lightText), bodySmall: TextStyle(color: lightTextSecondary), titleLarge: TextStyle(color: lightText), titleMedium: TextStyle(color: lightText), titleSmall: TextStyle(color: lightText)),
    // لون الأيقونات العام
    iconTheme: const IconThemeData(color: lightText),
    // لون الفواصل
    dividerColor: lightBorder,
    // التبويبات: المختار / غير المختار / المؤشر
    tabBarTheme: const TabBarThemeData(labelColor: primaryLight, unselectedLabelColor: lightTextSecondary, indicatorColor: primaryLight),
    // أزرار النص
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: primaryLight)),
    // أزرار الحدود: لون النص + لون الحد
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: primaryLight, side: const BorderSide(color: lightBorder))),
    // حقول الإدخال
    inputDecorationTheme: _inputTheme(lightText, lightSurface, lightBorder),
    // الأزرار المرتفعة
    elevatedButtonTheme: _buttonTheme(primaryLight, Colors.white),
    // الـ Chip: الخلفية - المختار - لون النص - الحد
    chipTheme: ChipThemeData(backgroundColor: lightSurfaceAlt, selectedColor: lightChipSelected, labelStyle: const TextStyle(color: lightText), secondaryLabelStyle: const TextStyle(color: lightText), side: const BorderSide(color: lightBorder)),
  );

  /// الثيم الداكن للتطبيق.
  static final darkTheme = ThemeData(
  brightness: Brightness.dark,
  primaryColor: primaryDark,
  // ✅ إضافة colorScheme صريحة
  colorScheme: ColorScheme.dark(
    primary: primaryDark,
    onPrimary: Colors.white,
    surface: darkSurface,
    onSurface: darkText,
    secondary: lightSecondary,
    onSecondary: Colors.white,
  ),
  scaffoldBackgroundColor: darkBackground,
  fontFamily: 'Cairo',
  inputDecorationTheme: _inputTheme(Colors.white, Colors.white.withOpacity(0.05), Colors.transparent),
  elevatedButtonTheme: _buttonTheme(primaryDark, Colors.white, elevation: 10),
);

  /// ثيم حقول الإدخال: textColor للنص والتركيز، fill للخلفية، borderColor للحد.
  static InputDecorationTheme _inputTheme(Color textColor, Color fill, Color borderColor) => InputDecorationTheme(
    filled: true,
    // خلفية الحقل
    fillColor: fill,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: borderColor)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: borderColor)),
    // حد الحقل عند التركيز عليه
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: textColor, width: 1.4)),
    // لون عنوان الحقل (Label)
    labelStyle: TextStyle(color: textColor.withOpacity(0.8)),
    // لون النص التوضيحي (Hint)
    hintStyle: TextStyle(color: textColor.withOpacity(0.65)),
  );

  /// ثيم الأزرار المرتفعة: color خلفية الزر، foreground لون النص، والزر المعطّل بشفافية.
  static ElevatedButtonThemeData _buttonTheme(Color color, Color foreground, {double elevation = 3}) => ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: foreground, disabledBackgroundColor: color.withOpacity(0.35), disabledForegroundColor: foreground.withOpacity(0.7), padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), elevation: elevation, shadowColor: color.withOpacity(elevation == 10 ? 0.4 : 0.2)),
  );
}
