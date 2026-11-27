// frontend/lib/views/widgets/app_loading_screen.dart

import 'package:flutter/material.dart';

// شاشة تحميل التطبيق
class AppLoadingScreen extends StatefulWidget {
  const AppLoadingScreen({super.key});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<AppLoadingScreen> createState() => _AppLoadingScreenState();
}

// حالة الويدجت AppLoadingScreen: تدير بيانات الشاشة وتفاعلاتها
class _AppLoadingScreenState extends State<AppLoadingScreen>
    with TickerProviderStateMixin {
  static const String _appName = 'Islam App';

  late AnimationController _logoController;
  late AnimationController _textController;
  late AnimationController _dotsFadeController;
  late AnimationController _dotsPulseController;

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _logoController.forward();
    });

    _textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..forward();

    _dotsFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _dotsPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    Future.delayed(const Duration(milliseconds: 1000), () {
      if (!mounted) return;
      _dotsFadeController.forward();
      _dotsPulseController.repeat();
    });
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    _logoController.dispose();
    _textController.dispose();
    _dotsFadeController.dispose();
    _dotsPulseController.dispose();
    super.dispose();
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0a0e27),
            Color(0xFF020617),
            Color(0xFF0f172a),
          ],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      // ⭐⭐⭐ الحل الأساسي: إجبار LTR على الشاشة كلها
      // عشان "Islam App" يظهر بالترتيب الصح والنقط تترتب من الشمال لليمين
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // اللوجو
              FadeTransition(
                opacity: _logoController,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.6, end: 1.0).animate(
                    CurvedAnimation(
                      parent: _logoController,
                      curve: Curves.easeOutBack,
                    ),
                  ),
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    width: 120,
                    height: 120,
                    cacheWidth: 240,
                    cacheHeight: 240,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // النص "Islam App"
              _buildText(),

              const SizedBox(height: 20),

              // 4 نقط
              FadeTransition(
                opacity: _dotsFadeController,
                child: RepaintBoundary(child: _buildDots()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ⭐ النص: كل حرف ينزل من فوق بتأخير 100ms
  // يبني نص اسم التطبيق
  Widget _buildText() {
    final letters = _appName.split('');
    final nonSpaceIndices = <int>[];
    for (int i = 0; i < letters.length; i++) {
      if (letters[i] != ' ') nonSpaceIndices.add(i);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(letters.length, (index) {
        if (letters[index] == ' ') {
          return const SizedBox(width: 8);
        }

        final pos = nonSpaceIndices.indexOf(index);
        final startFraction = (pos * 100) / 1500.0;
        final endFraction = ((pos * 100) + 500) / 1500.0;
        final duration = endFraction - startFraction;

        return AnimatedBuilder(
          animation: _textController,
          builder: (context, _) {
            final t = _textController.value;
            final progress = ((t - startFraction) / duration).clamp(0.0, 1.0);
            final eased = Curves.easeOutBack.transform(progress);
            final translateY = (1 - eased) * -80;

            return Transform.translate(
              offset: Offset(0, translateY),
              child: Opacity(
                opacity: progress,
                child: Text(
                  letters[index],
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 1,
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }

  // ⭐ النقط: مسافات ثابتة (12px) بـ SizedBox بين كل نقطة
  // يبني نقاط التحميل
  Widget _buildDots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildDot(0),
        const SizedBox(width: 12),
        _buildDot(1),
        const SizedBox(width: 12),
        _buildDot(2),
        const SizedBox(width: 12),
        _buildDot(3),
      ],
    );
  }

  // يبني نقطة تحميل واحدة
  Widget _buildDot(int index) {
    // ⭐ حجم ثابت 20x20 — الـ scale بيتحرك جوه ومش بيأثر على المسافات
    const double containerSize = 20;
    const double dotSize = 9;
    final offset = index * 0.125;

    return SizedBox(
      width: containerSize,
      height: containerSize,
      child: Center(
        child: AnimatedBuilder(
          animation: _dotsPulseController,
          builder: (context, _) {
            final rawT = (_dotsPulseController.value + offset) % 1.0;
            final triangle = rawT < 0.5 ? rawT * 2 : (1 - rawT) * 2;
            final pulseValue = Curves.easeInOut.transform(triangle);

            return Transform.scale(
              scale: 1 + pulseValue * 0.35,
              child: Opacity(
                opacity: 0.3 + pulseValue * 0.7,
                child: Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.lerp(
                      const Color(0xFF60a5fa),
                      const Color(0xFFa78bfa),
                      pulseValue,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color.lerp(
                          const Color(0xFF60a5fa).withValues(alpha: 0.5),
                          const Color(0xFFa78bfa).withValues(alpha: 0.9),
                          pulseValue,
                        )!,
                        blurRadius: 8 + pulseValue * 8,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
