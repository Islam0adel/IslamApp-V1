// lib/views/auth/verify_email_screen.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';
import '../../services/permissions_service.dart';
import '../dashboard/home_page.dart';
import 'login_screen.dart';
import '../../main.dart' show initializeGlobalListener;

class VerifyEmailScreen extends StatefulWidget {
  final String email;
  const VerifyEmailScreen({super.key, required this.email});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _apiService = ApiService();
  bool _isChecking = false;
  bool _isResending = false;
  bool _isCancelling = false;

  Future<void> _checkVerified() async {
    setState(() => _isChecking = true);
    try {
      final verified = await _apiService.checkEmailVerified();
      if (!verified) {
        _showSnackBar(
          'لم يتم التحقق من البريد بعد. تأكد من الضغط على الرابط.',
          AppTheme.warningOrangeFor(context),
        );
        return;
      }

      // ⭐ تحديث email_verified في Firestore
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user?.email != null) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user!.email!.toLowerCase())
              .update({'email_verified': true});
        }
      } catch (e) {
        print('⚠️ email_verified update failed: $e');
      }

      final result = await _apiService.verifyUser();
      await _savePrefsAndNavigate(result);
    } catch (e) {
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<void> _resendEmail() async {
    setState(() => _isResending = true);
    try {
      await _apiService.resendEmailVerification();
      _showSnackBar(
        'تم إرسال رابط التحقق مرة أخرى',
        AppTheme.successStrongFor(context),
      );
    } catch (e) {
      _showSnackBar('فشل إعادة الإرسال: $e', AppTheme.dangerFor(context));
    } finally {
      if (mounted) setState(() => _isResending = false);
    }
  }

  Future<void> _savePrefsAndNavigate(Map<String, dynamic> result) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', result['name'] ?? '');
    await prefs.setString('company_name', result['company_name'] ?? '');
    await prefs.setString('company_code', result['company_code'] ?? '');
    await prefs.setString('job_code', result['job_code'] ?? '1');
    await prefs.setString('job_title', result['job_title'] ?? '');
    await prefs.setString('role', result['role'] ?? 'employee');
    await prefs.setString('user_email', result['email'] ?? widget.email);
    await prefs.setBool('remember_me', true);

    if ((result['branch_code'] ?? '').toString().isNotEmpty) {
      await prefs.setString('selected_branch_code', result['branch_code']);
    }

    PermissionsService().setRole(result['role']?.toString());

    final allowedBranches = result['allowed_branches'];
    if (allowedBranches is List) {
      PermissionsService().setAllowedBranches(
        allowedBranches.map((e) => e.toString()).toList(),
      );
    }

    initializeGlobalListener(result['company_code'] ?? '');

    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => HomePage(
          userName: result['name'] ?? '',
          companyName: result['company_name'] ?? '',
          companyCode: result['company_code'] ?? '',
        ),
      ),
      (route) => false,
    );
  }

  // ⭐ إلغاء التسجيل — يرجع للـ Login
  Future<void> _cancelRegistration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: AppTheme.dangerFor(context),
              size: 24,
            ),
            const SizedBox(width: 8),
            Text(
              'إلغاء التسجيل',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          'سيتم إلغاء التسجيل الحالي وإرجاع حالتك "بانتظار التسجيل".\n\n'
          'يمكنك بعدها البدء من جديد بالبيانات الصحيحة.',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMutedFor(context),
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'تراجع',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'إلغاء التسجيل',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.dangerFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isCancelling = true);
    try {
      await _apiService.cancelRegistration();

      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } catch (e) {
      _showSnackBar(
        'فشل الإلغاء: $e',
        AppTheme.dangerFor(context),
      );
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_rounded,
            color: AppTheme.textMainFor(context),
          ),
          onPressed: _isCancelling ? null : _cancelRegistration,
          tooltip: 'رجوع',
        ),
        actions: [
          TextButton(
            onPressed: _isCancelling ? null : _cancelRegistration,
            child: Text(
              'إلغاء التسجيل',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.dangerFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.authGradient(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: Column(
                children: [
                  Icon(
                    Icons.mark_email_unread_rounded,
                    size: 90,
                    color: AppTheme.textMainFor(context),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'تحقق من بريدك الإلكتروني',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'أرسلنا رابط تحقق إلى:',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textSoftFor(context),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.inputFill(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.inputBorder(context)),
                    ),
                    child: Text(
                      widget.email,
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  GlassCard(
                    child: Column(
                      children: [
                        Text(
                          'اضغط على الرابط في بريدك لتفعيل الحساب، '
                          'ثم عد إلى هنا واضغط "تحققت بالفعل".',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: _isChecking
                              ? Center(
                                  child: CircularProgressIndicator(
                                    color:
                                        Theme.of(context).colorScheme.onPrimary,
                                  ),
                                )
                              : ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        AppTheme.successStrongFor(context),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 15),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(15),
                                    ),
                                  ),
                                  onPressed: _checkVerified,
                                  icon: Icon(
                                    Icons.check_circle_rounded,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary,
                                  ),
                                  label: Text(
                                    'تحققت بالفعل',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: _isResending ? null : _resendEmail,
                          icon: _isResending
                              ? SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.accentFor(context),
                                  ),
                                )
                              : Icon(
                                  Icons.refresh_rounded,
                                  color: AppTheme.accentFor(context),
                                  size: 18,
                                ),
                          label: Text(
                            _isResending
                                ? 'جاري الإرسال...'
                                : 'إعادة إرسال الرابط',
                            style: TextStyle(
                              color: AppTheme.accentFor(context),
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ),
                        const Divider(height: 24),
                        // ⭐ زر الرجوع/إلغاء (في الأسفل كمان للوضوح)
                        TextButton.icon(
                          onPressed: _isCancelling ? null : _cancelRegistration,
                          icon: _isCancelling
                              ? SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.dangerFor(context),
                                  ),
                                )
                              : Icon(
                                  Icons.cancel_outlined,
                                  color: AppTheme.dangerFor(context),
                                  size: 16,
                                ),
                          label: Text(
                            _isCancelling
                                ? 'جاري الإلغاء...'
                                : 'بياناتي غلط؟ إلغاء التسجيل',
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              color: AppTheme.dangerFor(context),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 25),
                  Text(
                    'لم تجد الإيميل؟ تحقق من مجلد "Spam".',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}