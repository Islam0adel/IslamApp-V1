import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../auth/login_screen.dart';
import 'coding_page.dart';

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

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late Timer _timer;
  int _secondsElapsed = 0;
  String _currentTime = "";
  late AnimationController _mainController;

  @override
  void initState() {
    super.initState();
    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..forward();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _secondsElapsed++;
          _currentTime = DateFormat('hh:mm:ss a').format(DateTime.now());
        });
      }
    });
  }

  String _formatDuration(int totalSeconds) {
    int h = totalSeconds ~/ 3600;
    int m = (totalSeconds % 3600) ~/ 60;
    int s = totalSeconds % 60;
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  void _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    _mainController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double width = MediaQuery.of(context).size.width;
    bool isDesktop = width > 900;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)], // ألوان Deep Blue احترافية
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _mainController,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Column(
                children: [
                  // 1. الجزء العلوي: بروفايل المستخدم والوقت
                  _buildHeader(isDesktop),
                  
                  const SizedBox(height: 20),

                  // 2. شريط العمليات السريعة (بديل القائمة الجانبية)
                  _buildQuickActionsBar(),

                  const SizedBox(height: 25),

                  // 3. المحتوى الرئيسي (الإحصائيات والتبويبات)
                  Expanded(
                    child: isDesktop 
                      ? Row(
                          children: [
                            Expanded(flex: 2, child: _buildMainGrid(3)),
                            const SizedBox(width: 20),
                            _buildSideStatsPanel(),
                          ],
                        )
                      : Column(
                          children: [
                            _buildSessionInfoCard(),
                            const SizedBox(height: 15),
                            Expanded(child: _buildMainGrid(2)),
                          ],
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

  // الهيدر: لوجو المستخدم واسم الشركة
  Widget _buildHeader(bool isDesktop) {
    return Row(
      children: [
        CircleAvatar(
          radius: 25,
          backgroundColor: Colors.blueAccent.withOpacity(0.2),
          child: const Icon(Icons.person, color: Colors.blueAccent, size: 30),
        ),
        const SizedBox(width: 15),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.userName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            Text(widget.companyName, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ],
        ),
        const Spacer(),
        if (isDesktop) Text(_currentTime, style: const TextStyle(color: Colors.white38, fontSize: 14)),
      ],
    );
  }

  // أزرار سريعة منظمة (الإعدادات، الدعم، الخروج)
  Widget _buildQuickActionsBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _quickBtn("الإعدادات", Icons.settings_outlined, Colors.grey, () {}),
          _quickBtn("الملف الشخصي", Icons.account_circle_outlined, Colors.grey, () {}),
          _quickBtn("الدعم الفني", Icons.help_outline, Colors.grey, () {}),
          _quickBtn("تسجيل خروج", Icons.logout, Colors.redAccent, _handleLogout),
        ],
      ),
    );
  }

  Widget _quickBtn(String label, IconData icon, Color color, VoidCallback action) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: ActionChip(
        backgroundColor: Colors.white.withOpacity(0.05),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        label: Text(label, style: TextStyle(color: color, fontSize: 12)),
        avatar: Icon(icon, color: color, size: 16),
        onPressed: action,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // شبكة التبويبات الكبيرة (التكويد، المبيعات، الموردين)
  Widget _buildMainGrid(int crossCount) {
    return GridView.count(
      crossAxisCount: crossCount,
      mainAxisSpacing: 15,
      crossAxisSpacing: 15,
      children: [
        _mainModuleCard("شاشة التكويد", Icons.api_rounded, Colors.blueAccent, () {
          Navigator.push(context, MaterialPageRoute(builder: (context) => const CodingPage()));
        }),
        _mainModuleCard("حسابات الموردين", Icons.local_shipping_outlined, Colors.orangeAccent, () {}),
        _mainModuleCard("حركة المبيعات", Icons.point_of_sale_rounded, Colors.greenAccent, () {}),
        _mainModuleCard("المخازن", Icons.inventory_2_outlined, Colors.purpleAccent, () {}),
        _mainModuleCard("التقارير", Icons.analytics_outlined, Colors.tealAccent, () {}),
        _mainModuleCard("الموظفين", Icons.badge_outlined, Colors.indigoAccent, () {}),
      ],
    );
  }

  Widget _mainModuleCard(String title, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: GlassCard(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 32),
            ),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // كارت وقت الجلسة (أحمر كما طلبت)
  Widget _buildSessionInfoCard() {
    return GlassCard(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer, color: Colors.redAccent),
          const SizedBox(width: 10),
          const Text("وقت النشاط: ", style: TextStyle(color: Colors.white70)),
          Text(_formatDuration(_secondsElapsed), style: const TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  // لوحة جانبية تظهر فقط في اللابتوب
  Widget _buildSideStatsPanel() {
    return Container(
      width: 300,
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("إحصائيات سريعة", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(color: Colors.white10, height: 30),
            _statRow("العمليات اليوم", "12", Colors.greenAccent),
            _statRow("تنبيهات المخزن", "3", Colors.orangeAccent),
            const Spacer(),
            _buildSessionInfoCard(),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white60)),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
        ],
      ),
    );
  }
}