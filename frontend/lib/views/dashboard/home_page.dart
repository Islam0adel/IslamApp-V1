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
          _currentTime = DateFormat('hh:mm:ss a').format(DateTime.now());
          _currentDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
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
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _mainController,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // --- الجزء العلوي (Header) ---
                  _buildHeader(isDesktop),
                  
                  const SizedBox(height: 10),
                  // التاريخ والوقت (تحت الاسم في الموبايل، وجمب بعض في اللاب)
                  _buildDateTimeBar(isDesktop),

                  const SizedBox(height: 25),

                  // --- الجزء الأوسط (التبويبات الكبيرة) ---
                  Expanded(
                    child: _buildMainGrid(isDesktop ? 3 : 2),
                  ),

                  const SizedBox(height: 15),

                  // --- الجزء السفلي (أزرار الدعم والخروج) ---
                  _buildBottomActions(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // الهيدر: اسم المستخدم والشركة + وقت النشاط (أحمر فوق عالشمال)
  Widget _buildHeader(bool isDesktop) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.blueAccent.withOpacity(0.1),
              child: const Icon(Icons.person, color: Colors.blueAccent),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.userName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                Text(widget.companyName, style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
          ],
        ),
        // وقت النشاط (أحمر فاقع)
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text("وقت النشاط", style: TextStyle(color: Colors.white38, fontSize: 10)),
            Text(
              _formatDuration(_secondsElapsed),
              style: const TextStyle(color: Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
            ),
          ],
        ),
      ],
    );
  }

  // بار التاريخ والوقت
  Widget _buildDateTimeBar(bool isDesktop) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(_currentTime, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          if (isDesktop) ...[
            const SizedBox(width: 15),
            Text(_currentDate, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ] else ...[
             const SizedBox(width: 10),
             Text(_currentDate, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ]
        ],
      ),
    );
  }

  // شبكة الأزرار الكبيرة (الترتيب الجديد)
  Widget _buildMainGrid(int crossCount) {
    return GridView.count(
      crossAxisCount: crossCount,
      mainAxisSpacing: 15,
      crossAxisSpacing: 15,
      childAspectRatio: 2.2,
      children: [
        _moduleCard("حركة الخزينة", Icons.account_balance_wallet_rounded, Colors.tealAccent, () {}),
        _moduleCard("حسابات الموردين", Icons.local_shipping_rounded, Colors.orangeAccent, () {}),
        _moduleCard("التقارير", Icons.analytics_rounded, Colors.purpleAccent, () {}),
        _moduleCard("حركة الجرد", Icons.inventory_2_rounded, Colors.amberAccent, () {}),
        _moduleCard("التكويد", Icons.api_rounded, Colors.blueAccent, () {
          Navigator.push(context, MaterialPageRoute(builder: (context) => const CodingPage()));
        }),
        _moduleCard("الإعدادات", Icons.settings_suggest_rounded, Colors.blueGrey, () {}),
      ],
    );
  }

  Widget _moduleCard(String title, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: GlassCard(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 35),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // أزرار الدعم والخروج (تحت خالص)
  Widget _buildBottomActions() {
    return Row(
      children: [
        Expanded(
          child: _bottomBtn("الدعم الفني", Icons.headset_mic_rounded, Colors.white60, () {}),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: _bottomBtn("تسجيل الخروج", Icons.logout_rounded, Colors.redAccent, _handleLogout),
        ),
      ],
    );
  }

  Widget _bottomBtn(String label, IconData icon, Color color, VoidCallback action) {
    return InkWell(
      onTap: action,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}