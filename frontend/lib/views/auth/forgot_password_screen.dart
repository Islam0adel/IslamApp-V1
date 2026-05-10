import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart'; // هتحتاج تضيفها في pubspec.yaml لفتح الرابط
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';


class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _compCodeController = TextEditingController();
  final _jobCodeController = TextEditingController();
  
  final _emailNode = FocusNode();
  final _compNode = FocusNode();
  final _jobNode = FocusNode();

  final _apiService = ApiService();
  bool _isLoading = false;
  String? _resetLink;

  void _handleVerify() async {
    if (_emailController.text.isEmpty || _compCodeController.text.isEmpty || _jobCodeController.text.isEmpty) {
      _showSnackBar('برجاء إدخال كافة البيانات المطلوبة', Colors.orange);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final result = await _apiService.verifyAndGetResetLink(
        email: _emailController.text.trim(),
        companyCode: _compCodeController.text.trim(),
        jobCode: _jobCodeController.text.trim(),
      );

      setState(() {
        _resetLink = result['reset_link'];
      });
      _showSnackBar('تم التحقق بنجاح، اضغط على الرابط بالأسفل', Colors.green);
    } catch (e) {
      _showSnackBar(e.toString(), Colors.redAccent);
    } finally {
      setState(() => _isLoading = false);
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
              children: [
                const Icon(Icons.security_rounded, size: 80, color: Colors.white),
                const SizedBox(height: 20),
                const Text(
                  'استعادة الحساب',
                  style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                const Text(
                  'أدخل البيانات بدقة لتوليد رابط الاستعادة',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),

                GlassCard(
                  child: Column(
                    children: [
                      _buildField(
                        icon: Icons.email_outlined,
                        label: 'البريد الإلكتروني',
                        controller: _emailController,
                        node: _emailNode,
                        nextNode: _compNode,
                      ),
                      _buildField(
                        icon: Icons.business,
                        label: 'كود الشركة',
                        controller: _compCodeController,
                        node: _compNode,
                        nextNode: _jobNode,
                      ),
                      _buildField(
                        icon: Icons.badge_outlined,
                        label: 'كود الموظف (المستخدم)',
                        controller: _jobCodeController,
                        node: _jobNode,
                        isLast: true,
                      ),
                      
                      const SizedBox(height: 25),

                      _isLoading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white.withOpacity(0.2),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                                  padding: const EdgeInsets.symmetric(vertical: 15),
                                ),
                                onPressed: _handleVerify,
                                child: const Text('تحقق من البيانات', style: TextStyle(color: Colors.white, fontSize: 18)),
                              ),
                            ),
                      
                      // ظهور الرابط فقط بعد التحقق الناجح
                      if (_resetLink != null) ...[
                        const SizedBox(height: 20),
                        const Divider(color: Colors.white24),
                        const SizedBox(height: 10),
                        const Text(
                          'تم التحقق! اضغط على الزر بالأسفل لتغيير كلمة المرور:',
                          style: TextStyle(color: Colors.greenAccent, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 15),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green.withOpacity(0.3)),
                          onPressed: () async {
                              final Uri url = Uri.parse(_resetLink!); // تحويل النص لـ Uri
                              if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
                                _showSnackBar('تعذر فتح الرابط', Colors.red);
                              }
                            },
                          icon: const Icon(Icons.link, color: Colors.white),
                          label: const Text('فتح رابط التغيير', style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('رجوع لتسجيل الدخول', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required IconData icon,
    required String label,
    required TextEditingController controller,
    required FocusNode node,
    FocusNode? nextNode,
    bool isLast = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: TextField(
        controller: controller,
        focusNode: node,
        style: const TextStyle(color: Colors.white),
        textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
        onSubmitted: (_) => isLast ? _handleVerify() : FocusScope.of(context).requestFocus(nextNode),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: Colors.white70),
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70, fontSize: 14),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Colors.white)),
        ),
      ),
    );
  }
}