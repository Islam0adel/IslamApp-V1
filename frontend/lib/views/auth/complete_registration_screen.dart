// lib/views/auth/complete_registration_screen.dart

import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';
import 'verify_email_screen.dart';

class CompleteRegistrationScreen extends StatefulWidget {
  final String? phoneNumber;
  final String userName;
  final String companyName;
  final String branchCode;
  final bool isSuperAdminSetup;
  final String? prefilledEmail;

  const CompleteRegistrationScreen({
    super.key,
    this.phoneNumber,
    required this.userName,
    required this.companyName,
    required this.branchCode,
    this.isSuperAdminSetup = false,
    this.prefilledEmail,
  });

  @override
  State<CompleteRegistrationScreen> createState() =>
      _CompleteRegistrationScreenState();
}

class _CompleteRegistrationScreenState
    extends State<CompleteRegistrationScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _usernameController = TextEditingController();
  final _employeeCodeController = TextEditingController();
  final _nameController = TextEditingController();
  final _apiService = ApiService();
  bool _isLoading = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefilledEmail != null) {
      _emailController.text = widget.prefilledEmail!;
    }
    if (widget.isSuperAdminSetup) {
      _nameController.text = widget.userName;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _usernameController.dispose();
    _employeeCodeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;
    final username = _usernameController.text.trim();
    final employeeCode = _employeeCodeController.text.trim();
    final name = _nameController.text.trim();

    if (email.isEmpty || password.isEmpty || confirm.isEmpty) {
      _showSnackBar(
        'برجاء ملء كل الحقول المطلوبة',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (widget.isSuperAdminSetup && name.isEmpty) {
      _showSnackBar(
        'الاسم مطلوب',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (!RegExp(r'^[\w\.-]+@[\w\.-]+\.[a-z]{2,}$', caseSensitive: false)
        .hasMatch(email)) {
      _showSnackBar(
        'البريد الإلكتروني غير صحيح',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (password.length < 6) {
      _showSnackBar(
        'كلمة المرور يجب أن تكون 6 أحرف على الأقل',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (password != confirm) {
      _showSnackBar(
        'كلمتا المرور غير متطابقتين',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (username.isNotEmpty &&
        !RegExp(r'^[a-zA-Z0-9_]{3,30}$').hasMatch(username)) {
      _showSnackBar(
        'اسم المستخدم يجب أن يكون 3-30 حرف (a-z, 0-9, _)',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await _apiService.completeRegistration(
        phoneNumber: widget.phoneNumber,
        email: email,
        password: password,
        username: username.isEmpty ? null : username,
        name: widget.isSuperAdminSetup ? name : null,
        employeeCode: employeeCode.isEmpty ? null : employeeCode,
      );

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => VerifyEmailScreen(email: email),
        ),
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
                horizontal: 20, vertical: 20),
            child: Column(
              children: [
                // Back button
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: Icon(
                      Icons.arrow_back_rounded,
                      color: AppTheme.textMainFor(context),
                    ),
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'رجوع',
                  ),
                ),
                Icon(
                  Icons.verified_user_rounded,
                  size: 70,
                  color: AppTheme.textMainFor(context),
                ),
                const SizedBox(height: 15),
                Text(
                  widget.isSuperAdminSetup
                      ? 'إعداد حساب السوبر أدمن'
                      : 'إكمال التسجيل',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'نحتاج بعض المعلومات لإكمال حسابك',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.textSoftFor(context),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),

                // بيانات الموظف (Read-only)
                GlassCard(
                  child: Column(
                    children: [
                      if (widget.phoneNumber != null) ...[
                        _buildInfoRow(
                          Icons.phone_rounded,
                          'الموبايل',
                          widget.phoneNumber!,
                        ),
                        const SizedBox(height: 8),
                      ],
                      _buildInfoRow(
                        Icons.business_rounded,
                        'الشركة',
                        widget.companyName,
                      ),
                      if (!widget.isSuperAdminSetup &&
                          widget.userName.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _buildInfoRow(
                          Icons.person_rounded,
                          'الاسم',
                          widget.userName,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 15),

                // بيانات التسجيل
                GlassCard(
                  child: Column(
                    children: [
                      // Name (لسوبر أدمن فقط)
                      if (widget.isSuperAdminSetup) ...[
                        _buildField(
                          icon: Icons.person_rounded,
                          label: 'الاسم الكامل',
                          controller: _nameController,
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Email
                      _buildField(
                        icon: Icons.email_outlined,
                        label: 'البريد الإلكتروني',
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        enabled: widget.prefilledEmail == null,
                      ),
                      const SizedBox(height: 12),

                      // Password
                      _buildField(
                        icon: Icons.lock_outline,
                        label: 'كلمة المرور',
                        controller: _passwordController,
                        obscure: !_showPassword,
                        suffix: IconButton(
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: AppTheme.textSoftFor(context),
                            size: 20,
                          ),
                          onPressed: () => setState(
                              () => _showPassword = !_showPassword),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Confirm
                      _buildField(
                        icon: Icons.lock_outline,
                        label: 'تأكيد كلمة المرور',
                        controller: _confirmController,
                        obscure: !_showPassword,
                      ),
                      const SizedBox(height: 12),

                      // Username
                      _buildField(
                        icon: Icons.alternate_email_rounded,
                        label: 'اسم المستخدم (اختياري)',
                        controller: _usernameController,
                        hint: 'مثال: ahmed_2024',
                      ),

                      // Employee code (regular users only)
                      if (!widget.isSuperAdminSetup) ...[
                        const SizedBox(height: 12),
                        _buildField(
                          icon: Icons.badge_outlined,
                          label: 'كود الموظف في HR (اختياري)',
                          controller: _employeeCodeController,
                          hint: 'اتركه فاضي لو مش موظف',
                        ),
                      ],

                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: _isLoading
                            ? Center(
                                child: CircularProgressIndicator(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimary,
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
                                onPressed: _handleSubmit,
                                child: Text(
                                  'إنشاء الحساب',
                                  style: TextStyle(
                                    fontSize: 17,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: AppTheme.infoFor(context),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'سيتم إرسال رابط تحقق إلى بريدك الإلكتروني',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppTheme.textMutedFor(context),
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.accentFor(context), size: 18),
        const SizedBox(width: 10),
        Text(
          '$label:',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMutedFor(context),
            fontSize: 12,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMainFor(context),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildField({
    required IconData icon,
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    bool obscure = false,
    String? hint,
    Widget? suffix,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      enabled: enabled,
      style: TextStyle(
        color: enabled
            ? AppTheme.textMainFor(context)
            : AppTheme.textMutedFor(context),
      ),
      decoration: InputDecoration(
        prefixIcon: Icon(
          icon,
          color: enabled
              ? AppTheme.textSoftFor(context)
              : AppTheme.textMutedFor(context),
        ),
        suffixIcon: suffix,
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
          color: AppTheme.textMutedFor(context),
          fontSize: 11,
        ),
        labelStyle: TextStyle(color: AppTheme.textSoftFor(context)),
        filled: true,
        fillColor: AppTheme.inputFill(context),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: AppTheme.inputBorder(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: AppTheme.inputFocus(context)),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(
            color: AppTheme.inputBorder(context).withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}