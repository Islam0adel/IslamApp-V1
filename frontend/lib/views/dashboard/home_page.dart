import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../auth/login_screen.dart';
import 'coding_page.dart';
import 'daily_page.dart';
import 'reports_dashboard_page.dart';
import 'settings_page.dart';
import '../../main.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/coding_service.dart';
import '../../models/coding_model.dart';
import '../../services/permissions_service.dart';
import '../../views/dashboard/inventory_page.dart'; // تأكد من المسار الصحيح
import 'stock_balance_page.dart'; // تأكد من المسار الصحيح
// import '../../views/dashboard/supplier_page.dart';
import 'suppliers_dashboard_page.dart'; // ✅ استيراد الصفحة الجديدة
import 'package:firebase_auth/firebase_auth.dart';

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
  bool _permissionsLoaded = false;

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

    if (!mounted) return;

    setState(() {
      _permissionsLoaded = true;
    });

    await _loadBranchesAndCheck();
  } catch (e) {
    print("خطأ في تحميل البيانات: $e");

    if (mounted) {
      setState(() {
        _permissionsLoaded = true;
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

    // ==========================================================
    // 1) قراءة الفروع من Hive
    // ==========================================================

    final dynamic rawData =
        codingBox.get(localKey, defaultValue: []);

    if (rawData is List) {
      for (final item in rawData) {
        if (item is Map &&
            item['name'] != null &&
            item['code'] != null) {
          fetchedBranches.add({
            'name': item['name'].toString(),
            'code': item['code'].toString(),
          });
        }
      }
    }

    // ==========================================================
    // 2) لو Hive فاضي فقط، جلب الفروع من السيرفر
    // ==========================================================

    if (fetchedBranches.isEmpty) {
      print("📥 الفروع غير موجودة محلياً.. جاري الجلب من السيرفر");

      final List<CodingModel> branchesData =
          await _codingService.getCodingList(
        companyCode: widget.companyCode,
        category: "branches",
      );

      fetchedBranches = branchesData
          .map(
            (item) => {
              'name': item.name,
              'code': item.code,
            },
          )
          .toList();
    }

    // ==========================================================
    // 3) قراءة الفروع المسموحة
    // ==========================================================

    final List<String>? allowed =
        PermissionsService().allowedBranches;

    List<Map<String, String>> filteredBranches;

    if (allowed != null && !allowed.contains('all')) {
      filteredBranches = fetchedBranches
          .where(
            (branch) => allowed.contains(branch['code']),
          )
          .toList();
    } else {
      filteredBranches = List<Map<String, String>>.from(
        fetchedBranches,
      );
    }

    // ==========================================================
    // 4) إضافة "كل الفروع" لو مسموح
    // ==========================================================

    if (allowed == null || allowed.contains('all')) {
      filteredBranches.insert(
        0,
        {
          'name': 'كل الفروع',
          'code': 'all',
        },
      );
    }

    // ==========================================================
    // 5) لو مفيش فروع مسموحة
    // ==========================================================

    if (filteredBranches.isEmpty) {
      filteredBranches = [
        {
          'name': 'لا توجد فروع مسموحة',
          'code': 'none',
        },
      ];
    }

    // ==========================================================
    // 6) إعداد رسالة اختيار الفرع
    // ==========================================================

    final String email =
        prefs.getString('user_email') ?? '';

    final bool showBranchDialog =
        prefs.getBool(
          'show_branch_dialog_$email',
        ) ?? true;

    // ==========================================================
    // 7) تحديد الفرع الحالي
    // ==========================================================

    String selectedCode = 'all';
    String selectedName = 'كل الفروع';

    final String? savedBranchCode =
        prefs.getString('selected_branch_code');

    final String? savedBranchName =
        prefs.getString('selected_branch_name');

    final bool savedBranchIsAllowed =
        savedBranchCode != null &&
        filteredBranches.any(
          (branch) =>
              branch['code'] == savedBranchCode,
        ) &&
        savedBranchCode != 'none';

    if (savedBranchIsAllowed) {
      // هنا savedBranchCode مضمون إنه غير null
      selectedCode = savedBranchCode;
      selectedName = savedBranchName ?? 'كل الفروع';
    } else {
      // ========================================================
      // الفروع الحقيقية فقط
      // ========================================================

      final List<Map<String, String>> realBranches =
          filteredBranches
              .where(
                (branch) =>
                    branch['code'] != 'all' &&
                    branch['code'] != 'none',
              )
              .toList();

      // --------------------------------------------------------
      // فرع واحد
      // --------------------------------------------------------

      if (realBranches.length == 1) {
        selectedCode =
            realBranches.first['code'] ?? 'all';

        selectedName =
            realBranches.first['name'] ?? 'فرع';

        await prefs.setString(
          'selected_branch_code',
          selectedCode,
        );

        await prefs.setString(
          'selected_branch_name',
          selectedName,
        );

        print(
          "✅ تم اختيار الفرع الوحيد: "
          "$selectedName ($selectedCode)",
        );
      }

      // --------------------------------------------------------
      // أكثر من فرع
      // --------------------------------------------------------

      else if (realBranches.length > 1) {
        selectedCode =
            realBranches.first['code'] ?? 'all';

        selectedName =
            realBranches.first['name'] ?? 'فرع';

        await prefs.setString(
          'selected_branch_code',
          selectedCode,
        );

        await prefs.setString(
          'selected_branch_name',
          selectedName,
        );

        print(
          "✅ تم اختيار الفرع الافتراضي: "
          "$selectedName ($selectedCode)",
        );
      }

      // --------------------------------------------------------
      // لا توجد فروع حقيقية
      // --------------------------------------------------------

      else if (filteredBranches.any(
        (branch) => branch['code'] == 'all',
      )) {
        selectedCode = 'all';
        selectedName = 'كل الفروع';
      } else {
        selectedCode = 'none';
        selectedName = 'لا توجد فروع';
      }
    }

    // ==========================================================
    // 8) تحديث الواجهة
    // ==========================================================

    if (!mounted) return;

    setState(() {
      _branches = filteredBranches;
      _selectedBranchCode = selectedCode;
      _selectedBranchName = selectedName;
      _isLoadingBranches = false;
    });

    // ==========================================================
    // 9) رسالة اختيار الفرع
    // ==========================================================

    final List<Map<String, String>> realBranches =
        filteredBranches
            .where(
              (branch) =>
                  branch['code'] != 'all' &&
                  branch['code'] != 'none',
            )
            .toList();

    if (realBranches.length > 1 &&
        showBranchDialog &&
        PermissionsService().canChangeBranch) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) {
          if (mounted) {
            _showBranchSelectionDialog();
          }
        },
      );
    }
  } catch (e) {
    print("❌ خطأ في جلب الفروع: $e");

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
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text(
          "اختر فرع العمل الحالي",
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold),
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
                color: isCurrent ? GlassStyle.warningFill20For(context) : GlassStyle.fill05For(context),
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: ListTile(
                  title: Text(
                    branchName,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: isCurrent ? AppTheme.warningFor(context) : AppTheme.textMainFor(context), fontFamily: 'Cairo', fontSize: 14),
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

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientDeep(context),
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
                      color: AppTheme.brandVersionText,
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
                    Icon(Icons.timer, color: AppTheme.dangerFor(context), size: 16),
                    const SizedBox(width: 5),
                    Text("وقت النشاط: ",
                        style: TextStyle(
                            color: AppTheme.textSoftFor(context),
                            fontSize: 13,
                            fontFamily: 'Cairo')),
                    Text(_formatDuration(_secondsElapsed),
                        style: TextStyle(
                            color: AppTheme.dangerFor(context),
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
                    _buildSmallInfo("الوقت", _currentTime, Icons.access_time, AppTheme.warningFor(context)),
                    _buildSmallInfo("التاريخ", _currentDate, Icons.calendar_today, AppTheme.infoSoftFor(context)),
                    _buildSmallInfo("الفرع النشط", _selectedBranchName, Icons.storefront, AppTheme.successFor(context)),
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
        Icon(Icons.business, color: AppTheme.warningFor(context), size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.companyName,
                  style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Cairo')),
              Text("مرحبا: ${widget.userName}",
                  style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontSize: 12,
                      fontFamily: 'Cairo')),
            ],
          ),
        ),
        // ✅ زر "تغيير الفرع" يظهر دائماً إذا كان لدى المستخدم صلاحية
        if (!_isLoadingBranches &&
    PermissionsService().canChangeBranch &&
    !PermissionsService().hasSingleBranch())
          InkWell(
            onTap: _showBranchSelectionDialog,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: GlassStyle.warningFill15For(context),
                border: Border.all(color: GlassStyle.warningBorder50For(context)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.swap_horiz, color: AppTheme.warningFor(context), size: 16),
                  SizedBox(width: 4),
                  Text("تغيير الفرع",
                      style: TextStyle(
                          color: AppTheme.warningFor(context),
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
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text("$label: ",
              style: TextStyle(
                  color: AppTheme.textSoftFor(context), fontSize: 11, fontFamily: 'Cairo')),
          Text(value,
              style: TextStyle(
                  color: AppTheme.textMainFor(context),
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
    if (_permissionsLoaded &&
    PermissionsService().canShowTreasury) {
      menuItems.add(
        _menuItem("حركة الخزينة", Icons.account_balance_wallet_rounded, AppTheme.successFor(context), () {
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
    if (_permissionsLoaded &&
    PermissionsService().canShowCoding) {
      menuItems.add(
        _menuItem("التكويد", Icons.code_rounded, AppTheme.warningFor(context), () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (c) => CodingPage(companyCode: widget.companyCode)),
          ).then((_) {
            _loadBranchesAndCheck();
          });
        }),
      );
    }

    // 3. 🔥 المشتريات والموردين (يؤدي إلى لوحة تحكم الموردين)
if (_permissionsLoaded &&PermissionsService().canShowSuppliers) {
  menuItems.add(
    _menuItem(
      "المشتريات والموردين",
      Icons.shopping_cart_rounded, // تغيير الأيقونة لأيقونة مشتريات
      AppTheme.infoSoftFor(context),
      () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (c) => SuppliersDashboardPage(
              companyCode: widget.companyCode,
              selectedBranchCode: _selectedBranchCode,
              userName: widget.userName,
            ),
          ),
        );
      },
    ),
  );
}

    // 4. 🔥 حركة الجرد (جديد)
// داخل HomePage - _buildMenuGrid()
if (_permissionsLoaded &&PermissionsService().canShowInventory) {
  menuItems.add(
    _menuItem("حركة الجرد", Icons.inventory_2_rounded, AppTheme.warningOrangeSoftFor(context), () {
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
if (_permissionsLoaded &&PermissionsService().canShowInventory) { // أو يمكنك إنشاء صلاحية جديدة canShowStock
  menuItems.add(
    _menuItem("رصيد المخزون", Icons.storage_rounded, AppTheme.extraTealFor(context), () {
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
    if (_permissionsLoaded &&PermissionsService().canShowReports) {
      menuItems.add(
        _menuItem("التقارير", Icons.analytics_rounded, AppTheme.extraPurpleFor(context), () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => ReportsDashboardPage(
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
      _menuItem("الاعدادات", Icons.settings_rounded, AppTheme.extraBlueGreyFor(context), () async {
        await Navigator.push(context, MaterialPageRoute(builder: (c) => const SettingsPage()));
        await PermissionsService().loadPermissions();

if (mounted) {
  setState(() {
    _permissionsLoaded = true;
  });
}
      }),
    );

    if (menuItems.isEmpty) {
      return Center(
        child: Text(
          "لا توجد صلاحيات متاحة لك",
          style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo', fontSize: 14),
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
              style: TextStyle(
                  color: AppTheme.textMainFor(context),
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
                    AppTheme.textMutedFor(context), () {})),
            const SizedBox(width: 12),
            Expanded(
                child: _bottomBtn("تسجيل الخروج", Icons.logout_rounded,
                    AppTheme.dangerFor(context), _handleLogout)),
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
          color: GlassStyle.fill03For(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: GlassStyle.line10For(context)),
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

  await prefs.remove('remember_me');
  await prefs.remove('saved_email');
  await prefs.remove('saved_password');

  await prefs.remove('user_name');
  await prefs.remove('company_name');
  await prefs.remove('company_code');
  await prefs.remove('job_code');
  await prefs.remove('job_title');
  await prefs.remove('user_email');

  await FirebaseAuth.instance.signOut();

  disposeGlobalListener();

  if (!mounted) return;

  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(
      builder: (context) => const LoginScreen(),
    ),
    (route) => false,
  );
}

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.warningOrangeFor(context),
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