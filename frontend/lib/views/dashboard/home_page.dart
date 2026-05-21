import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../auth/login_screen.dart';
import 'coding_page.dart';
import 'daily_page.dart';
import 'settings_page.dart';
import '../../services/api_service.dart';

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

  final ApiService _apiService = ApiService();
  // متغيرات الفروع الجديدة
  String _selectedBranch = "كل الفروع"; // الفرع المختار حالياً
  List<String> _branches = ["كل الفروع"]; // قائمة الفروع التي ستأتي من السيرفر
  bool _isLoadingBranches = true;

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

    // جلب الفروع وعمل الفحص الذكي أول ما يفتح السستم
    _loadBranchesAndCheck();
  }

  // دالة جلب الفروع والفحص الذكي (المحدثة لقراءة التكويد المتزامن لحظياً)
  Future<void> _loadBranchesAndCheck() async {
    try {
      setState(() => _isLoadingBranches = true);

      // 🎯 السر هنا: استخدام نفس الدالة الموحدة التي نستخدمها في صفحة التكويد
      // هذا يضمن أن أي فرع تم إضافته أو حذفه في صفحة التكويد سيظهر هنا فوراً
      List<dynamic> rawBranches = await _apiService.getCodingData(widget.companyCode, "branches");

      if (!mounted) return;

      setState(() {
        // تحويل البيانات من JSON إلى قائمة نصوص لعرضها في الـ Dropdown أو الـ List
        _branches = ["كل الفروع"];
        for (var b in rawBranches) {
          _branches.add(b['name'].toString());
        }
        
        _isLoadingBranches = false;

        // منطق اختيار الفرع الافتراضي...
        if (_branches.length > 1 && _selectedBranch == "كل الفروع") {
           // لو مفيش فرع مختار، افتح النافذة ليختار المستخدم
           WidgetsBinding.instance.addPostFrameCallback((_) {
             _showBranchSelectionDialog();
           });
        }
      });
    } catch (e) {
      print("خطأ في ربط بيانات الهوم باج: $e");
      setState(() => _isLoadingBranches = false);
    }
  }

  // نافذة اختيار الفرع الإجبارية عند الدخول أو التغيير
  void _showBranchSelectionDialog() async {
    // 1. التحديث اللحظي من السيرفر
    setState(() => _isLoadingBranches = true);
    
    try {
      List<dynamic> rawBranches = await _apiService.getCodingData(widget.companyCode, "branches");
      
      List<String> updatedBranches = ["كل الفروع"];
      for (var b in rawBranches) {
        if (b['name'] != null) updatedBranches.add(b['name'].toString());
      }
      
      if (!mounted) return;

      setState(() {
        _branches = updatedBranches;
        _isLoadingBranches = false;
      });

      // 2. الشرط الذكي: لا تفتح النافذة إذا كان هناك فرع واحد فقط (أو لا يوجد غير "كل الفروع")
      // ملاحظة: إذا كان _branches تحتوي فقط على "كل الفروع" أو فرع واحد مكوّد، الطول سيكون 1 أو 2
      if (_branches.length <= 2) {
        // إذا كان هناك فرع واحد مكوّد، نختاره تلقائياً
        if (_branches.length == 2) {
           String autoBranch = _branches[1];
           final prefs = await SharedPreferences.getInstance();
           await prefs.setString('selected_branch', autoBranch);
           setState(() => _selectedBranch = autoBranch);
        }
        return; // خروج: لا تفتح النافذة
      }

    } catch (e) {
      if (mounted) setState(() => _isLoadingBranches = false);
      return; // خروج في حالة الخطأ
    }

    // 3. فتح الديالوج فقط إذا كان هناك أكثر من فرع (أكثر من 2 يعني: كل الفروع + فرع 1 + فرع 2)
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: _selectedBranch != "كل الفروع",
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          title: const Text(
            "اختر فرع العمل الحالي",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _branches.length,
              itemBuilder: (context, index) {
                String branchName = _branches[index];
                bool isCurrent = _selectedBranch == branchName;
                return Card(
                  color: isCurrent ? Colors.amber.withOpacity(0.2) : Colors.white.withOpacity(0.05),
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  child: ListTile(
                    title: Text(
                      branchName,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: isCurrent ? Colors.amber : Colors.white, fontFamily: 'Cairo', fontSize: 14),
                    ),
                    onTap: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('selected_branch', branchName);
                      if (mounted) {
                        setState(() {
                          _selectedBranch = branchName;
                        });
                      }
                      Navigator.pop(context);
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

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
            colors: [Color(0xFF020617), Color.fromARGB(255, 47, 54, 190), Color(0xFF020617)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            child: Column(
              children: [
                const Text(
                  "IslamApp V1.0",
                  style: TextStyle(color: Color.fromARGB(213, 123, 248, 51), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
                const SizedBox(height: 10),
                
                // الهيدر المطور (يحتوي على زر تغيير الفرع الفوري)
                _buildHeader(),
                const SizedBox(height: 15),

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

                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    _buildSmallInfo("الوقت", _currentTime, Icons.access_time, Colors.amber),
                    _buildSmallInfo("التاريخ", _currentDate, Icons.calendar_today, Colors.lightBlueAccent),
                    // كارت صغير يعرض الفرع النشط حالياً تحت التاريخ والوقت
                    _buildSmallInfo("الفرع النشط", _selectedBranch, Icons.storefront, Colors.greenAccent),
                  ],
                ),
                const SizedBox(height: 20),

                _buildMenuGrid(), 
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
          // 👈 الزرار هيظهر هنا دايماً أول ما الفروع تحمل عشان تضغط عليه وتغير الفرع
          if (!_isLoadingBranches)
            InkWell(
              onTap: _showBranchSelectionDialog, // بيفتح القائمة لما تضغط عليه
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.15),
                  border: Border.all(color: Colors.amber.withOpacity(0.5)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.swap_horiz, color: Colors.amber, size: 16),
                    SizedBox(width: 4),
                    Text("تغيير الفرع", style: TextStyle(color: Colors.amber, fontSize: 11, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                  ],
                ),
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
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
        ],
      ),
    );
  }

  Widget _buildMenuGrid() {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 15,
      crossAxisSpacing: 15,
      childAspectRatio: 1.1,
      children: [
        // تعديل التوجيه: نمرر الـ _selectedBranch للشاشات الأخرى لتصفية الحركات بناءً عليه بالملي
        _menuItem("حركة الخزينة", Icons.account_balance_wallet_rounded, Colors.greenAccent, () {
          Navigator.push(context, MaterialPageRoute(builder: (c) => DailyPage(
            companyCode: widget.companyCode, 
            selectedBranch: _selectedBranch,
            userName: widget.userName, // 👈 تمرير اسم المستخدم
          )));
        }),
        _menuItem("التكويد", Icons.code_rounded, Colors.amber, () {
          Navigator.push(context, MaterialPageRoute(builder: (c) => CodingPage(companyCode: widget.companyCode)));
        }),
        _menuItem("حسابات الموردين", Icons.local_shipping_rounded, Colors.lightBlueAccent, () {}),
        _menuItem("حركة الجرد", Icons.inventory_2_rounded, Colors.orangeAccent, () {}),
        _menuItem("التقارير", Icons.analytics_rounded, Colors.purpleAccent, () {}),
        _menuItem("الاعدادات", Icons.settings_rounded, Colors.blueGrey, () {
          Navigator.push(context, MaterialPageRoute(builder: (c) => const SettingsPage()));
        }),
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
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
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
            Expanded(child: _bottomBtn("الدعم الفني", Icons.headset_mic_rounded, Colors.white60, () {})),
            const SizedBox(width: 12),
            Expanded(child: _bottomBtn("تسجيل الخروج", Icons.logout_rounded, Colors.redAccent, _handleLogout)),
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
            Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
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
}