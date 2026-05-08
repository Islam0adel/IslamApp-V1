import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart'; // المسار الجديد اللي ظبطته
import '../../services/api_service.dart';
import '../dashboard/home_page.dart';

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
  bool _rememberMe = false; // خاصية تذكرني

  // دالة تسجيل الدخول
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
      // هنا هيظهر لك الخطأ الحقيقي اللي جاي من البايثون
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
              const Text(
                'IslamApp V1.0',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 2),
              ),
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
                      
                      // سطر تذكرني ونسيت كلمة المرور
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
                            onPressed: () {}, // هنربطها بدالة resetPassword لاحقاً
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
                      // زر إنشاء حساب (عشان تقدر تجرب)
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
              const Text(
                'executed by Islam Adel',
                style: TextStyle(color: Colors.white54, fontSize: 13, fontStyle: FontStyle.italic),
              ),
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