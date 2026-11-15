// lib/views/auth/phone_entry_screen.dart

import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';
import 'complete_registration_screen.dart';

class PhoneEntryScreen extends StatefulWidget {
  const PhoneEntryScreen({super.key});

  @override
  State<PhoneEntryScreen> createState() => _PhoneEntryScreenState();
}

class _PhoneEntryScreenState extends State<PhoneEntryScreen>
    with SingleTickerProviderStateMixin {
  final _identifierController = TextEditingController();
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
    _identifierController.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleContinue() async {
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty) {
      _showSnackBar(
        'برجاء إدخال رقم الموبايل أو البريد الإلكتروني',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    // ⭐ Smart validation
    final isEmail = identifier.contains('@');
    final isPhone = RegExp(r'^[0-9]{8,15}$').hasMatch(identifier);

    if (!isEmail && !isPhone) {
      _showSnackBar(
        'أدخل رقم موبايل صحيح أو بريد إلكتروني صحيح',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final result = await _apiService.checkPhone(identifier);
      if (!mounted) return;

      if (result['found'] != true) {
        // ⭐ اعرض خيار "طلب الانضمام"
        if (!mounted) return;
        final shouldRequest = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.dialogBackground(context),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            title: Text(
              'غير مسجل في النظام',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Text(
              'هذا ${isEmail ? "البريد" : "الرقم"} غير مسجل. '
              'هل تريد إرسال طلب انضمام للشركة؟',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
                height: 1.5,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'إلغاء',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  'طلب الانضمام',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.accentFor(context),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );

        if (shouldRequest == true && mounted) {
          await _showRequestDialog(
            prefilledPhone: isPhone ? identifier : null,
            prefilledEmail: isEmail ? identifier : null,
          );
        }
        return;
      }

      // ⭐ حالة 1: سوبر أدمن مش متسجل
      if (result['is_super_admin'] == true &&
          result['needs_setup'] == true) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CompleteRegistrationScreen(
              phoneNumber: null, // السوبر أدمن مش محتاج رقم
              userName: (result['name'] ?? 'Super Admin').toString(),
              companyName: (result['company_name'] ?? 'الشركة الافتراضية').toString(),
              branchCode: '',
              isSuperAdminSetup: true,
              prefilledEmail: isEmail ? identifier : null,
            ),
          ),
        );
        return;
      }

      // ⭐ حالة 2: مستخدم عنده حساب كامل
      if (result['has_account'] == true) {
        _showSnackBar(
          'هذا الحساب مسجل بالفعل. اضغط "تسجيل الدخول".',
          AppTheme.warningOrangeFor(context),
        );
        return;
      }

      // ⭐ حالة 3: مستخدم مسجل من الأدمن، لسه مكملش
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CompleteRegistrationScreen(
            phoneNumber: isPhone ? identifier : null,
            userName: (result['name'] ?? '').toString(),
            companyName: (result['company_name'] ?? '').toString(),
            branchCode: (result['branch_code'] ?? '').toString(),
            isSuperAdminSetup: false,
            prefilledEmail: isEmail ? identifier : null,
          ),
        ),
      );
    } catch (e) {
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

    Future<void> _showRequestDialog({
    String? prefilledPhone,
    String? prefilledEmail,
  }) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _RequestRegistrationDialog(
        prefilledPhone: prefilledPhone,
        prefilledEmail: prefilledEmail,
      ),
    );

    if (result == null || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await _apiService.requestRegistration(
        name: result['name'] as String,
        phoneNumber: result['phone_number'] as String?,
        email: result['email'] as String?,
        companyCode: result['company_code'] as String,
        branchCode: result['branch_code'] as String?,
        note: result['note'] as String?,
      );
      if (!mounted) return;
      _showSnackBar(
        'تم إرسال طلب الانضمام. سيتم مراجعته من الإدارة.',
        AppTheme.successStrongFor(context),
      );
    } catch (e) {
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
      body: Container(
        height: double.infinity,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.registerGradient(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 40),
            child: Column(
              children: [
                FadeTransition(
                  opacity: _animController,
                  child: Column(
                    children: [
                      Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 80,
                        color: AppTheme.textMainFor(context),
                      ),
                      const SizedBox(height: 15),
                      Text(
                        'إنشاء حساب',
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'أدخل رقم الموبايل أو البريد الإلكتروني\nالمسجل من الإدارة',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTheme.textSoftFor(context),
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                GlassCard(
                  child: Column(
                    children: [
                      TextField(
                        controller: _identifierController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _handleContinue(),
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                        ),
                        decoration: InputDecoration(
                          prefixIcon: Icon(
                            Icons.person_search_rounded,
                            color: AppTheme.textSoftFor(context),
                          ),
                          labelText: 'رقم الموبايل أو البريد',
                          hintText: '01xxxxxxxxx أو user@example.com',
                          hintStyle: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontSize: 12,
                          ),
                          labelStyle: TextStyle(
                            color: AppTheme.textSoftFor(context),
                            fontFamily: 'Cairo',
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
                      const SizedBox(height: 25),
                      SizedBox(
                        width: double.infinity,
                        child: _isLoading
                            ? Center(
                                child: CircularProgressIndicator(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                ),
                              )
                            : ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      AppTheme.authActionBackground(context),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 15),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15),
                                  ),
                                ),
                                onPressed: _handleContinue,
                                child: Text(
                                  'متابعة',
                                  style: TextStyle(
                                    fontSize: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'لديك حساب بالفعل؟ سجل دخولك',
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
// ============================================================
// Dialog: طلب الانضمام
// ============================================================
// ============================================================
// Dialog: طلب الانضمام (بدون اختيار شركة — الأدمن يحددها)
// ============================================================
class _RequestRegistrationDialog extends StatefulWidget {
  final String? prefilledPhone;
  final String? prefilledEmail;

  const _RequestRegistrationDialog({
    this.prefilledPhone,
    this.prefilledEmail,
  });

  @override
  State<_RequestRegistrationDialog> createState() =>
      _RequestRegistrationDialogState();
}

class _RequestRegistrationDialogState
    extends State<_RequestRegistrationDialog> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.prefilledPhone != null) {
      _phoneCtrl.text = widget.prefilledPhone!;
    }
    if (widget.prefilledEmail != null) {
      _emailCtrl.text = widget.prefilledEmail!;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return _error('الاسم مطلوب');
    if (_phoneCtrl.text.trim().isEmpty && _emailCtrl.text.trim().isEmpty) {
      return _error('رقم الموبايل أو الإيميل مطلوب');
    }

    Navigator.pop(context, {
      'name': name,
      'phone_number': _phoneCtrl.text.trim(),
      'email': _emailCtrl.text.trim(),
      'company_code': '',  // ⭐ الأدمن يحددها
      'branch_code': '',
      'note': _noteCtrl.text.trim(),
    });
  }

  void _error(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: AppTheme.dangerFor(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Row(
        children: [
          Icon(Icons.mail_outline_rounded, color: AppTheme.accentFor(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'طلب الانضمام',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.infoFor(context).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.infoFor(context).withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: AppTheme.infoFor(context),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'اكتب اسم الشركة في الملاحظات عشان الإدارة تعرف '
                        'تحوّل طلبك للشركة الصح.',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.infoFor(context),
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _field(
                controller: _nameCtrl,
                label: 'الاسم الكامل',
                icon: Icons.person_rounded,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _phoneCtrl,
                label: 'رقم الموبايل',
                icon: Icons.phone_rounded,
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _emailCtrl,
                label: 'البريد الإلكتروني',
                icon: Icons.email_rounded,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _noteCtrl,
                label: 'اكتب اسم الشركة أو أي ملاحظات',
                icon: Icons.notes_rounded,
                hint: 'مثال: شركة اسلام / فرع العاشر',
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'إلغاء',
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMutedFor(context),
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentFor(context),
            foregroundColor: Colors.white,
          ),
          child: const Text(
            'إرسال الطلب',
            style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: TextStyle(
        fontFamily: 'Cairo',
        color: AppTheme.textMainFor(context),
      ),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMutedFor(context),
          fontSize: 11,
        ),
        labelStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textSoftFor(context),
          fontSize: 12,
        ),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}