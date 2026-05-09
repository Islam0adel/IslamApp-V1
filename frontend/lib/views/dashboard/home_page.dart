import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../auth/login_screen.dart';

class HomePage extends StatefulWidget {
  final String userName;
  final String companyName;
  final String companyCode;

  const HomePage({
    super.key,
    required this.userName,
    required this.companyName,
    required this.companyCode,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Timer _timer;
  int _secondsElapsed = 0;
  String _currentTime = "";
  String _currentDate = "";

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _secondsElapsed++;
          _currentTime = DateFormat('hh:mm:ss a').format(DateTime.now());
          _currentDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  // دالة تسجيل الخروج ومسح البيانات
  void _logout(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); 
    if (context.mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  String _formatTimer(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.of(context).size;
    // تحديد هل الجهاز موبايل بناءً على عرض الشاشة
    final bool isMobile = size.width < 800;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0D1117) : const Color(0xFFF0F2F5),
      // في الموبايل بنظهر AppBar فيه زرار القائمة
      appBar: isMobile 
        ? AppBar(
            title: Text(widget.companyName, style: const TextStyle(fontSize: 18)),
            backgroundColor: isDark ? const Color(0xFF161B22) : const Color(0xFF1A237E),
            elevation: 0,
          ) 
        : null,
      // قائمة الموبايل الجانبية
      drawer: isMobile ? Drawer(child: _buildSidebarContent(isDark, true)) : null,
      body: Row(
        children: [
          // لو مش موبايل، اظهر القائمة الجانبية ثابتة
          if (!isMobile)
            Container(
              width: 260,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF161B22) : const Color(0xFF1A237E),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10)],
              ),
              child: _buildSidebarContent(isDark, false),
            ),

          // المحتوى الرئيسي
          Expanded(
            child: SingleChildScrollView( // عشان الصفحة متضربش لو المحتوى كتر
              padding: EdgeInsets.all(isMobile ? 15.0 : 30.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(isDark, isMobile),
                  const SizedBox(height: 30),
                  _buildStatsGrid(isDark, isMobile),
                  const SizedBox(height: 30),
                  Text("النشاط الأخير", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
                  const SizedBox(height: 20),
                  _buildMainContentArea(isDark, size.height),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
// تصميم محتوى القائمة الجانبية (ثابت للموبايل والكمبيوتر)
  Widget _buildSidebarContent(bool isDark, bool inDrawer) {
    return Column(
      children: [
        const SizedBox(height: 50),
        const Icon(Icons.account_balance_wallet_rounded, size: 50, color: Colors.white),
        const SizedBox(height: 15),
        const Text("IslamApp 1.0", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        Text("Code: ${widget.companyCode}", style: const TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 40),
        _buildSidebarItem(Icons.dashboard_rounded, "الرئيسية", true, isDark),
        _buildSidebarItem(Icons.edit_note_rounded, "دفتر اليومية", false, isDark),
        _buildSidebarItem(Icons.point_of_sale_rounded, "المبيعات", false, isDark),
        _buildSidebarItem(Icons.assessment_rounded, "التقارير", false, isDark),
        _buildSidebarItem(Icons.settings_rounded, "الإعدادات", false, isDark),
        const Spacer(),
        _buildSidebarItem(Icons.logout_rounded, "خروج", false, isDark, isLogout: true),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildHeader(bool isDark, bool isMobile) {
    return isMobile 
    ? Column( // في الموبايل المعلومات تحت بعض
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Welcome : ${widget.userName}", style: TextStyle(color: isDark ? Colors.white70 : Colors.grey[800], fontSize: 18)),
          const SizedBox(height: 15),
          GlassCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildInfoRow(Icons.calendar_today, _currentDate, isDark),
                _buildInfoRow(Icons.access_time, _currentTime, isDark),
                _buildInfoRow(Icons.timer_outlined, "Log Time: ${_formatTimer(_secondsElapsed)}", isDark, isHighlight: true),
              ],
            ),
          ),
        ],
      )
    : Row( // في الكمبيوتر المعلومات بجانب بعض
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Company", style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600], fontSize: 16)),
              Text(widget.companyName, style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: isDark ? Colors.blue[400] : const Color(0xFF1A237E))),
              Text("Welcome: ${widget.userName}", style: TextStyle(color: isDark ? Colors.white70 : Colors.grey[800], fontSize: 18)),
            ],
          ),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _buildInfoRow(Icons.calendar_today, _currentDate, isDark),
                _buildInfoRow(Icons.access_time, _currentTime, isDark),
                _buildInfoRow(Icons.timer_outlined, "Log Time: ${_formatTimer(_secondsElapsed)}", isDark, isHighlight: true),
              ],
            ),
          ),
        ],
      );
  }

  Widget _buildStatsGrid(bool isDark, bool isMobile) {
    // في الموبايل بنعرض الكروت تحت بعض، في الكمبيوتر جنب بعض
    return isMobile 
      ? Column(
          children: [
            _buildStatCard('إجمالي الإيرادات', '0.00', Icons.trending_up, Colors.green, isDark),
            const SizedBox(height: 10),
            _buildStatCard('إجمالي المصروفات', '0.00', Icons.trending_down, Colors.red, isDark),
            const SizedBox(height: 10),
            _buildStatCard('صافي الربح', '0.00', Icons.account_balance, Colors.blue, isDark),
          ],
        )
      : Row(
          children: [
            Expanded(child: _buildStatCard('إجمالي الإيرادات', '0.00', Icons.trending_up, Colors.green, isDark)),
            const SizedBox(width: 20),
            Expanded(child: _buildStatCard('إجمالي المصروفات', '0.00', Icons.trending_down, Colors.red, isDark)),
            const SizedBox(width: 20),
            Expanded(child: _buildStatCard('صافي الربح', '0.00', Icons.account_balance, Colors.blue, isDark)),
          ],
        );
  }

  Widget _buildMainContentArea(bool isDark, double screenHeight) {
    return Container(
      width: double.infinity,
      height: 300, // ارتفاع ثابت للمساحة في الموبايل
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161B22) : Colors.white,
        borderRadius: BorderRadius.circular(25),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20)],
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.analytics_outlined, size: 60, color: isDark ? Colors.white10 : Colors.grey[200]),
            const SizedBox(height: 10),
            Text("لا توجد عمليات مسجلة اليوم", style: TextStyle(color: isDark ? Colors.white30 : Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarItem(IconData icon, String title, bool isActive, bool isDark, {bool isLogout = false}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
      decoration: BoxDecoration(
        color: isActive ? Colors.white.withOpacity(0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        onTap: () => isLogout ? _logout(context) : null,
        leading: Icon(icon, color: isLogout ? Colors.redAccent : (isActive ? Colors.white : Colors.white60)),
        title: Text(title, style: TextStyle(color: isLogout ? Colors.redAccent : (isActive ? Colors.white : Colors.white60))),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color, bool isDark) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            CircleAvatar(backgroundColor: color.withOpacity(0.1), child: Icon(icon, color: color)),
            const SizedBox(width: 15),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: isDark ? Colors.white70 : Colors.grey[600], fontSize: 12)),
                Text(value, style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text, bool isDark, {bool isHighlight = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: TextStyle(color: isHighlight ? Colors.green : (isDark ? Colors.white70 : Colors.black87), fontSize: 12)),
        const SizedBox(width: 5),
        Icon(icon, size: 14, color: isHighlight ? Colors.green : Colors.grey),
      ],
    );
  }
}