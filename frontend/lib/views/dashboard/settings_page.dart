import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../../main.dart'; // عشان نوصل لدالة تغيير الثيم

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key}); // شيلنا المتغيرات عشان متضربش في الهوم

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with TickerProviderStateMixin {
  late AnimationController _controller;
  bool _isDark = true;
  String _userName = "جاري التحميل...";
  String _companyName = "شركتي";
  bool _isLoadingData = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _loadUserData(); // تحميل البيانات محلياً لمنع الأخطاء
  }

  // دالة لقراءة البيانات المقروءة عند تسجيل الدخول
  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userName = prefs.getString('user_name') ?? "مستخدم غير معروف";
        _companyName = prefs.getString('company_name') ?? "شركتي";
        _isLoadingData = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // التحقق من الثيم الحالي للنظام أو التطبيق
    _isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('الإعدادات', 
          style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, color: Colors.white)),
        centerTitle: true,
        backgroundColor: Color.fromARGB(24, 75, 42, 194),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          // 1. الخلفية الأساسية المموجة بالتدرج اللوني الشبيه بباقي البرنامج
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _isDark 
                    ? [Color.fromARGB(255, 33, 31, 147), const Color(0xFF161B22)]
                    : [Color.fromARGB(255, 33, 44, 159), const Color(0xFF3949AB)],
                ),
              ),
            ),
          ),
          
          // 2. الدوائر الخلفية المدمجة لتعزيز مظهر الـ Glassmorphism
          Positioned(
            top: -100,
            right: -50,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.04),
              ),
            ),
          ),

          // 3. محتوى الصفحة داخل SafeArea
          SafeArea(
            child: FadeTransition(
              opacity: _controller,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Column(
                  children: [
                    // كارت الجلاس الخاص بمعلومات الحساب
                    GlassCard(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.person_rounded, color: Colors.cyanAccent, size: 40),
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: _isLoadingData 
                                ? const Align(
                                    alignment: Alignment.centerRight,
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent),
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _userName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          fontFamily: 'Cairo',
                                        ),
                                      ),
                                      Text(
                                        _companyName,
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.6),
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

                    // إعدادات المظهر والنظام
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
                              activeColor: Colors.cyanAccent,
                              onChanged: (val) {
                                // تغيير الثيم بشكل ديناميكي يسمع في الـ main فوراً
                                try {
                                  IslamApp.of(context).changeTheme(
                                    val ? ThemeMode.dark : ThemeMode.light
                                  );
                                } catch (e) {
                                  // حماية إضافية في حالة تعذر الوصول للسياق الشجري
                                  debugPrint("تنبيه الثيم: $e");
                                }
                              },
                            ),
                          ),
                          const Divider(color: Colors.white10, height: 20),
                          _buildSettingRow(
                            icon: Icons.translate_rounded,
                            title: 'لغة التطبيق',
                            trailing: const Text('العربية', 
                              style: TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo')),
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 25),

                    // إعدادات الحماية والدعم الفني
                    _buildSectionTitle("الدعم والخصوصية"),
                    const SizedBox(height: 10),
                    GlassCard(
                      child: Column(
                        children: [
                          _buildSettingRow(
                            icon: Icons.lock_reset_rounded,
                            title: 'تغيير كلمة المرور',
                            onTap: () {
                              // أكشن تغيير الباسورد هنا
                            },
                          ),
                          const Divider(color: Colors.white10, height: 20),
                          _buildSettingRow(
                            icon: Icons.contact_support_rounded,
                            title: 'تواصل مع الدعم الفني',
                            onTap: () {
                              // أكشن التواصل هنا
                            },
                          ),
                          const Divider(color: Colors.white10, height: 20),
                          _buildSettingRow(
                            icon: Icons.info_outline_rounded,
                            title: 'حول الإصدار V1.0',
                            onTap: () {},
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 40),
                    const Opacity(
                      opacity: 0.3,
                      child: Text(
                        "Designed & Developed by Islam",
                        style: TextStyle(color: Colors.white, fontSize: 10, letterSpacing: 1.1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ودجت لعنوان القسم الفرعي
  Widget _buildSectionTitle(String title) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Text(
          title,
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontFamily: 'Cairo',
          ),
        ),
      ),
    );
  }

  // ودجت لسطر الإعدادات المفرد
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
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 15),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontFamily: 'Cairo'),
            ),
            const Spacer(),
            if (trailing != null) trailing,
            if (onTap != null && trailing == null)
              const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white30, size: 14),
          ],
        ),
      ),
    );
  }
}