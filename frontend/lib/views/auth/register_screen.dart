import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> with TickerProviderStateMixin {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _compCodeController = TextEditingController();
  final _jobCodeController = TextEditingController(); // كود الوظيفة

  //Nodes للانتقال بزر انتر
  final FocusNode _nameNode = FocusNode();
  final FocusNode _emailNode = FocusNode();
  final FocusNode _passNode = FocusNode();
  final FocusNode _compNode = FocusNode();
  final FocusNode _jobNode = FocusNode();

  late AnimationController _animController;
  final _apiService = ApiService();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
  }

  @override
  void dispose() {
    _nameNode.dispose();
    _emailNode.dispose();
    _passNode.dispose();
    _compNode.dispose();
    _jobNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _handleRegister() async {
    if (_nameController.text.isEmpty || _emailController.text.isEmpty || 
        _passwordController.text.isEmpty || _compCodeController.text.isEmpty ||
        _jobCodeController.text.isEmpty) {
      _showSnackBar('برجاء ملء جميع الحقول بما فيها أكواد التفعيل', Colors.orange);
      return;
    }

    setState(() => _isLoading = true);
    try {
      // هنا هنعدل الـ ApiService لاحقاً ليدعم الـ jobCode
      await _apiService.register(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        companyCode: _compCodeController.text.trim(),
        jobCode: _jobCodeController.text.trim(), // الحقل الجديد
      );

      if (mounted) {
        _showSnackBar('تم إنشاء الحساب بنجاح كـ ${_jobCodeController.text}', Colors.green);
        Navigator.pop(context);
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
      // خلفية متدرجة تليق بالتصميم الزجاجي
      body: Container(
        height: double.infinity,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.indigo.shade900, Colors.black],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
          child: Column(
            children: [
              // أنميشن الشعار أو العنوان
              FadeTransition(
                opacity: _animController,
                child: const Column(
                  children: [
                    Icon(Icons.person_add_outlined, size: 80, color: Colors.white),
                    SizedBox(height: 10),
                    Text(
                      'إنشاء حساب جديد',
                      style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),

              // الكارت الزجاجي الذي يحتوي على الخانات
              GlassCard(
                child: Column(
                  children: [
                    _buildAnimatedField(
                      index: 1,
                      icon: Icons.person,
                      label: 'الاسم الكامل',
                      controller: _nameController,
                      node: _nameNode,
                      nextNode: _emailNode,
                    ),
                    _buildAnimatedField(
                      index: 2,
                      icon: Icons.email,
                      label: 'البريد الإلكتروني',
                      controller: _emailController,
                      node: _emailNode,
                      nextNode: _passNode,
                    ),
                    _buildAnimatedField(
                      index: 3,
                      icon: Icons.lock,
                      label: 'كلمة المرور',
                      controller: _passwordController,
                      node: _passNode,
                      nextNode: _compNode,
                      isPass: true,
                    ),
                    _buildAnimatedField(
                      index: 4,
                      icon: Icons.business,
                      label: 'كود الشركة',
                      controller: _compCodeController,
                      node: _compNode,
                      nextNode: _jobNode,
                    ),
                    _buildAnimatedField(
                      index: 5,
                      icon: Icons.badge,
                      label: 'كود الوظيفة (1، 200، 201، 99)',
                      controller: _jobCodeController,
                      node: _jobNode,
                      isLast: true, // هنا هيشغل الدالة علطول عند ضغط انتر
                    ),
                    
                    const SizedBox(height: 30),

                    // زر التسجيل مع حالة التحميل
                    SizedBox(
                      width: double.infinity,
                      child: _isLoading
                          ? const Center(child: CircularProgressIndicator(color: Colors.white))
                          : ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white.withOpacity(0.2),
                                padding: const EdgeInsets.symmetric(vertical: 15),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                              ),
                              onPressed: _handleRegister,
                              child: const Text('إتمام التسجيل', style: TextStyle(fontSize: 18, color: Colors.white)),
                            ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 20),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('لديك حساب بالفعل؟ سجل دخولك', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // دالة بناء الخانات مع الأنميشن وخاصية الانتقال (Enter)
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
        // تأثير انزلاق العناصر واحد تلو الآخر
        final slide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
            .animate(CurvedAnimation(
              parent: _animController,
              curve: Interval(0.2 + (index * 0.1), 1.0, curve: Curves.easeOut),
            ));

        return SlideTransition(
          position: slide,
          child: FadeTransition(
            opacity: _animController,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 15),
              child: TextField(
                controller: controller,
                focusNode: node,
                obscureText: isPass,
                style: const TextStyle(color: Colors.white),
                textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
                // الانتقال للخانات التالية عند ضغط Enter
                onSubmitted: (_) {
                  if (isLast) {
                    _handleRegister();
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
            ),
          ),
        );
      },
    );
  }
}