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
  String _currentDate = "";
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

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

  // دالة تحويل الثواني لتنسيق (ساعة:دقيقة:ثانية)
  String _formatDuration(int totalSeconds) {
    int hours = totalSeconds ~/ 3600;
    int minutes = (totalSeconds % 3600) ~/ 60;
    int seconds = totalSeconds % 60;
    return "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _timer.cancel();
    _fadeController.dispose();
    super.dispose();
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
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    bool isDesktop = screenWidth > 900; // لو الشاشة أكبر من 900 بكسل نعتبرها لابتوب

    return Scaffold(
      appBar: isDesktop ? null : AppBar(
        title: Text(widget.companyName),
        centerTitle: true,
        backgroundColor: const Color(0xFF1A237E),
        elevation: 0,
      ),
      // المنيو تظهر كـ Drawer فقط على الموبايل
      drawer: isDesktop ? null : _buildDrawerContent(),
      body: Row(
        children: [
          // لو لابتوب، القائمة الجانبية ثابتة هنا
          if (isDesktop)
            Container(
              width: 260,
              color: const Color(0xFF0D1117),
              child: _buildDrawerContent(),
            ),
          
          // محتوى الصفحة الرئيسي
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF1A237E), Color(0xFF3949AB)],
                ),
              ),
              child: FadeTransition(
                opacity: _fadeController,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      if (isDesktop) _buildDesktopHeader(),
                      const SizedBox(height: 20),
                      _buildStatCard("مرحباً بك", widget.userName, Icons.person, Colors.orangeAccent),
                      const SizedBox(height: 15),
                      // كارت وقت الجلسة باللون الأحمر والتنسيق الجديد
                      _buildStatCard(
                        "وقت الجلسة الحالي", 
                        _formatDuration(_secondsElapsed), 
                        Icons.timer, 
                        Colors.redAccent, 
                        valueColor: Colors.redAccent
                      ),
                      const SizedBox(height: 15),
                      _buildStatCard("التاريخ والوقت", "$_currentDate | $_currentTime", Icons.calendar_month, Colors.lightBlueAccent),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(widget.companyName, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        IconButton(onPressed: _handleLogout, icon: const Icon(Icons.power_settings_new, color: Colors.redAccent)),
      ],
    );
  }

  Widget _buildDrawerContent() {
    return ListView(
      children: [
        UserAccountsDrawerHeader(
          decoration: const BoxDecoration(color: Colors.transparent),
          accountName: Text(widget.userName, style: const TextStyle(fontWeight: FontWeight.bold)),
          accountEmail: const Text("النظام نشط حالياً"),
          currentAccountPicture: const CircleAvatar(backgroundColor: Colors.white24, child: Icon(Icons.person, color: Colors.white)),
        ),
        _drawerItem(Icons.edit_calendar, "شاشة التكويد", () {
          Navigator.push(context, MaterialPageRoute(builder: (context) => const CodingPage()));
        }),
        _drawerItem(Icons.shopping_cart, "المبيعات", () {}),
        _drawerItem(Icons.local_shipping, "الموردين", () {}),
        _drawerItem(Icons.settings, "الإعدادات", () {}),
        const Divider(color: Colors.white12),
        _drawerItem(Icons.exit_to_app, "خروج", _handleLogout, isLogout: true),
      ],
    );
  }

  Widget _drawerItem(IconData icon, String title, VoidCallback onTap, {bool isLogout = false}) {
    return ListTile(
      leading: Icon(icon, color: isLogout ? Colors.redAccent : Colors.white70),
      title: Text(title, style: TextStyle(color: isLogout ? Colors.redAccent : Colors.white)),
      onTap: onTap,
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color iconColor, {Color valueColor = Colors.white}) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 15),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 30),
            const SizedBox(width: 20),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 5),
                Text(value, style: TextStyle(color: valueColor, fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}