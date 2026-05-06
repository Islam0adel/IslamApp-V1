import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

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

  String _formatTimer(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: Row(
        children: [
          // 1. القائمة الجانبية على اليمين (الخلفية الكحلي)
          Container(
            width: 280,
            color: const Color(0xFF1A237E),
            child: Column(
              children: [
                const SizedBox(height: 50),
                const Icon(Icons.account_balance_wallet, size: 50, color: Colors.white),
                const SizedBox(height: 10),
                const Text("IslamApp 1.0", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 40),
                
                // الأزرار تحت بعض على اليمين
                _buildSidebarItem(Icons.edit_note_rounded, "اليومية", "/daily"),
                _buildSidebarItem(Icons.point_of_sale_rounded, "تقرير المبيعات", "/sales"),
                _buildSidebarItem(Icons.assessment_rounded, "التقارير المالية", "/finance"),
                _buildSidebarItem(Icons.settings_rounded, "الإعدادات", "/settings"),
                _buildSidebarItem(Icons.support_agent_rounded, "الدعم الفني", "/support"),
                
                const Spacer(),
                // زر الخروج
                _buildSidebarItem(Icons.logout_rounded, "خروج", "/login", isLogout: true),
                const SizedBox(height: 20),
              ],
            ),
          ),

          // 2. المحتوى الرئيسي على الشمال
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(30.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // كارت اسم الشركة والبيانات
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(30),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(25),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20)
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("المؤسسة الحالية", style: TextStyle(color: Colors.grey, fontSize: 16)),
                            const SizedBox(height: 10),
                            const Text("شركة بيت اللوز", 
                              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF1A237E))),
                            const SizedBox(height: 5),
                            Text("المستخدم: إسلام عادل", style: TextStyle(color: Colors.grey[700], fontSize: 18)),
                          ],
                        ),
                        // ركن الوقت والمؤقت
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _buildInfoTile(Icons.calendar_today, _currentDate),
                            _buildInfoTile(Icons.access_time, _currentTime),
                            _buildInfoTile(Icons.timer_outlined, "مدة الجلسة: ${_formatTimer(_secondsElapsed)}", isHighlight: true),
                          ],
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 40),
                  const Text("نظرة عامة على النظام", 
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  
                  // مساحة لوضع الرسوم البيانية مستقبلاً
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white),
                      ),
                      child: const Center(
                        child: Text("هنا سيتم عرض تقارير مبيعات سريعة", style: TextStyle(color: Colors.grey)),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ويدجت عناصر القائمة الجانبية
  Widget _buildSidebarItem(IconData icon, String title, String route, {bool isLogout = false}) {
    return ListTile(
      onTap: () => Navigator.pushReplacementNamed(context, route),
      leading: Icon(icon, color: isLogout ? Colors.redAccent : Colors.white70),
      title: Text(title, style: TextStyle(color: isLogout ? Colors.redAccent : Colors.white, fontSize: 16)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 25, vertical: 5),
      hoverColor: Colors.white10,
    );
  }

  // ويدجت عرض المعلومات (تاريخ/وقت/مؤقت)
  Widget _buildInfoTile(IconData icon, String text, {bool isHighlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: TextStyle(
            fontSize: 16, 
            fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
            color: isHighlight ? Colors.green : Colors.black87
          )),
          const SizedBox(width: 10),
          Icon(icon, size: 20, color: isHighlight ? Colors.green : Colors.grey),
        ],
      ),
    );
  }
}