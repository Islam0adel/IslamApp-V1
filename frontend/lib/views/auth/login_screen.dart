import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart'; 
import '../../services/api_service.dart';
import '../dashboard/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _apiService = ApiService();
  bool _isLoading = false;
  bool _rememberMe = false;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials(); // تحميل البيانات عند تشغيل الصفحة
  }

  void _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _emailController.text = prefs.getString('saved_email') ?? '';
      _passwordController.text = prefs.getString('saved_password') ?? '';
      _rememberMe = prefs.getBool('remember_me') ?? false;
    });
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

      // منطق تذكرني
      final prefs = await SharedPreferences.getInstance();
      if (_rememberMe) {
        await prefs.setString('saved_email', _emailController.text.trim());
        await prefs.setString('saved_password', _passwordController.text);
        await prefs.setBool('remember_me', true);
        await prefs.setString('user_name', result['name']); // حفظ الاسم للدخول التلقائي
        await prefs.setString('company_name', result['company_name'] ?? 'شركتي');
      } else {
        await prefs.remove('saved_email');
        await prefs.remove('saved_password');
        await prefs.setBool('remember_me', false);
      }

      if (mounted) {
        _showSnackBar('أهلاً بك: ${result['name']}', Colors.green);
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => HomePage(
              userName: result['name'],
              companyName: result['company_name'] ?? 'شركتي',
              companyCode: result['company_code'],
            ),
          ),
        );
      }
    } catch (e) {
      _showSnackBar(e.toString(), Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // دالة نسيت كلمة المرور
  void _handleForgotPassword() async {
    if (_emailController.text.isEmpty) {
      _showSnackBar('اكتب بريدك الإلكتروني أولاً في الخانة فوق', Colors.orange);
      return;
    }
    
    setState(() => _isLoading = true);
    try {
      await _apiService.resetPassword(_emailController.text.trim());
      _showSnackBar('تم إرسال رابط استعادة كلمة المرور لبريدك', Colors.green);
    } catch (e) {
      _showSnackBar(e.toString(), Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1A237E), Color(0xFF3949AB)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 80),
              const Text('IslamApp V1.0', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 50),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GlassCard(
                  child: Column(
                    children: [
                      const Text('تسجيل الدخول', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(height: 25),
                      _buildTextField(Icons.email, 'البريد الإلكتروني', _emailController),
                      const SizedBox(height: 15),
                      _buildTextField(Icons.lock, 'كلمة المرور', _passwordController, obscure: true),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Checkbox(
                                value: _rememberMe,
                                onChanged: (v) => setState(() => _rememberMe = v!),
                                side: const BorderSide(color: Colors.white70),
                              ),
                              const Text('تذكرني', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                          TextButton(
                            onPressed: _handleForgotPassword, // تم الربط
                            child: const Text('نسيت كلمة المرور؟', style: TextStyle(color: Colors.white70, fontSize: 12)),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 20),
                      _isLoading 
                        ? const CircularProgressIndicator(color: Colors.white)
                        : SizedBox(
                            width: double.infinity,
                            height: 55,
                            child: ElevatedButton(
                              onPressed: _handleLogin,
                              child: const Text('دخول', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ),
                          ),
                      
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('ليس لديك حساب؟', style: TextStyle(color: Colors.white70)),
                          TextButton(
                            onPressed: () => Navigator.pushNamed(context, '/register'),
                            child: const Text('إنشاء حساب جديد', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 50),
              const Text('executed by Islam Adel', style: TextStyle(color: Colors.white54, fontSize: 13, fontStyle: FontStyle.italic)),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(IconData icon, String hint, TextEditingController controller, {bool obscure = false}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: Colors.white70),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white54),
        filled: true,
        fillColor: Colors.white.withOpacity(0.1),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
      ),
    );
  }
}