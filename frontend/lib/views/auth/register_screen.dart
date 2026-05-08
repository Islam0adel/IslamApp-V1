import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // تعريف الـ Controllers عشان ناخد الكلام من الخانات
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  
  final _apiService = ApiService();
  bool _isLoading = false;

  // الدالة اللي بتشغل الزرار وبتربط بالباك إند
  void _handleRegister() async {
    // 1. التأكد إن الخانات مش فاضية
    if (_nameController.text.isEmpty || 
        _emailController.text.isEmpty || 
        _passwordController.text.isEmpty || 
        _codeController.text.isEmpty) {
      _showSnackBar('برجاء ملء جميع الحقول', Colors.orange);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 2. مناداة دالة التسجيل من الـ ApiService
      await _apiService.register(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        companyCode: _codeController.text.trim(),
      );

      if (mounted) {
        _showSnackBar('تم إنشاء الحساب بنجاح! سجل دخولك الآن', Colors.green);
        // 3. الرجوع لصفحة اللوج إن بعد النجاح
        Navigator.pop(context); 
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('خطأ: ${e.toString()}', Colors.red);
      }
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
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
          child: Column(
            children: [
              const Text(
                'IslamApp V1.0',
                style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 30),
              
              GlassCard(
                child: Column(
                  children: [
                    const Text('إنشاء حساب جديد', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 25),
                    _buildField(Icons.person, 'الاسم ال', _nameController),
                    const SizedBox(height: 15),
                    _buildField(Icons.email, 'البريد الإلكتروني', _emailController),
                    const SizedBox(height: 15),
                    _buildField(Icons.lock, 'كلمة المرور', _passwordController, isPass: true),
                    const SizedBox(height: 15),
                    _buildField(Icons.business, 'كود الشركة (مثلاً: 01)', _codeController),
                    
                    const SizedBox(height: 30),
                    
                    _isLoading 
                      ? const CircularProgressIndicator(color: Colors.white)
                      : SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _handleRegister, // الزرار بقى شغال هنا
                            child: const Text('إنشاء الحساب', style: TextStyle(fontSize: 18)),
                          ),
                        ),
                    
                    const SizedBox(height: 15),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('لديك حساب بالفعل؟ سجل دخولك', style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 40),
              const Text(
                'executed by Islam Adel',
                style: TextStyle(color: Colors.white54, fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(IconData icon, String label, TextEditingController controller, {bool isPass = false}) {
    return TextField(
      controller: controller,
      obscureText: isPass,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: Colors.white70),
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white.withOpacity(0.3))),
        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
      ),
    );
  }
}