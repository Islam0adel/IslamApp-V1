// frontend/lib/views/dashboard/settings_page.dart
import '../../services/cache_partitions.dart';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../../main.dart';
import '../../views/dashboard/admin_companies_screen.dart';
import '../../views/dashboard/company_users_page.dart';
// 1. استدعاء صفحة الصلاحيات الجديدة (تأكد من مسار الملف عندك)
import '../../views/dashboard/permissions_page.dart';
import '../../services/permissions_service.dart';
import '../../views/dashboard/reset_page.dart';
import '../../views/auth/forgot_password_screen.dart';
import 'notification_settings_page.dart';
import 'pending_ownership_page.dart';

// صفحة الإعدادات
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

// حالة الويدجت SettingsPage: تدير بيانات الشاشة وتفاعلاتها
class _SettingsPageState extends State<SettingsPage>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  bool _isDark = true;
  String _userName = "جاري التحميل...";
  String _companyName = "شركتي";
  String _companyCode = "01";
  bool _isLoadingData = true;
  bool _showBranchDialog = true;

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _loadUserData();
  }

  // دالة لقراءة البيانات المقروءة عند تسجيل الدخول
  // يحمّل بيانات المستخدم
  Future<void> _loadUserData() async {
    return CachePartitions.run(() async {
      final prefs = await SharedPreferences.getInstance();

      final email = prefs.getString('user_email') ?? '';

      final showDialog = prefs.getBool('show_branch_dialog_$email') ?? true;

      if (mounted) {
        setState(() {
          _userName = prefs.getString('user_name') ?? "مستخدم غير معروف";

          _companyName = prefs.getString('company_name') ?? "شركتي";

          // ⭐ role محفوظ تلقائياً في PermissionsService

          _companyCode = prefs.getString('company_code') ?? "01";

          _showBranchDialog = showDialog;

          _isLoadingData = false;
        });
      }
    });
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    _isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      // السماح بالرجوع الطبيعي لتعمل إيماءة السحب من الحافة على iOS
      canPop: true,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text('الإعدادات',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textMainFor(context))),
          centerTitle: true,
          backgroundColor: AppTheme.appBarBgGlass,
          elevation: 0,
          iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: AppTheme.settingsGradient(context),
                  ),
                ),
              ),
            ),
            Positioned(
              top: -100,
              right: -50,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GlassStyle.fill04For(context),
                ),
              ),
            ),
            SafeArea(
              child: FadeTransition(
                opacity: _controller,
                child: SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Column(
                    children: [
                      GlassCard(
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: GlassStyle.fill10For(context),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.person_rounded,
                                  color: AppTheme.accentFor(context), size: 40),
                            ),
                            const SizedBox(width: 15),
                            Expanded(
                              child: _isLoadingData
                                  ? Align(
                                      alignment: Alignment.centerRight,
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppTheme.accentFor(context)),
                                      ),
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _userName,
                                          style: TextStyle(
                                            color:
                                                AppTheme.textMainFor(context),
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: 'Cairo',
                                          ),
                                        ),
                                        Text(
                                          _companyName,
                                          style: TextStyle(
                                            color:
                                                AppTheme.textMutedFor(context),
                                            fontSize: 13,
                                            fontFamily: 'Cairo',
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 25),
                      _buildSectionTitle("المظهر والنظام"),
                      const SizedBox(height: 10),
                      GlassCard(
                        child: Column(
                          children: [
                            _buildSettingRow(
                              icon: Icons.dark_mode_rounded,
                              title: 'الوضع الليلي (Dark Mode)',
                              trailing: Switch(
                                value: _isDark,
                                activeThumbColor: AppTheme.accentFor(context),
                                onChanged: (val) {
                                  try {
                                    IslamApp.of(context).changeTheme(
                                        val ? ThemeMode.dark : ThemeMode.light);
                                  } catch (e) {
                                    debugPrint("تنبيه الثيم: $e");
                                  }
                                },
                              ),
                            ),
                            Divider(
                              color: GlassStyle.line10For(context),
                              height: 20,
                            ),
                            _buildSettingRow(
                              icon: Icons.storefront_rounded,
                              title: 'إظهار رسالة اختيار الفرع',
                              trailing: Switch(
                                value: _showBranchDialog,
                                activeThumbColor: AppTheme.accentFor(context),
                                onChanged: (value) async {
                                  return CachePartitions.run(() async {
                                    final prefs =
                                        await SharedPreferences.getInstance();

                                    final email =
                                        prefs.getString('user_email') ?? '';

                                    await prefs.setBool(
                                      'show_branch_dialog_$email',
                                      value,
                                    );

                                    if (mounted) {
                                      setState(() {
                                        _showBranchDialog = value;
                                      });
                                    }
                                  });
                                },
                              ),
                            ),
                            Divider(
                                color: GlassStyle.line10For(context),
                                height: 20),
                            if (PermissionsService().canShowNotifications) ...[
                              _buildSettingRow(
                                icon: Icons.notifications_active_rounded,
                                title: 'إعدادات الإشعارات',
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (c) =>
                                            NotificationSettingsPage(
                                                companyCode: _companyCode))),
                              ),
                              Divider(
                                  color: GlassStyle.line10For(context),
                                  height: 20),
                            ],
                            _buildSettingRow(
                              icon: Icons.translate_rounded,
                              title: 'لغة التطبيق',
                              trailing: Text('العربية',
                                  style: TextStyle(
                                      color: AppTheme.accentFor(context),
                                      fontFamily: 'Cairo')),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 25),
                      _buildSectionTitle("الدعم والخصوصية"),
                      const SizedBox(height: 10),
                      GlassCard(
                        child: Column(
                          children: [
                            // ⭐ إدارة المستخدمين — admin + super_admin
                            if (PermissionsService().canOpenUserManagement) ...[
                              _buildSettingRow(
                                icon: Icons.people_alt_rounded,
                                title: 'إدارة المستخدمين',
                                onTap: () async {
                                  return CachePartitions.run(() async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => CompanyUsersPage(
                                          companyCode:
                                              PermissionsService().isSuperAdmin
                                                  ? ''
                                                  : _companyCode,
                                          companyName:
                                              PermissionsService().isSuperAdmin
                                                  ? 'كل الشركات'
                                                  : _companyName,
                                        ),
                                      ),
                                    );
                                  });
                                },
                              ),
                              Divider(
                                  color: GlassStyle.line10For(context),
                                  height: 20),
                            ],

                            // ⭐ عمليات معلقة مجهولة المالك — admin
                            // (قرار نسب/حذف صريح لكل عملية)
                            if (PermissionsService().canManageUsers) ...[
                              _buildSettingRow(
                                icon: Icons.sync_problem_rounded,
                                title: 'عمليات معلقة مجهولة المالك',
                                onTap: () async {
                                  return CachePartitions.run(() async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PendingOwnershipPage(
                                          companyCode: _companyCode,
                                        ),
                                      ),
                                    );
                                  });
                                },
                              ),
                              Divider(
                                  color: GlassStyle.line10For(context),
                                  height: 20),
                            ],

                            // ⭐ إدارة الصلاحيات — admin + super_admin
                            if (PermissionsService().canManagePermissions) ...[
                              _buildSettingRow(
                                icon: Icons.security_rounded,
                                title: 'إدارة الصلاحيات',
                                onTap: () async {
                                  return CachePartitions.run(() async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const PermissionsPage()),
                                    );
                                  });
                                },
                              ),
                              Divider(
                                  color: GlassStyle.line10For(context),
                                  height: 20),
                            ],

                            _buildSettingRow(
                              icon: Icons.lock_reset_rounded,
                              title: 'تغيير كلمة المرور',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const ForgotPasswordScreen()),
                                );
                              },
                            ),
                            Divider(
                                color: GlassStyle.line10For(context),
                                height: 20),
                            _buildSettingRow(
                              icon: Icons.contact_support_rounded,
                              title: 'تواصل مع الدعم الفني',
                              onTap: () {},
                            ),

                            Divider(
                                color: GlassStyle.line10For(context),
                                height: 20),
                            _buildSettingRow(
                              icon: Icons.restore_rounded,
                              title: 'إعادة تعيين البيانات',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const ResetPage()),
                                );
                              },
                            ),
                            Divider(
                                color: GlassStyle.line10For(context),
                                height: 20),

                            // زر إدارة الشركات — super_admin فقط
                            if (PermissionsService().isSuperAdmin) ...[
                              Divider(
                                  color: GlassStyle.line10For(context),
                                  height: 20),
                              _buildSettingRow(
                                icon: Icons.business_center,
                                title: 'إدارة الشركات',
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const AdminCompaniesScreen()),
                                  );
                                },
                              ),
                            ],

                            Divider(
                                color: GlassStyle.line10For(context),
                                height: 20),
                            _buildSettingRow(
                              icon: Icons.info_outline_rounded,
                              title: 'حول الإصدار V1.0',
                              onTap: () {},
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 40),
                      Opacity(
                        opacity: 0.3,
                        child: Text(
                          "Designed & Developed by Islam",
                          style: TextStyle(
                              color: AppTheme.textMainFor(context),
                              fontSize: 10,
                              letterSpacing: 1.1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // يبني عنوان قسم
  Widget _buildSectionTitle(String title) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Text(
          title,
          style: TextStyle(
            color: AppTheme.textStrongFor(context),
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontFamily: 'Cairo',
          ),
        ),
      ),
    );
  }

  // يبني صف إعداد
  Widget _buildSettingRow({
    required IconData icon,
    required String title,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: GlassStyle.fill05For(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AppTheme.textMainFor(context), size: 20),
            ),
            const SizedBox(width: 15),
            Text(
              title,
              style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 15,
                  fontFamily: 'Cairo'),
            ),
            const Spacer(),
            if (trailing != null) trailing,
            if (onTap != null && trailing == null)
              const Icon(Icons.arrow_forward_ios_rounded,
                  color: AppTheme.iconFaint, size: 14),
          ],
        ),
      ),
    );
  }
}
