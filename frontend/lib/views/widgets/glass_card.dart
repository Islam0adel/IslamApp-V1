import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme.dart';

/// ============================================================================
///  GlassStyle  —  المرجع الوحيد للكروت الزجاجية والتأثيرات
///  ملاحظة: غيّر قيم التمويه والشفافية والحواف هنا لتعديل شكل الزجاج في التطبيق كله.
///  الدوال المنتهية بـ For(context) هي التي تستخدمها الصفحات حتى تتبدل تلقائيًا مع الثيم.
/// ============================================================================
///  القاعدة:
///   • أي شفافية / حد / فاصل / خلفية صندوق داخل الكروت بتتغير من هنا.
///   • ألوان النصوص والحالات والتدرجات الأساسية في ملف theme.dart.
///
///  الأقسام:
///   1) إعدادات الكارت الزجاجي (التمويه - الزوايا - الحدود - الحشو)
///   2) خلفيات الصناديق الداخلية (أبيض شفاف بدرجات مختلفة)
///   3) الحدود والفواصل (خطوط بيضاء شفافة)
///   4) خلفيات وحدود "الحالات" (نجاح - خطر - تحذير...) وهي مشتقة من ألوان theme.dart
/// ============================================================================
class GlassStyle {
  // ==========================================================================
  // 1) إعدادات الكارت الزجاجي (GlassCard)
  // ==========================================================================

  /// قوة التمويه (Blur) خلف الكارت. زوّدها = الزجاج أكتر ضبابية.
  static const double blur = 15;

  /// استدارة زوايا الكارت.
  static const double radius = 25;

  /// سمك حد الكارت.
  static const double borderWidth = 1.5;

  /// الحشو الداخلي الافتراضي للكارت.
  static const EdgeInsets padding = EdgeInsets.all(20);

  /// خلفية الكارت في الوضع الداكن (أسود شفافية 40%).
  static const Color cardFillDark = Color(0x66000000);

  /// شفافية خلفية الكارت في الوضع الفاتح (بتتطبق على لون surface من theme.dart).
  static const double cardFillLightOpacity = 0.88;

  /// حد الكارت في الوضع الداكن (أبيض شفافية 20%).
  static const Color cardBorderDark = Color(0x33FFFFFF);

  /// شفافية حد الكارت في الوضع الفاتح (بتتطبق على لون border من theme.dart).
  static const double cardBorderLightOpacity = 0.9;

  /// لون خلفية الكارت حسب الوضع (فاتح / داكن).
  static Color cardFill(BuildContext context) => AppTheme.isDark(context)
      ? cardFillDark
      : AppTheme.surface(context).withOpacity(cardFillLightOpacity);

  /// لون حد الكارت حسب الوضع (فاتح / داكن).
  static Color cardBorder(BuildContext context) => AppTheme.isDark(context)
      ? cardBorderDark
      : AppTheme.border(context).withOpacity(cardBorderLightOpacity);

  // ==========================================================================
  // 2) خلفيات الصناديق الداخلية (تتكيف تلقائيًا مع الوضع)
  // ==========================================================================

  // الدوال التالية هي البديل المستخدم في الصفحات: في الوضع الداكن تحتفظ
  // بنفس الشفافيات الأصلية، وفي الوضع الفاتح تستخدم درجات سطح وحدود من theme.dart.
  static Color fill03For(BuildContext context) => AppTheme.isDark(context) ? fill03 : AppTheme.surfaceAlt(context).withOpacity(0.28);
  static Color fill04For(BuildContext context) => AppTheme.isDark(context) ? fill04 : AppTheme.surfaceAlt(context).withOpacity(0.34);
  static Color fill05For(BuildContext context) => AppTheme.isDark(context) ? fill05 : AppTheme.surface(context).withOpacity(0.76);
  static Color fill06For(BuildContext context) => AppTheme.isDark(context) ? fill06 : AppTheme.surface(context).withOpacity(0.80);
  static Color fill08For(BuildContext context) => AppTheme.isDark(context) ? fill08 : AppTheme.surface(context).withOpacity(0.86);
  static Color fill10For(BuildContext context) => AppTheme.isDark(context) ? fill10 : AppTheme.surfaceAlt(context).withOpacity(0.78);
  static Color fill12For(BuildContext context) => AppTheme.isDark(context) ? fill12 : AppTheme.surfaceAlt(context).withOpacity(0.86);
  static Color fill15For(BuildContext context) => AppTheme.isDark(context) ? fill15 : AppTheme.surfaceAlt(context).withOpacity(0.92);
  static Color fill20For(BuildContext context) => AppTheme.isDark(context) ? fill20 : AppTheme.surfaceAlt(context);
  static Color line05For(BuildContext context) => AppTheme.isDark(context) ? line05 : AppTheme.border(context).withOpacity(0.30);
  static Color line10For(BuildContext context) => AppTheme.isDark(context) ? line10 : AppTheme.border(context).withOpacity(0.48);
  static Color line20For(BuildContext context) => AppTheme.isDark(context) ? line20 : AppTheme.border(context).withOpacity(0.72);
  static Color line24For(BuildContext context) => AppTheme.isDark(context) ? line24 : AppTheme.border(context).withOpacity(0.88);
  static Color switchTrackOffFor(BuildContext context) => AppTheme.isDark(context) ? switchTrackOff : AppTheme.border(context);

  // ==========================================================================
  // خلفيات الصناديق الأصلية للوضع الداكن (محفوظة للتوافق مع أي استخدام قديم)
  //    الرقم = نسبة الأبيض. كل ما زاد الرقم، الصندوق بيظهر أوضح.
  // ==========================================================================

  /// أبيض 3%: خلفية خفيفة جداً — حقول الإدخال والأزرار المحددة بحد.
  static const Color fill03 = Color(0x08FFFFFF);

  /// أبيض 4%: دائرة زخرفية خفيفة في خلفية الصفحة.
  static const Color fill04 = Color(0x0AFFFFFF);

  /// أبيض 5%: الأكثر استخداماً — خلفية الصناديق الداخلية وصفوف القوائم والـ Card.
  static const Color fill05 = Color(0x0DFFFFFF);

  /// أبيض 6%: خلفية صندوق بيانات.
  static const Color fill06 = Color(0x0FFFFFFF);

  /// أبيض 8%: خلفية صندوق بارز قليلاً.
  static const Color fill08 = Color(0x14FFFFFF);

  /// أبيض 10%: رأس الجداول (DataTable) والأزرار غير المختارة وصناديق التمييز.
  static const Color fill10 = Color(0x1AFFFFFF);

  /// أبيض 12%: صناديق ملخصات وبطاقات بارزة.
  static const Color fill12 = Color(0x1FFFFFFF);

  /// أبيض 15%: خلفية عنصر بارز.
  static const Color fill15 = Color(0x26FFFFFF);

  /// أبيض 20%: زر وضع غير التعديل (يوم عادي).
  static const Color fill20 = Color(0x33FFFFFF);

  // ==========================================================================
  // 3) الحدود والفواصل
  // ==========================================================================

  /// أبيض 5%: خط فاصل خفيف بين الصفوف.
  static const Color line05 = Color(0x0DFFFFFF);

  /// أبيض 10%: حد الصناديق الداخلية + الفواصل (Divider) الخفيفة.
  static const Color line10 = Color(0x1AFFFFFF);

  /// أبيض 20%: حد واضح للصناديق.
  static const Color line20 = Color(0x33FFFFFF);

  /// أبيض 24%: حد وفواصل أوضح (Divider - الفواصل الرأسية - حدود الحقول).
  static const Color line24 = Color(0x3DFFFFFF);

  /// مسار مفتاح التبديل (Switch) عندما يكون غير مفعّل.
  static const Color switchTrackOff = Color(0x3DFFFFFF);

  // ==========================================================================
  // 4) خلفيات وحدود الحالات (مشتقة من ألوان theme.dart — لو غيرت اللون هناك بيتغير هنا تلقائياً)
  // ==========================================================================

  // ---- المميز (accent) ----
  // في Light Mode نستخدم أزرق هادئ بدل السماوي الفاقع، وفي Dark Mode نحتفظ بالأصل.
  static Color accentFill10For(BuildContext context) => (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context)).withOpacity(0.1);
  static Color accentFill15For(BuildContext context) => (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context)).withOpacity(0.15);
  static Color accentFill20For(BuildContext context) => (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context)).withOpacity(0.2);
  static Color accentBorder30For(BuildContext context) => (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context)).withOpacity(0.3);
  static Color accentBorder40For(BuildContext context) => (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context)).withOpacity(0.4);
  /// خلفية مميزة خفيفة 10%.
  static Color get accentFill10 => AppTheme.accent.withOpacity(0.1);
  /// خلفية مميزة 15% (دائرة أيقونة).
  static Color get accentFill15 => AppTheme.accent.withOpacity(0.15);
  /// خلفية مميزة 20% (دائرة أيقونة).
  static Color get accentFill20 => AppTheme.accent.withOpacity(0.2);
  /// حد مميز 30%.
  static Color get accentBorder30 => AppTheme.accent.withOpacity(0.3);
  /// حد مميز 40%.
  static Color get accentBorder40 => AppTheme.accent.withOpacity(0.4);

  // ألوان الحالات التكيفية: ألوان أهدأ في الوضع الفاتح مع الاحتفاظ بالأصل في الداكن.
  static Color successFill05For(BuildContext context) => AppTheme.successFor(context).withOpacity(0.05);
  static Color successFill10For(BuildContext context) => AppTheme.successFor(context).withOpacity(0.1);
  static Color successFill15For(BuildContext context) => AppTheme.successFor(context).withOpacity(0.15);
  static Color successBorder30For(BuildContext context) => AppTheme.successFor(context).withOpacity(0.3);
  static Color successBorder40For(BuildContext context) => AppTheme.successFor(context).withOpacity(0.4);
  static Color dangerBorder40For(BuildContext context) => AppTheme.dangerFor(context).withOpacity(0.4);
  static Color warningFill15For(BuildContext context) => AppTheme.warningFor(context).withOpacity(0.15);
  static Color warningFill20For(BuildContext context) => AppTheme.warningFor(context).withOpacity(0.2);
  static Color warningBorder50For(BuildContext context) => AppTheme.warningFor(context).withOpacity(0.5);
  static Color warningOrangeFill20For(BuildContext context) => AppTheme.warningOrangeFor(context).withOpacity(0.2);
  static Color warningOrangeFill30For(BuildContext context) => AppTheme.warningOrangeFor(context).withOpacity(0.3);
  static Color warningOrangeSoftFill15For(BuildContext context) => AppTheme.warningOrangeSoftFor(context).withOpacity(0.15);
  static Color warningOrangeSoftBorder60For(BuildContext context) => AppTheme.warningOrangeSoftFor(context).withOpacity(0.6);
  static Color extraPurpleBorder30For(BuildContext context) => AppTheme.extraPurpleFor(context).withOpacity(0.3);
  static Color neutralFill15For(BuildContext context) => AppTheme.neutralFor(context).withOpacity(0.15);
  static Color neutralBorder30For(BuildContext context) => AppTheme.neutralFor(context).withOpacity(0.3);

  // ---- النجاح (success) ----
  /// خلفية نجاح 5% (تدرج خفيف).
  static Color get successFill05 => AppTheme.success.withOpacity(0.05);
  /// خلفية نجاح 10%.
  static Color get successFill10 => AppTheme.success.withOpacity(0.1);
  /// خلفية نجاح 15% (شارات - صناديق الإيراد).
  static Color get successFill15 => AppTheme.success.withOpacity(0.15);
  /// حد نجاح 30%.
  static Color get successBorder30 => AppTheme.success.withOpacity(0.3);
  /// حد نجاح 40%.
  static Color get successBorder40 => AppTheme.success.withOpacity(0.4);

  // ---- الخطر (danger) ----
  /// حد خطر 40%.
  static Color get dangerBorder40 => AppTheme.danger.withOpacity(0.4);

  // ---- التحذير (warning) ----
  /// خلفية تحذير 15%.
  static Color get warningFill15 => AppTheme.warning.withOpacity(0.15);
  /// خلفية تحذير 20% (الكارت الحالي في القائمة).
  static Color get warningFill20 => AppTheme.warning.withOpacity(0.2);
  /// حد تحذير 50%.
  static Color get warningBorder50 => AppTheme.warning.withOpacity(0.5);

  // ---- التحذير البرتقالي ----
  /// خلفية برتقالية 20%.
  static Color get warningOrangeFill20 => AppTheme.warningOrange.withOpacity(0.2);
  /// خلفية برتقالية 30% (زر وضع التعديل).
  static Color get warningOrangeFill30 => AppTheme.warningOrange.withOpacity(0.3);

  // ---- البرتقالي الفاتح ----
  /// خلفية برتقالية فاتحة 15%.
  static Color get warningOrangeSoftFill15 => AppTheme.warningOrangeSoft.withOpacity(0.15);
  /// حد برتقالي فاتح 60%.
  static Color get warningOrangeSoftBorder60 => AppTheme.warningOrangeSoft.withOpacity(0.6);

  // ---- بنفسجي ----
  /// حد بنفسجي 30%.
  static Color get extraPurpleBorder30 => AppTheme.extraPurple.withOpacity(0.3);

  // ---- محايد (رمادي) ----
  /// خلفية رمادية 15%.
  static Color get neutralFill15 => AppTheme.neutral.withOpacity(0.15);
  /// حد رمادي 30%.
  static Color get neutralBorder30 => AppTheme.neutral.withOpacity(0.3);
}

/// الكارت الزجاجي المستخدم في كل التطبيق — كل ألوانه وتأثيراته من GlassStyle فوق.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  const GlassCard({
    super.key,
    required this.child,
    this.margin,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GlassStyle.radius),
        child: BackdropFilter(
          // تأثير التمويه (الزجاج)
          filter: ImageFilter.blur(sigmaX: GlassStyle.blur, sigmaY: GlassStyle.blur),
          child: Container(
            padding: padding ?? GlassStyle.padding,
            decoration: BoxDecoration(
              // خلفية الكارت
              color: GlassStyle.cardFill(context),
              borderRadius: BorderRadius.circular(GlassStyle.radius),
              // حد الكارت
              border: Border.all(
                color: GlassStyle.cardBorder(context),
                width: GlassStyle.borderWidth,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
