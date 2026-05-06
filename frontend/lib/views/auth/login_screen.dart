import 'package:flutter/material.dart';
import '../../services/api_service.dart';

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

  void _handleLogin() async {
    // 1. التأكد إن الحقول مش فاضية
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('برجاء إدخال البريد الإلكتروني وكلمة المرور')),
      );
      return;
    }

    setState(() => _isLoading = true);
    
    try {
      final result = await _apiService.login(
        _emailController.text.trim(),
        _passwordController.text,
      );
      
      // 2. إظهار رسالة النجاح
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] ?? 'تم الدخول بنجاح'),
            backgroundColor: Colors.green,
          ),
        );

        // 🔥 3. السطر السحري: الانتقال لصفحة الـ Dashboard وحذف صفحة اللوجن من الـ Stack
        // ده اللي كان ناقصك يا هندسة عشان البرنامج يفتح
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception:', '')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // لوجو البرنامج أو أيقونة شيك
              const Icon(Icons.account_balance_wallet_rounded, size: 80, color: Color(0xFF1A237E)),
              const SizedBox(height: 20),
              const Text(
                'IslamApp 1.0',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF1A237E)),
              ),
              const SizedBox(height: 10),
              Text('مرحباً بك في نظامك المالي ', style: TextStyle(color: Colors.grey[600])),
              const SizedBox(height: 40),
              
              // حقل الإيميل
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 20),
              
              // حقل الباسورد
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              const SizedBox(height: 30),
              
              // زرار الدخول
              _isLoading 
                ? const CircularProgressIndicator() 
                : ElevatedButton(
                    onPressed: _handleLogin,
                    child: const Text('تسجيل الدخول'),
                  ),
              
              const SizedBox(height: 20),
              TextButton(
                onPressed: () {
                  // هنا هنضيف صفحة التسجيل لاحقاً
                },
                child: const Text('ليس لديك حساب؟ أنشئ حساباً الآن'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}