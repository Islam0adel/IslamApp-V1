// frontend/lib/views/auth/forgot_password_screen.dart
import '../../core/theme.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../views/widgets/glass_card.dart';
import 'dart:convert';
import '../../core/constants.dart';
import '../../services/auth_http.dart';

// شاشة استعادة كلمة المرور
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

// حالة الويدجت ForgotPasswordScreen: تدير بيانات الشاشة وتفاعلاتها
class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _emailNode = FocusNode();

  bool _isLoading = false;
  bool _emailSent = false;

  // يرسل طلب استعادة كلمة المرور
  Future<void> _handleSend() async {
    final email = _emailController.text.trim().toLowerCase();

    if (email.isEmpty) {
      _showSnackBar(
        'برجاء إدخال البريد الإلكتروني',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (!RegExp(r'^[\w\.-]+@[\w\.-]+\.[a-zA-Z]{2,}$').hasMatch(email)) {
      _showSnackBar(
        'صيغة البريد الإلكتروني غير صحيحة',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _emailSent = false;
    });

    try {
      // ⭐ 1) تحقق من وجود الإيميل عبر الباك (Admin SDK)
      final response = await AuthHttp.post(
        Uri.parse('${ApiConstants.baseUrl}/auth/check-email'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw 'تعذر التحقق من البريد. حاول مرة أخرى.';
      }

      final result = jsonDecode(response.body) as Map<String, dynamic>;
      final exists = result['exists'] == true;
      final needsCompletion = result['needs_completion'] == true;

      if (!exists) {
        _showSnackBar(
          'لا يوجد حساب مسجل بهذا البريد الإلكتروني',
          AppTheme.warningOrangeFor(context),
        );
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      if (needsCompletion) {
        _showSnackBar(
          'حسابك لم يكمل التسجيل بعد. يرجى التواصل مع الإدارة.',
          AppTheme.warningOrangeFor(context),
        );
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // ⭐ 2) البيانات صح → Firebase يبعت إيميل إعادة التعيين
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);

      setState(() => _emailSent = true);

      _showSnackBar(
        '✅ تم إرسال إيميل إعادة تعيين كلمة المرور',
        AppTheme.successStrongFor(context),
      );
    } on FirebaseAuthException catch (e) {
      String msg;
      switch (e.code) {
        case 'user-not-found':
          msg = 'لا يوجد حساب مسجل بهذا البريد. تأكد من إكمال التسجيل أولاً.';
          break;
        case 'invalid-email':
          msg = 'صيغة البريد الإلكتروني غير صحيحة';
          break;
        case 'too-many-requests':
          msg = 'محاولات كثيرة، حاول بعد قليل';
          break;
        case 'network-request-failed':
          msg = 'خطأ في الاتصال بالشبكة. تحقق من اتصالك بالإنترنت.';
          break;
        default:
          msg = 'تعذر إرسال الإيميل: ${e.message ?? e.code}';
      }
      _showSnackBar(msg, AppTheme.dangerFor(context));
    } catch (e) {
      _showSnackBar(
        'تعذر إرسال الإيميل: $e',
        AppTheme.dangerFor(context),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // يعرض رسالة سريعة بالنص واللون المحددين
  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textAlign: TextAlign.center),
        backgroundColor: color,
      ),
    );
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    _emailController.dispose();
    _emailNode.dispose();
    super.dispose();
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
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
              children: [
                Icon(
                  Icons.security_rounded,
                  size: 80,
                  color: AppTheme.textMainFor(context),
                ),
                const SizedBox(height: 20),
                Text(
                  'استعادة كلمة المرور',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'أدخل بريدك الإلكتروني وسنرسل لك رابط إعادة التعيين',
                  style: TextStyle(
                    color: AppTheme.textSoftFor(context),
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),
                GlassCard(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 15),
                        child: TextField(
                          controller: _emailController,
                          focusNode: _emailNode,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _handleSend(),
                          style:
                              TextStyle(color: AppTheme.textMainFor(context)),
                          decoration: InputDecoration(
                            prefixIcon: Icon(
                              Icons.email_outlined,
                              color: AppTheme.textSoftFor(context),
                            ),
                            labelText: 'البريد الإلكتروني',
                            labelStyle: TextStyle(
                              color: AppTheme.textSoftFor(context),
                              fontSize: 14,
                            ),
                            filled: true,
                            fillColor: AppTheme.inputFill(context),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(15),
                              borderSide: BorderSide(
                                color: AppTheme.inputBorder(context),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(15),
                              borderSide: BorderSide(
                                color: AppTheme.inputFocus(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _isLoading
                          ? CircularProgressIndicator(
                              color: Theme.of(context).colorScheme.onPrimary,
                            )
                          : SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      AppTheme.authActionBackground(context),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15),
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 15),
                                ),
                                onPressed: _handleSend,
                                child: Text(
                                  'إرسال إيميل إعادة التعيين',
                                  style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.onPrimary,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                            ),
                      if (_emailSent) ...[
                        const SizedBox(height: 20),
                        Divider(color: AppTheme.border(context)),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.successStrongFor(context)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppTheme.successStrongFor(context)
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.mark_email_read_rounded,
                                color: AppTheme.successStrongFor(context),
                                size: 24,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'تم إرسال إيميل إعادة تعيين كلمة المرور.\n'
                                  'افتح بريدك واضغط على الرابط في الإيميل.',
                                  style: TextStyle(
                                    color: AppTheme.successStrongFor(context),
                                    fontSize: 13,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'لو مش لاقي الإيميل، تحقق من Spam أو Junk',
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontSize: 11,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'رجوع لتسجيل الدخول',
                    style: TextStyle(color: AppTheme.textSoftFor(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
