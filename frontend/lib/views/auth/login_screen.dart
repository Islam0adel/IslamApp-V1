// frontend/lib/views/auth/login_screen.dart
import '../../services/cache_partitions.dart';
import '../../core/theme.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';
import '../../services/permissions_service.dart';
import '../dashboard/home_page.dart';
import 'verify_email_screen.dart';
import '../../main.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/web_loading_helper.dart';
import '../widgets/app_loading_screen.dart';

// شاشة تسجيل الدخول
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

// حالة الويدجت LoginScreen: تدير بيانات الشاشة وتفاعلاتها
class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  // Nodes للتنقل بزر انتر
  final FocusNode _emailNode = FocusNode();
  final FocusNode _passNode = FocusNode();

  late AnimationController _animController;
  final _apiService = ApiService();
  bool _isLoading = false;
  bool _rememberMe = false;
  bool _isSyncing = false;

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..forward();

    // ⭐ إخفاء شاشة التحميل بعد أول frame من LoginScreen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      hideWebLoadingScreen();
    });
  }

  // يحمّل بيانات الدخول المحفوظة
  void _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _emailController.text = prefs.getString('saved_email') ?? '';
      _passwordController.text = prefs.getString('saved_password') ?? '';
      _rememberMe = prefs.getBool('remember_me') ?? false;
    });
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    _emailNode.dispose();
    _passNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  // ينفذ تسجيل الدخول
  void _handleLogin() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      _showSnackBar('برجاء ملء البيانات', AppTheme.warningOrangeFor(context));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final result = await _apiService.login(
        _emailController.text.trim(),
        _passwordController.text,
      );

      // ⭐ فحص حالة الحساب
      final userStatus =
          (result['user_status'] ?? 'active').toString().toLowerCase();
      if (userStatus == 'pending') {
        _showSnackBar(
          'حسابك قيد المراجعة. اضغط "إنشاء حساب" لإكمال التسجيل.',
          AppTheme.warningOrangeFor(context),
        );
        await FirebaseAuth.instance.signOut();
        return;
      }
      if (userStatus == 'suspended') {
        _showSnackBar(
          'تم إيقاف حسابك. يرجى التواصل مع الإدارة.',
          AppTheme.dangerStrongFor(context),
        );
        await FirebaseAuth.instance.signOut();
        return;
      }

      // ⭐ فحص التحقق من الإيميل
      final requiresVerification =
          result['requires_email_verification'] == true;
      final emailVerified = result['email_verified'] == true;
      if (requiresVerification && !emailVerified) {
        final email = (result['email'] ?? '').toString();
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => VerifyEmailScreen(email: email),
          ),
        );
        return;
      }

      // ⭐ حفظ البيانات
      final prefs = await SharedPreferences.getInstance();
      if (_rememberMe) {
        await prefs.setString('saved_email', _emailController.text.trim());
        await prefs.setString('saved_password', _passwordController.text);
        await prefs.setBool('remember_me', true);
      } else {
        await prefs.remove('saved_email');
        await prefs.remove('saved_password');
        await prefs.setBool('remember_me', false);
      }

      await prefs.setString('user_name', result['name'] ?? '');
      await prefs.setString('company_name', result['company_name'] ?? '');
      await prefs.setString('company_code', result['company_code'] ?? '');
      await prefs.setString('job_code', result['job_code'] ?? '1');
      await prefs.setString('job_title', result['job_title'] ?? '');
      await prefs.setString('role', result['role'] ?? 'employee');
      await prefs.setString(
          'user_email', result['email'] ?? _emailController.text.trim());
      // ⭐ branch_code (لمشكلة الفرع)
      if ((result['branch_code'] ?? '').toString().isNotEmpty) {
        await prefs.setString('selected_branch_code', result['branch_code']);
      }

      await CachePartitions.activate(
          FirebaseAuth.instance.currentUser!.uid, result['company_code'] ?? '');
      PermissionsService().resetForCachePartition();

      // ⭐ حدّث الدور في PermissionsService فوراً
      PermissionsService().setRole(result['role']?.toString());

      // ⭐ حدّث الفروع المسموحة فوراً (قبل Firestore listener)
      final allowedBranches = result['allowed_branches'];
      if (allowedBranches is List) {
        PermissionsService().setAllowedBranches(
          allowedBranches.map((e) => e.toString()).toList(),
        );
      }

      initializeGlobalListener(result['company_code'] ?? '');

      // ⭐ انتظر المزامنة الأولى (بحد أقصى 15s) قبل الانتقال لـ HomePage
      if (mounted) setState(() => _isSyncing = true);

      // ⭐ وقت بداية عرض الـ Overlay (عشان نضمن حد أدنى للأنيميشن)
      final overlayStartTime = DateTime.now();

      await waitForSyncToComplete(
        timeout: const Duration(seconds: 10),
      );

      // ⭐ ضمان عرض الأنيميشن لمدة كافية (1500ms) حتى لو sync خلصت بسرعة
      const minDisplayTime = Duration(milliseconds: 1500);
      final elapsed = DateTime.now().difference(overlayStartTime);
      if (elapsed < minDisplayTime) {
        await Future.delayed(minDisplayTime - elapsed);
      }

      if (!mounted) return;
      setState(() => _isSyncing = false);

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HomePage(
            userName: result['name'] ?? '',
            companyName: result['company_name'] ?? '',
            companyCode: result['company_code'] ?? '',
          ),
        ),
      );
    } catch (e) {
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSyncing = false;
        });
      }
    }
  }

  // يعرض رسالة سريعة بالنص واللون المحددين
  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(msg, textAlign: TextAlign.center),
          backgroundColor: color),
    );
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ⭐ المحتوى الأصلي في Container
          Container(
            height: double.infinity,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: AppTheme.authGradient(context),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 25),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // أنميشن الشعار
                    FadeTransition(
                      opacity: _animController,
                      child: Column(
                        children: [
                          // ⭐ اللوجو الجديد بدلاً من أيقونة القفل
                          Image.asset(
                            'assets/images/app_icon.png',
                            width: 100,
                            height: 100,
                            cacheWidth: 260,
                            cacheHeight: 260,
                          ),
                          const SizedBox(height: 0),
                          // ⭐ النص الجديد
                          Text(
                            'Islam App',
                            style: TextStyle(
                              color: AppTheme.textMainFor(context),
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 5),
                          // النص الفرعي (تسجيل الدخول)
                          Text(
                            'تسجيل الدخول',
                            style: TextStyle(
                              color: AppTheme.textSoftFor(context),
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),

                    // الكارت الزجاجي
                    GlassCard(
                      child: Column(
                        children: [
                          _buildAnimatedField(
                            index: 1,
                            icon: Icons.person_search_rounded,
                            label: 'البريد / الموبايل / اسم المستخدم',
                            controller: _emailController,
                            node: _emailNode,
                            nextNode: _passNode,
                          ),
                          const SizedBox(height: 20),
                          _buildAnimatedField(
                            index: 2,
                            icon: Icons.lock_outline,
                            label: 'كلمة المرور',
                            controller: _passwordController,
                            node: _passNode,
                            isPass: true,
                            isLast: true,
                          ),

                          const SizedBox(height: 10),

                          // خيار تذكرني ونسيت كلمة المرور
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Checkbox(
                                    value: _rememberMe,
                                    checkColor: AppTheme.checkboxCheck(context),
                                    activeColor:
                                        AppTheme.checkboxActive(context),
                                    onChanged: (val) =>
                                        setState(() => _rememberMe = val!),
                                  ),
                                  Text('تذكرني',
                                      style: TextStyle(
                                          color: AppTheme.textSoftFor(context),
                                          fontSize: 13)),
                                ],
                              ),
                              TextButton(
                                onPressed: () {
                                  Navigator.pushNamed(
                                      context, '/forgot-password');
                                },
                                child: Text('نسيت كلمة السر؟',
                                    style: TextStyle(
                                        color: AppTheme.textSoftFor(context),
                                        fontSize: 13)),
                              ),
                            ],
                          ),

                          const SizedBox(height: 25),

                          // زر الدخول
                          SizedBox(
                            width: double.infinity,
                            child: _isLoading
                                ? Center(
                                    child: CircularProgressIndicator(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimary))
                                : ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          AppTheme.authActionBackground(
                                              context),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 15),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(15)),
                                      side: BorderSide(
                                          color: AppTheme.inputBorder(context)),
                                    ),
                                    onPressed: _handleLogin,
                                    child: Text(
                                      'دخول',
                                      style: TextStyle(
                                          fontSize: 20,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimary,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 30),

                    // رابط إنشاء حساب
                    FadeTransition(
                      opacity: _animController,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('ليس لديك حساب؟',
                              style: TextStyle(
                                  color: AppTheme.textSoftFor(context))),
                          TextButton(
                            onPressed: () =>
                                Navigator.pushNamed(context, '/register'),
                            child: Text(
                              'إنشاء حساب جديد',
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 40),
                    Text(
                      'executed by Islam Adel',
                      style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontSize: 12,
                          fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ⭐⭐ شاشة تحميل المزامنة (نفس شكل HTML) ⭐⭐
          if (_isSyncing)
            const Positioned.fill(
              child: AppLoadingScreen(),
            ),
        ],
      ),
    );
  }

  // دالة بناء الخانات بالأنميشن والتنقل بزر Enter
  // يبني حقل إدخال متحرك
  Widget _buildAnimatedField({
    required int index,
    required IconData icon,
    required String label,
    required TextEditingController controller,
    required FocusNode node,
    FocusNode? nextNode,
    bool isPass = false,
    bool isLast = false,
  }) {
    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        final slide =
            Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
                .animate(CurvedAnimation(
          parent: _animController,
          curve: Interval(0.4 + (index * 0.1), 1.0, curve: Curves.easeOut),
        ));

        return SlideTransition(
          position: slide,
          child: TextField(
            controller: controller,
            focusNode: node,
            obscureText: isPass,
            style: TextStyle(color: AppTheme.textMainFor(context)),
            textInputAction:
                isLast ? TextInputAction.done : TextInputAction.next,
            onSubmitted: (_) {
              if (isLast) {
                _handleLogin();
              } else {
                FocusScope.of(context).requestFocus(nextNode);
              }
            },
            decoration: InputDecoration(
              prefixIcon: Icon(icon, color: AppTheme.textSoftFor(context)),
              labelText: label,
              labelStyle: TextStyle(color: AppTheme.textSoftFor(context)),
              filled: true,
              fillColor: AppTheme.inputFill(context),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide(color: AppTheme.inputBorder(context)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide(color: AppTheme.inputFocus(context)),
              ),
            ),
          ),
        );
      },
    );
  }
}
