import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../auth/login_screen.dart';
import 'coding_page.dart';
import 'daily_page.dart';

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
  String _currentDate = "";
  late AnimationController _mainController;

  @override
  void initState() {
    super.initState();
    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _secondsElapsed++;
          _currentTime = DateFormat('hh:mm a').format(DateTime.now());
          _currentDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
        });
      }
    });
  }

  // دالة تحويل الثواني لشكل وقت (00:00:00)
  String _formatDuration(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF020617), Color.fromARGB(255, 47, 54, 190), Color(0xFF020617)], // الخلفية المموجة الداكنة
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            child: Column(
              children: [
                // اسم البرنامج في الأعلى
                const Text(
                  "IslamApp V1.0",
                  style: TextStyle(color: Color.fromARGB(213, 123, 248, 51), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
                const SizedBox(height: 10),
                
                // الهيدر (الشركة والمستخدم)
                _buildHeader(),
                const SizedBox(height: 15),

                // وقت النشاط باللون الأحمر
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.timer, color: Colors.redAccent, size: 16),
                    const SizedBox(width: 5),
                    const Text("وقت النشاط: ", style: TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'Cairo')),
                    Text(_formatDuration(_secondsElapsed), 
                      style: const TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                  ],
                ),
                const SizedBox(height: 15),

                // الوقت والتاريخ جنب بعض (بيتقلبوا فوق بعض في الشاشات الصغيرة تلقائياً)
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    _buildSmallInfo("الوقت", _currentTime, Icons.access_time, Colors.amber),
                    _buildSmallInfo("التاريخ", _currentDate, Icons.calendar_today, Colors.lightBlueAccent),
                  ],
                ),
                const SizedBox(height: 20),

                _buildMenuGrid(), // الجزء القادم
                const SizedBox(height: 20),
                _buildBottomActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return GlassCard(
      child: Row(
        children: [
          const Icon(Icons.business, color: Colors.amber, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.companyName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
                Text("مرحبا: ${widget.userName}", style: const TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'Cairo')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallInfo(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text("$label: ", style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'Cairo')),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
  Widget _buildMenuGrid() {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2, // زرارين في كل صف عشان الحجم ميكبرش
      mainAxisSpacing: 15,
      crossAxisSpacing: 15,
      childAspectRatio: 2.2, // نسبة العرض للطول عشان الزرار يبقى مستطيل صغير وشيك
      children: [
        _menuItem("حركة الخزينة", Icons.account_balance_wallet_rounded, Colors.greenAccent, () {
          Navigator.push(context, MaterialPageRoute(builder: (c) => DailyPage(companyCode: widget.companyCode)));
        }),
        _menuItem("التكويد", Icons.code_rounded, Colors.amber, () {
          Navigator.push(context, MaterialPageRoute(builder: (c) => CodingPage(companyCode: widget.companyCode)));
        }),
        
        _menuItem("حسابات الموردين", Icons.local_shipping_rounded, Colors.lightBlueAccent, () {}),
        _menuItem("حركة الجرد", Icons.inventory_2_rounded, Colors.orangeAccent, () {}),
        _menuItem("التقارير", Icons.analytics_rounded, Colors.purpleAccent, () {}),
        _menuItem("الاعدادات", Icons.settings_rounded, Colors.blueGrey, () {}),
      ],
    );
  }

  Widget _menuItem(String title, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: GlassCard(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28), // حجم الأيقونة مناسب للموبايل
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13, // خط متوسط وواضح
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo'
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomActions() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _bottomBtn("الدعم الفني", Icons.headset_mic_rounded, Colors.white60, () {}),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _bottomBtn("تسجيل الخروج", Icons.logout_rounded, Colors.redAccent, _handleLogout),
            ),
          ],
        ),
        const SizedBox(height: 15),
      ],
    );
  }

  Widget _bottomBtn(String label, IconData icon, Color color, VoidCallback action) {
    return InkWell(
      onTap: action,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleLogout() async {
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
} // نهاية الكلاس تمام يا هندسة