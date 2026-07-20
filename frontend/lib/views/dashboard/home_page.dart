import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../auth/login_screen.dart';
import 'coding_page.dart';
import 'daily_page.dart';
import 'reports_page.dart';
import 'settings_page.dart';
import '../../main.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/coding_service.dart';
import '../../models/coding_model.dart';
import '../../services/permissions_service.dart';
import '../../views/dashboard/inventory_page.dart'; // تأكد من المسار الصحيح
import 'stock_balance_page.dart'; // تأكد من المسار الصحيح
import '../../views/dashboard/supplier_page.dart';

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

  final CodingService _codingService = CodingService();
  String _selectedBranchName = "كل الفروع";
  String _selectedBranchCode = "all";
  List<Map<String, String>> _branches = [{'name': 'كل الفروع', 'code': 'all'}];
  bool _isLoadingBranches = true;
  bool _isLoading = true;

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAllData();
    });
  }

  Future<void> _loadAllData() async {
    try {
      await PermissionsService().loadPermissions();
      await _loadBranchesAndCheck();
      initializeGlobalListener(widget.companyCode);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      print("خطأ في تحميل البيانات: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadBranchesAndCheck() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final Box codingBox = Hive.box('coding_box');
    final String localKey = "${widget.companyCode}_branches";

    List<Map<String, String>> fetchedBranches = [];
    bool hasLocalData = false;

    // 1️⃣ قراءة الفروع من Hive
    final dynamic rawData = codingBox.get(localKey, defaultValue: []);
    if (rawData is List && rawData.isNotEmpty) {
      for (var item in rawData) {
        if (item is Map && item['name'] != null && item['code'] != null) {
          fetchedBranches.add({'name': item['name'].toString(), 'code': item['code'].toString()});
        }
      }
      if (fetchedBranches.isNotEmpty) {
        hasLocalData = true;
      }
    }

    // 2️⃣ جلب من السيرفر إذا لم تكن محلية
    if (!hasLocalData) {
      print("📥 الفروع غير موجودة محلياً.. جاري الجلب من السيرفر");
      List<CodingModel> branchesData = await _codingService.getCodingList(
        companyCode: widget.companyCode,
        category: "branches",
      );
      fetchedBranches = [];
      for (var item in branchesData) {
        fetchedBranches.add({'name': item.name, 'code': item.code});
      }
    }

    // 3️⃣ تصفية الفروع حسب صلاحية المستخدم
    final allowed = PermissionsService().allowedBranches;
    List<Map<String, String>> filteredBranches;
    if (allowed != null && !allowed.contains('all')) {
      // المستخدم لديه فروع محددة
      filteredBranches = fetchedBranches.where((b) => allowed.contains(b['code'])).toList();
    } else {
      // المستخدم لديه صلاحية كل الفروع (أو null)
      filteredBranches = List.from(fetchedBranches);
    }

    // ═══ إضافة خيار "كل الفروع" دائماً إذا كانت الصلاحية تسمح بذلك ═══
    if (allowed == null || allowed.contains('all')) {
      // نضيف "كل الفروع" في البداية (بغض النظر عن عدد الفروع)
      filteredBranches.insert(0, {'name': 'كل الفروع', 'code': 'all'});
    }

    // إذا كانت القائمة فارغة (لا توجد فروع مسموحة)، نضيف عنصر وهمي
    if (filteredBranches.isEmpty) {
      filteredBranches = [{'name': 'لا توجد فروع مسموحة', 'code': 'none'}];
    }

    if (mounted) {
      setState(() {
        _branches = filteredBranches;
        _isLoadingBranches = false;

        // 4️⃣ اختيار الفرع الافتراضي
        String? savedBranchCode = prefs.getString('selected_branch_code');
        String? savedBranchName = prefs.getString('selected_branch_name');

        bool isAllowed = _branches.any((b) => b['code'] == savedBranchCode);
        if (savedBranchCode != null && isAllowed && savedBranchCode != 'none') {
          _selectedBranchCode = savedBranchCode;
          _selectedBranchName = savedBranchName ?? "كل الفروع";
        } else {
          // استبعاد 'none' للحصول على الفروع الحقيقية (بما فيها 'all')
          var realBranches = _branches.where((b) => b['code'] != 'none').toList();
          if (realBranches.length == 1) {
            // خيار واحد فقط (قد يكون 'all' أو فرع حقيقي)
            _selectedBranchCode = realBranches[0]['code']!;
            _selectedBranchName = realBranches[0]['name']!;
            prefs.setString('selected_branch_code', _selectedBranchCode);
            prefs.setString('selected_branch_name', _selectedBranchName);
          } else if (realBranches.isNotEmpty) {
            // عدة خيارات → نختار 'all' إذا وجد، وإلا الأول
            if (_branches.any((b) => b['code'] == 'all')) {
              _selectedBranchCode = 'all';
              _selectedBranchName = 'كل الفروع';
            } else {
              _selectedBranchCode = realBranches[0]['code']!;
              _selectedBranchName = realBranches[0]['name']!;
            }
            prefs.setString('selected_branch_code', _selectedBranchCode);
            prefs.setString('selected_branch_name', _selectedBranchName);
          } else {
            // لا توجد خيارات
            _selectedBranchCode = 'none';
            _selectedBranchName = 'لا توجد فروع';
          }
        }
      });

      // ═══ عرض الحوار التلقائي فقط إذا كان عدد الفروع الحقيقية (غير 'all' و 'none') > 1 ═══
      var realBranches = _branches.where((b) => b['code'] != 'all' && b['code'] != 'none').toList();
      if (realBranches.length > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showBranchSelectionDialog();
        });
      }
    }
  } catch (e) {
    print("خطأ في جلب الفروع: $e");
    if (mounted) {
      setState(() {
        _isLoadingBranches = false;
      });
    }
  }
}

  void _showBranchSelectionDialog() {
    showDialog(
      context: context,
      barrierDismissible: _selectedBranchCode != "all",
      builder: (context) => AlertDialog(
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
              String branchName = _branches[index]['name']!;
              String branchCode = _branches[index]['code']!;
              bool isCurrent = _selectedBranchCode == branchCode;
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
                    await prefs.setString('selected_branch_code', branchCode);
                    await prefs.setString('selected_branch_name', branchName);
                    if (mounted) {
                      setState(() {
                        _selectedBranchCode = branchCode;
                        _selectedBranchName = branchName;
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
    );
  }

  String _formatDuration(int seconds) {
    int minutes = seconds ~/ 60;
    int remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Colors.cyanAccent),
        ),
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF020617),
              Color.fromARGB(255, 47, 54, 190),
              Color(0xFF020617)
            ],
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
                  style: TextStyle(
                      color: Color.fromARGB(213, 123, 248, 51),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2),
                ),
                const SizedBox(height: 10),
                _buildHeader(),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.timer, color: Colors.redAccent, size: 16),
                    const SizedBox(width: 5),
                    const Text("وقت النشاط: ",
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontFamily: 'Cairo')),
                    Text(_formatDuration(_secondsElapsed),
                        style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace')),
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
                    _buildSmallInfo("الفرع النشط", _selectedBranchName, Icons.storefront, Colors.greenAccent),
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
              Text(widget.companyName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Cairo')),
              Text("مرحبا: ${widget.userName}",
                  style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      fontFamily: 'Cairo')),
            ],
          ),
        ),
        // ✅ زر "تغيير الفرع" يظهر دائماً إذا كان لدى المستخدم صلاحية
        if (!_isLoadingBranches && PermissionsService().canChangeBranch)
          InkWell(
            onTap: _showBranchSelectionDialog,
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
                  Text("تغيير الفرع",
                      style: TextStyle(
                          color: Colors.amber,
                          fontSize: 11,
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold)),
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
          Text("$label: ",
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11, fontFamily: 'Cairo')),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Cairo')),
        ],
      ),
    );
  }

  Widget _buildMenuGrid() {
    List<Widget> menuItems = [];

    // 1. حركة الخزينة
    if (PermissionsService().canShowTreasury) {
      menuItems.add(
        _menuItem("حركة الخزينة", Icons.account_balance_wallet_rounded, Colors.greenAccent, () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => DailyPage(
                companyCode: widget.companyCode,
                selectedBranchCode: _selectedBranchCode,
                userName: widget.userName,
              ),
            ),
          );
        }),
      );
    }

    // 2. التكويد
    if (PermissionsService().canShowCoding) {
      menuItems.add(
        _menuItem("التكويد", Icons.code_rounded, Colors.amber, () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (c) => CodingPage(companyCode: widget.companyCode)),
          ).then((_) {
            _loadBranchesAndCheck();
          });
        }),
      );
    }

    // 3. 🔥 حركة الموردين (جديد)
    if (PermissionsService().canShowSuppliers) {
  menuItems.add(
    _menuItem("حركة الموردين", Icons.local_shipping_rounded, Colors.lightBlueAccent, () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (c) => SupplierPage(
            companyCode: widget.companyCode,
            selectedBranchCode: _selectedBranchCode,
            userName: widget.userName,
          ),
        ),
      );
    }),
  );
}

    // 4. 🔥 حركة الجرد (جديد)
// داخل HomePage - _buildMenuGrid()
if (PermissionsService().canShowInventory) {
  menuItems.add(
    _menuItem("حركة الجرد", Icons.inventory_2_rounded, Colors.orangeAccent, () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (c) => InventoryPage(
            companyCode: widget.companyCode,
            selectedBranchCode: _selectedBranchCode,   // ✅ تمرير الفرع النشط
          ),
        ),
      );
    }),
  );
}
// 5. 🔥 رصيد المخزون
if (PermissionsService().canShowInventory) { // أو يمكنك إنشاء صلاحية جديدة canShowStock
  menuItems.add(
    _menuItem("رصيد المخزون", Icons.storage_rounded, Colors.tealAccent, () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (c) => StockBalancePage(
            companyCode: widget.companyCode,
            selectedBranchCode: _selectedBranchCode,
          ),
        ),
      );
    }),
  );
}

    // 5. التقارير
    if (PermissionsService().canShowReports) {
      menuItems.add(
        _menuItem("التقارير", Icons.analytics_rounded, Colors.purpleAccent, () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => ReportsPage(
                companyCode: widget.companyCode,
                selectedBranchCode: _selectedBranchCode,
              ),
            ),
          );
        }),
      );
    }

    // 6. الإعدادات (دائماً ظاهرة)
    menuItems.add(
      _menuItem("الاعدادات", Icons.settings_rounded, Colors.blueGrey, () async {
        await Navigator.push(context, MaterialPageRoute(builder: (c) => const SettingsPage()));
        await PermissionsService().loadPermissions();
        if (mounted) {
          setState(() {});
        }
      }),
    );

    if (menuItems.isEmpty) {
      return const Center(
        child: Text(
          "لا توجد صلاحيات متاحة لك",
          style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 14),
        ),
      );
    }

    // 🔥 تصميم متجاوب: تغيير عدد الأعمدة وحجم البطاقات حسب عرض الشاشة
    return LayoutBuilder(
      builder: (context, constraints) {
        double screenWidth = constraints.maxWidth;
        int crossAxisCount;
        double childAspectRatio;

        if (screenWidth > 800) {
          // شاشات كبيرة (لاب توب / ديسكتوب)
          crossAxisCount = 4;
          childAspectRatio = 1.3;
        } else if (screenWidth > 500) {
          // شاشات متوسطة (تابلت)
          crossAxisCount = 3;
          childAspectRatio = 1.2;
        } else {
          // شاشات صغيرة (موبايل)
          crossAxisCount = 2;
          childAspectRatio = 1.1;
        }

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 15,
          crossAxisSpacing: 15,
          childAspectRatio: childAspectRatio,
          children: menuItems,
        );
      },
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
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Cairo'),
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
                child: _bottomBtn("الدعم الفني", Icons.headset_mic_rounded,
                    Colors.white60, () {})),
            const SizedBox(width: 12),
            Expanded(
                child: _bottomBtn("تسجيل الخروج", Icons.logout_rounded,
                    Colors.redAccent, _handleLogout)),
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
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Cairo')),
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

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    _mainController.dispose();
    super.dispose();
  }
}