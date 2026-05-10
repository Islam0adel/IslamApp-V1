import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';
import '../dashboard/home_page.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  
  // Nodes للتنقل بزر انتر
  final FocusNode _emailNode = FocusNode();
  final FocusNode _passNode = FocusNode();

  late AnimationController _animController;
  final _apiService = ApiService();
  bool _isLoading = false;
  bool _rememberMe = false;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..forward();
  }

  void _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _emailController.text = prefs.getString('saved_email') ?? '';
      _passwordController.text = prefs.getString('saved_password') ?? '';
      _rememberMe = prefs.getBool('remember_me') ?? false;
    });
  }

  @override
  void dispose() {
    _emailNode.dispose();
    _passNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _handleLogin() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      _showSnackBar('برجاء ملء البيانات', Colors.orange);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final result = await _apiService.login(
        _emailController.text.trim(),
        _passwordController.text,
      );

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

      // حفظ بيانات المستخدم وصلاحياته (مهم جداً للخطوات الجاية)
      await prefs.setString('user_name', result['name']);
      await prefs.setString('company_name', result['company_name']);
      await prefs.setString('company_code', result['company_code']);
      await prefs.setString('job_code', result['job_code']); // حفظ كود الوظيفة
      await prefs.setString('job_title', result['job_title']); // حفظ مسمى الوظيفة

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => HomePage(
              userName: result['name'],
              companyName: result['company_name'],
              companyCode: result['company_code'],
            ),
          ),
        );
      }
    } catch (e) {
      _showSnackBar(e.toString(), Colors.redAccent);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg, textAlign: TextAlign.center), backgroundColor: color),
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        height: double.infinity,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Colors.indigo.shade900, Colors.black],
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
                  child: const Column(
                    children: [
                      Icon(Icons.lock_person_rounded, size: 90, color: Colors.white),
                      SizedBox(height: 15),
                      Text(
                        'تسجيل الدخول',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
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
                        icon: Icons.email_outlined,
                        label: 'البريد الإلكتروني',
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
                        isLast: true, // يضغط Enter يسجل دخول علطول
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
                                checkColor: Colors.black,
                                activeColor: Colors.white,
                                onChanged: (val) => setState(() => _rememberMe = val!),
                              ),
                              const Text('تذكرني', style: TextStyle(color: Colors.white70, fontSize: 13)),
                            ],
                          ),
                          TextButton(
                              onPressed: () {
                                Navigator.pushNamed(context, '/forgot-password'); // الانتقال لصفحة الاستعادة
                              },
                              child: const Text('نسيت كلمة السر؟', style: TextStyle(color: Colors.white70, fontSize: 13)),
                            ),
                        ],
                      ),

                      const SizedBox(height: 25),

                      // زر الدخول
                      SizedBox(
                        width: double.infinity,
                        child: _isLoading
                            ? const Center(child: CircularProgressIndicator(color: Colors.white))
                            : ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white.withOpacity(0.2),
                                  padding: const EdgeInsets.symmetric(vertical: 15),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                                  side: BorderSide(color: Colors.white.withOpacity(0.1)),
                                ),
                                onPressed: _handleLogin,
                                child: const Text(
                                  'دخول',
                                  style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold),
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
                      const Text('ليس لديك حساب؟', style: TextStyle(color: Colors.white70)),
                      TextButton(
                        onPressed: () => Navigator.pushNamed(context, '/register'),
                        child: const Text(
                          'إنشاء حساب جديد',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 40),
                const Text(
                  'executed by Islam Adel',
                  style: TextStyle(color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // دالة بناء الخانات بالأنميشن والتنقل بزر Enter
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
        final slide = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
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
            style: const TextStyle(color: Colors.white),
            textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
            onSubmitted: (_) {
              if (isLast) {
                _handleLogin();
              } else {
                FocusScope.of(context).requestFocus(nextNode);
              }
            },
            decoration: InputDecoration(
              prefixIcon: Icon(icon, color: Colors.white70),
              labelText: label,
              labelStyle: const TextStyle(color: Colors.white70),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: const BorderSide(color: Colors.white),
              ),
            ),
          ),
        );
      },
    );
  }
}