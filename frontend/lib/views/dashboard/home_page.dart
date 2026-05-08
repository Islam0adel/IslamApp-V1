import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../views/widgets/glass_card.dart';

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
    // تحديث الوقت كل ثانية
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      // تحديد لون الخلفية بناءً على الثيم
      backgroundColor: isDark ? const Color(0xFF0D1117) : const Color(0xFFF0F2F5),
      body: Row(
        children: [
          // 1. القائمة الجانبية (Sidebar)
          Container(
            width: 260,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF161B22) : const Color(0xFF1A237E),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10)
              ],
            ),
            child: Column(
              children: [
                const SizedBox(height: 50),
                const Icon(Icons.account_balance_wallet_rounded, size: 50, color: Colors.white),
                const SizedBox(height: 15),
                const Text(
                  "IslamApp 1.0",
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
                const SizedBox(height: 10),
                Text("Code: ${widget.companyCode}", style: const TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 40),
                
                // عناصر القائمة
                _buildSidebarItem(Icons.dashboard_rounded, "الرئيسية", true),
                _buildSidebarItem(Icons.edit_note_rounded, "دفتر اليومية", false),
                _buildSidebarItem(Icons.point_of_sale_rounded, "المبيعات", false),
                _buildSidebarItem(Icons.assessment_rounded, "التقارير", false),
                _buildSidebarItem(Icons.settings_rounded, "الإعدادات", false),
                
                const Spacer(),
                // زر الخروج
                _buildSidebarItem(Icons.logout_rounded, "خروج", false, isLogout: true),
                const SizedBox(height: 20),
              ],
            ),
          ),

          // 2. المحتوى الرئيسي
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(30.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // الهيدر (اسم الشركة والوقت)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("المؤسسة الحالية", style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600], fontSize: 16)),
                          const SizedBox(height: 8),
                          Text(
                            widget.companyName,
                            style: TextStyle(
                              fontSize: 34, 
                              fontWeight: FontWeight.bold, 
                              color: isDark ? Colors.blue[400] : const Color(0xFF1A237E)
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text("مرحباً بك: ${widget.userName}", style: TextStyle(color: isDark ? Colors.white70 : Colors.grey[800], fontSize: 18)),
                        ],
                      ),
                      
                      // بلوك الوقت والتاريخ (تصميم GlassCard مصغر)
                      GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _buildInfoRow(Icons.calendar_today, _currentDate, isDark),
                            _buildInfoRow(Icons.access_time, _currentTime, isDark),
                            _buildInfoRow(Icons.timer_outlined, "مدة الجلسة: ${_formatTimer(_secondsElapsed)}", isDark, isHighlight: true),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 40),

                  // كروت الإحصائيات السريعة (التي كانت في التصميم القديم)
                  Row(
                    children: [
                      Expanded(child: _buildStatCard('إجمالي الإيرادات', '0.00', Icons.trending_up, Colors.green, isDark)),
                      const SizedBox(width: 20),
                      Expanded(child: _buildStatCard('إجمالي المصروفات', '0.00', Icons.trending_down, Colors.red, isDark)),
                      const SizedBox(width: 20),
                      Expanded(child: _buildStatCard('صافي الربح', '0.00', Icons.account_balance, Colors.blue, isDark)),
                    ],
                  ),

                  const SizedBox(height: 40),
                  Text("النشاط الأخير", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
                  const SizedBox(height: 20),

                  // مساحة عرض البيانات الرئيسية
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF161B22) : Colors.white,
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(color: isDark ? Colors.white10 : Colors.white),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.05), blurRadius: 20)
                        ],
                      ),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.analytics_outlined, size: 80, color: isDark ? Colors.white10 : Colors.grey[200]),
                            const SizedBox(height: 20),
                            Text("لا توجد عمليات مسجلة اليوم", style: TextStyle(color: isDark ? Colors.white30 : Colors.grey)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  
                  // التوقيع أسفل الصفحة
                  const SizedBox(height: 20),
                  const Center(
                    child: Column(
                      children: [
                        Text("IslamApp V1.0", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 12)),
                        Text("executed by Islam Adel", style: TextStyle(color: Colors.grey, fontSize: 10, fontStyle: FontStyle.italic)),
                      ],
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
  Widget _buildSidebarItem(IconData icon, String title, bool isActive, {bool isLogout = false}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
      decoration: BoxDecoration(
        color: isActive ? Colors.white.withOpacity(0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        onTap: () {
          if (isLogout) Navigator.pushReplacementNamed(context, '/login');
        },
        leading: Icon(icon, color: isLogout ? Colors.redAccent : (isActive ? Colors.white : Colors.white60)),
        title: Text(
          title, 
          style: TextStyle(
            color: isLogout ? Colors.redAccent : (isActive ? Colors.white : Colors.white60),
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal
          )
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ويدجت الإحصائيات (Stat Cards)
  Widget _buildStatCard(String title, String value, IconData icon, Color color, bool isDark) {
    return GlassCard(
      child: Container(
        padding: const EdgeInsets.all(5),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withOpacity(0.1),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 15),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: isDark ? Colors.white70 : Colors.grey[600], fontSize: 12)),
                Text(value, style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            )
          ],
        ),
      ),
    );
  }

  // ويدجت صفوف المعلومات (وقت/تاريخ)
  Widget _buildInfoRow(IconData icon, String text, bool isDark, {bool isHighlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text, 
            style: TextStyle(
              color: isHighlight ? Colors.green : (isDark ? Colors.white70 : Colors.black87),
              fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal
            )
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 16, color: isHighlight ? Colors.green : Colors.grey),
        ],
      ),
    );
  }
}