// frontend/lib/views/widgets/glass_card.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme.dart';

// أنماط الزجاج: ألوان التعبئة والخطوط والحدود حسب الوضع
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

  // يعيد لون تعبئة الكارت الزجاجي
  /// لون خلفية الكارت حسب الوضع (فاتح / داكن).
  static Color cardFill(BuildContext context) => AppTheme.isDark(context)
      ? cardFillDark
      : AppTheme.surface(context).withValues(alpha: cardFillLightOpacity);

  // يعيد لون حد الكارت الزجاجي
  /// لون حد الكارت حسب الوضع (فاتح / داكن).
  static Color cardBorder(BuildContext context) => AppTheme.isDark(context)
      ? cardBorderDark
      : AppTheme.border(context).withValues(alpha: cardBorderLightOpacity);

  // ==========================================================================
  // 2) خلفيات الصناديق الداخلية (تتكيف تلقائيًا مع الوضع)
  // ==========================================================================

  // الدوال التالية هي البديل المستخدم في الصفحات: في الوضع الداكن تحتفظ
  // بنفس الشفافيات الأصلية، وفي الوضع الفاتح تستخدم درجات سطح وحدود من theme.dart.
  // يعيد لون تعبئة زجاجية بشفافية 3% حسب الوضع
  static Color fill03For(BuildContext context) => AppTheme.isDark(context)
      ? fill03
      : AppTheme.surfaceAlt(context).withValues(alpha: 0.28);

  // يعيد لون تعبئة زجاجية بشفافية 4% حسب الوضع
  static Color fill04For(BuildContext context) => AppTheme.isDark(context)
      ? fill04
      : AppTheme.surfaceAlt(context).withValues(alpha: 0.34);

  // يعيد لون تعبئة زجاجية بشفافية 5% حسب الوضع
  static Color fill05For(BuildContext context) => AppTheme.isDark(context)
      ? fill05
      : AppTheme.surface(context).withValues(alpha: 0.76);

  // يعيد لون تعبئة زجاجية بشفافية 6% حسب الوضع
  static Color fill06For(BuildContext context) => AppTheme.isDark(context)
      ? fill06
      : AppTheme.surface(context).withValues(alpha: 0.80);

  // يعيد لون تعبئة زجاجية بشفافية 8% حسب الوضع
  static Color fill08For(BuildContext context) => AppTheme.isDark(context)
      ? fill08
      : AppTheme.surface(context).withValues(alpha: 0.86);

  // يعيد لون تعبئة زجاجية بشفافية 10% حسب الوضع
  static Color fill10For(BuildContext context) => AppTheme.isDark(context)
      ? fill10
      : AppTheme.surfaceAlt(context).withValues(alpha: 0.78);

  // يعيد لون تعبئة زجاجية بشفافية 12% حسب الوضع
  static Color fill12For(BuildContext context) => AppTheme.isDark(context)
      ? fill12
      : AppTheme.surfaceAlt(context).withValues(alpha: 0.86);

  // يعيد لون تعبئة زجاجية بشفافية 15% حسب الوضع
  static Color fill15For(BuildContext context) => AppTheme.isDark(context)
      ? fill15
      : AppTheme.surfaceAlt(context).withValues(alpha: 0.92);

  // يعيد لون تعبئة زجاجية بشفافية 20% حسب الوضع
  static Color fill20For(BuildContext context) =>
      AppTheme.isDark(context) ? fill20 : AppTheme.surfaceAlt(context);

  // يعيد لون خط زجاجي بشفافية 5% حسب الوضع
  static Color line05For(BuildContext context) => AppTheme.isDark(context)
      ? line05
      : AppTheme.border(context).withValues(alpha: 0.30);

  // يعيد لون خط زجاجي بشفافية 10% حسب الوضع
  static Color line10For(BuildContext context) => AppTheme.isDark(context)
      ? line10
      : AppTheme.border(context).withValues(alpha: 0.48);

  // يعيد لون خط زجاجي بشفافية 20% حسب الوضع
  static Color line20For(BuildContext context) => AppTheme.isDark(context)
      ? line20
      : AppTheme.border(context).withValues(alpha: 0.72);

  // يعيد لون خط زجاجي بشفافية 24% حسب الوضع
  static Color line24For(BuildContext context) => AppTheme.isDark(context)
      ? line24
      : AppTheme.border(context).withValues(alpha: 0.88);

  // يعيد لون مسار المفتاح في حالة الإيقاف حسب الوضع
  static Color switchTrackOffFor(BuildContext context) =>
      AppTheme.isDark(context) ? switchTrackOff : AppTheme.border(context);

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
  // يعيد لون تعبئة التمييز بشفافية 10% حسب الوضع
  static Color accentFill10For(BuildContext context) =>
      (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context))
          .withValues(alpha: 0.1);

  // يعيد لون تعبئة التمييز بشفافية 15% حسب الوضع
  static Color accentFill15For(BuildContext context) =>
      (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context))
          .withValues(alpha: 0.15);

  // يعيد لون تعبئة التمييز بشفافية 20% حسب الوضع
  static Color accentFill20For(BuildContext context) =>
      (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context))
          .withValues(alpha: 0.2);

  // يعيد لون حد التمييز بشفافية 30% حسب الوضع
  static Color accentBorder30For(BuildContext context) =>
      (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context))
          .withValues(alpha: 0.3);

  // يعيد لون حد التمييز بشفافية 40% حسب الوضع
  static Color accentBorder40For(BuildContext context) =>
      (AppTheme.isDark(context) ? AppTheme.accent : AppTheme.accentFor(context))
          .withValues(alpha: 0.4);

  // يعيد لون تعبئة التمييز بشفافية 10%
  /// خلفية مميزة خفيفة 10%.
  static Color get accentFill10 => AppTheme.accent.withValues(alpha: 0.1);

  // يعيد لون تعبئة التمييز بشفافية 15%
  /// خلفية مميزة 15% (دائرة أيقونة).
  static Color get accentFill15 => AppTheme.accent.withValues(alpha: 0.15);

  // يعيد لون تعبئة التمييز بشفافية 20%
  /// خلفية مميزة 20% (دائرة أيقونة).
  static Color get accentFill20 => AppTheme.accent.withValues(alpha: 0.2);

  // يعيد لون حد التمييز بشفافية 30%
  /// حد مميز 30%.
  static Color get accentBorder30 => AppTheme.accent.withValues(alpha: 0.3);

  // يعيد لون حد التمييز بشفافية 40%
  /// حد مميز 40%.
  static Color get accentBorder40 => AppTheme.accent.withValues(alpha: 0.4);

  // ألوان الحالات التكيفية: ألوان أهدأ في الوضع الفاتح مع الاحتفاظ بالأصل في الداكن.
  // يعيد لون تعبئة النجاح بشفافية 5% حسب الوضع
  static Color successFill05For(BuildContext context) =>
      AppTheme.successFor(context).withValues(alpha: 0.05);

  // يعيد لون تعبئة النجاح بشفافية 10% حسب الوضع
  static Color successFill10For(BuildContext context) =>
      AppTheme.successFor(context).withValues(alpha: 0.1);

  // يعيد لون تعبئة النجاح بشفافية 15% حسب الوضع
  static Color successFill15For(BuildContext context) =>
      AppTheme.successFor(context).withValues(alpha: 0.15);

  // يعيد لون حد النجاح بشفافية 30% حسب الوضع
  static Color successBorder30For(BuildContext context) =>
      AppTheme.successFor(context).withValues(alpha: 0.3);

  // يعيد لون حد النجاح بشفافية 40% حسب الوضع
  static Color successBorder40For(BuildContext context) =>
      AppTheme.successFor(context).withValues(alpha: 0.4);

  // يعيد لون حد الخطر بشفافية 40% حسب الوضع
  static Color dangerBorder40For(BuildContext context) =>
      AppTheme.dangerFor(context).withValues(alpha: 0.4);

  // يعيد لون تعبئة التحذير بشفافية 15% حسب الوضع
  static Color warningFill15For(BuildContext context) =>
      AppTheme.warningFor(context).withValues(alpha: 0.15);

  // يعيد لون تعبئة التحذير بشفافية 20% حسب الوضع
  static Color warningFill20For(BuildContext context) =>
      AppTheme.warningFor(context).withValues(alpha: 0.2);

  // يعيد لون حد التحذير بشفافية 50% حسب الوضع
  static Color warningBorder50For(BuildContext context) =>
      AppTheme.warningFor(context).withValues(alpha: 0.5);

  // يعيد لون تعبئة التحذير البرتقالي بشفافية 20% حسب الوضع
  static Color warningOrangeFill20For(BuildContext context) =>
      AppTheme.warningOrangeFor(context).withValues(alpha: 0.2);

  // يعيد لون تعبئة التحذير البرتقالي بشفافية 30% حسب الوضع
  static Color warningOrangeFill30For(BuildContext context) =>
      AppTheme.warningOrangeFor(context).withValues(alpha: 0.3);

  // يعيد لون تعبئة التحذير البرتقالي الخفيف بشفافية 15% حسب الوضع
  static Color warningOrangeSoftFill15For(BuildContext context) =>
      AppTheme.warningOrangeSoftFor(context).withValues(alpha: 0.15);

  // يعيد لون حد التحذير البرتقالي الخفيف بشفافية 60% حسب الوضع
  static Color warningOrangeSoftBorder60For(BuildContext context) =>
      AppTheme.warningOrangeSoftFor(context).withValues(alpha: 0.6);

  // يعيد لون حد البنفسجي بشفافية 30% حسب الوضع
  static Color extraPurpleBorder30For(BuildContext context) =>
      AppTheme.extraPurpleFor(context).withValues(alpha: 0.3);

  // يعيد لون تعبئة المحايد بشفافية 15% حسب الوضع
  static Color neutralFill15For(BuildContext context) =>
      AppTheme.neutralFor(context).withValues(alpha: 0.15);

  // يعيد لون حد المحايد بشفافية 30% حسب الوضع
  static Color neutralBorder30For(BuildContext context) =>
      AppTheme.neutralFor(context).withValues(alpha: 0.3);

  // ---- النجاح (success) ----
  // يعيد لون تعبئة النجاح بشفافية 5%
  /// خلفية نجاح 5% (تدرج خفيف).
  static Color get successFill05 => AppTheme.success.withValues(alpha: 0.05);

  // يعيد لون تعبئة النجاح بشفافية 10%
  /// خلفية نجاح 10%.
  static Color get successFill10 => AppTheme.success.withValues(alpha: 0.1);

  // يعيد لون تعبئة النجاح بشفافية 15%
  /// خلفية نجاح 15% (شارات - صناديق الإيراد).
  static Color get successFill15 => AppTheme.success.withValues(alpha: 0.15);

  // يعيد لون حد النجاح بشفافية 30%
  /// حد نجاح 30%.
  static Color get successBorder30 => AppTheme.success.withValues(alpha: 0.3);

  // يعيد لون حد النجاح بشفافية 40%
  /// حد نجاح 40%.
  static Color get successBorder40 => AppTheme.success.withValues(alpha: 0.4);

  // ---- الخطر (danger) ----
  // يعيد لون حد الخطر بشفافية 40%
  /// حد خطر 40%.
  static Color get dangerBorder40 => AppTheme.danger.withValues(alpha: 0.4);

  // ---- التحذير (warning) ----
  // يعيد لون تعبئة التحذير بشفافية 15%
  /// خلفية تحذير 15%.
  static Color get warningFill15 => AppTheme.warning.withValues(alpha: 0.15);

  // يعيد لون تعبئة التحذير بشفافية 20%
  /// خلفية تحذير 20% (الكارت الحالي في القائمة).
  static Color get warningFill20 => AppTheme.warning.withValues(alpha: 0.2);

  // يعيد لون حد التحذير بشفافية 50%
  /// حد تحذير 50%.
  static Color get warningBorder50 => AppTheme.warning.withValues(alpha: 0.5);

  // ---- التحذير البرتقالي ----
  // يعيد لون تعبئة التحذير البرتقالي بشفافية 20%
  /// خلفية برتقالية 20%.
  static Color get warningOrangeFill20 =>
      AppTheme.warningOrange.withValues(alpha: 0.2);

  // يعيد لون تعبئة التحذير البرتقالي بشفافية 30%
  /// خلفية برتقالية 30% (زر وضع التعديل).
  static Color get warningOrangeFill30 =>
      AppTheme.warningOrange.withValues(alpha: 0.3);

  // ---- البرتقالي الفاتح ----
  // يعيد لون تعبئة التحذير البرتقالي الخفيف بشفافية 15%
  /// خلفية برتقالية فاتحة 15%.
  static Color get warningOrangeSoftFill15 =>
      AppTheme.warningOrangeSoft.withValues(alpha: 0.15);

  // يعيد لون حد التحذير البرتقالي الخفيف بشفافية 60%
  /// حد برتقالي فاتح 60%.
  static Color get warningOrangeSoftBorder60 =>
      AppTheme.warningOrangeSoft.withValues(alpha: 0.6);

  // ---- بنفسجي ----
  // يعيد لون حد البنفسجي بشفافية 30%
  /// حد بنفسجي 30%.
  static Color get extraPurpleBorder30 =>
      AppTheme.extraPurple.withValues(alpha: 0.3);

  // ---- محايد (رمادي) ----
  // يعيد لون تعبئة المحايد بشفافية 15%
  /// خلفية رمادية 15%.
  static Color get neutralFill15 => AppTheme.neutral.withValues(alpha: 0.15);

  // يعيد لون حد المحايد بشفافية 30%
  /// حد رمادي 30%.
  static Color get neutralBorder30 => AppTheme.neutral.withValues(alpha: 0.3);
}

// الكارت الزجاجي المستخدم في الشاشات
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

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GlassStyle.radius),
        child: BackdropFilter(
          // تأثير التمويه (الزجاج)
          filter: ImageFilter.blur(
              sigmaX: GlassStyle.blur, sigmaY: GlassStyle.blur),
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
