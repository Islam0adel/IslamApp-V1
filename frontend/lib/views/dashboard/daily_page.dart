import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import '../../services/coding_service.dart';
import 'daily_history_page.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'treasury_transfer_page.dart';
import '../../services/permissions_service.dart'; // ✅ استيراد خدمة الصلاحيات
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';

class DailyPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;      // كود الفرع (يُستخدم للفلترة والحفظ)
  final String? branchName;      // اسم الفرع (للعرض فقط)
  final String? userName;
  final Map<String, dynamic>? editItem;

  const DailyPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.branchName,
    this.userName,
    this.editItem,
  });

  @override
  State<DailyPage> createState() => _DailyPageState();
}

class _DailyPageState extends State<DailyPage> with WidgetsBindingObserver { // ✅ إضافة WidgetsBindingObserver للاستماع لعودة التطبيق
  final DailyService _dailyService = DailyService();
  final CodingService _codingService = CodingService();

  final _amountController = TextEditingController();
  final _statementController = TextEditingController();
  final _dateController = TextEditingController();

  bool _isLoading = false;
  bool _isUpdating = false; // ✅ متغير علم لمنع التحديث المتكرر

  Map<String, double> _treasuryBalances = {};

  int _currentSerial = 1;
  String? _selectedTreasury;
  String? _selectedCategory;

  List<Map<String, dynamic>> _treasuries = [];
  List<Map<String, dynamic>> _categories = [];

  // ✅ مستمع للتغييرات في صندوق اليوميات (للتحديث التلقائي للأرصدة)
  VoidCallback? _boxListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // ✅ إضافة المراقب
    _amountController.addListener(() => setState(() {}));
    
    // ✅ إضافة مستمع لتغييرات الصندوق
    _boxListener = () {
      // منع التحديث إذا كان التطبيق في حالة تحديث بالفعل
      if (!_isUpdating && mounted) {
        _loadInitialData();
      }
    };
    Hive.box('daily_transactions_box').listenable().addListener(_boxListener!);
    
    _loadInitialData();

    if (widget.editItem != null) {
      _amountController.text = widget.editItem!['amount']?.toString() ?? '';
      _statementController.text = widget.editItem!['statement'] ?? "";
      if (widget.editItem!['date'] != null) {
        String rawDate = widget.editItem!['date'].toString();
        _dateController.text = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
      } else {
        _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
      }
      _currentSerial = widget.editItem!['serial'] ?? 1;
      _selectedTreasury = widget.editItem!['treasury'];
      _selectedCategory = widget.editItem!['category'];
    } else {
      _amountController.clear();
      _statementController.clear();
      _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _amountController.removeListener(() => setState(() {}));
    if (_boxListener != null) {
      Hive.box('daily_transactions_box').listenable().removeListener(_boxListener!);
    }
    _amountController.dispose();
    _statementController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  // ✅ عند عودة التطبيق إلى المقدمة، نحدث الأرصدة
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) {
        _loadInitialData();
      }
    }
  }

  // دالة مساعدة لعرض اسم الفرع من كوده (يمكن استدعاءها من أي مكان)
  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    final Box codingBox = Hive.box('coding_box');
    final rawData = codingBox.get("${widget.companyCode}_branches", defaultValue: []);
    for (var item in rawData) {
      if (item['code']?.toString() == code) return item['name']?.toString() ?? "فرع غير معروف";
    }
    return "فرع غير معروف";
  }

  double _getLiveBalanceForTreasury(String treasuryName) {
    double currentBaseBalance = _treasuryBalances[treasuryName] ?? 0.0;

    if (_selectedTreasury == treasuryName && _selectedCategory != null) {
      double enteredAmount = double.tryParse(_amountController.text) ?? 0.0;
      if (widget.editItem != null && widget.editItem!['treasury'] == treasuryName) {
        double originalAmount = double.tryParse(widget.editItem!['amount'].toString()) ?? 0.0;
        String originalType = widget.editItem!['type'] ?? "وارد";
        if (originalType == "وارد") {
          currentBaseBalance -= originalAmount;
        } else if (originalType == "صادر") {
          currentBaseBalance += originalAmount;
        }
      }
      var matchingCategory = _categories.firstWhere(
        (c) => c['name'] == _selectedCategory,
        orElse: () => {}
      );
      if (matchingCategory.isNotEmpty) {
        String actionType = matchingCategory['type'] ?? "وارد";
        if (actionType == "وارد") {
          return currentBaseBalance + enteredAmount;
        } else if (actionType == "صادر") {
          return currentBaseBalance - enteredAmount;
        }
      }
    }
    return currentBaseBalance;
  }

  void _loadInitialData() async {
    // ✅ منع التنفيذ إذا كان الـ Widget غير موجود أو قيد التحديث
    if (!mounted || _isUpdating) return;
    
    _isUpdating = true;
    setState(() => _isLoading = true);
    try {
      final Box dailyBox = Hive.box('daily_transactions_box');

      // ✅ التحقق من وجود بيانات محلية للشركة الحالية (أي حركة)
      bool hasLocalData = dailyBox.values.any((tx) =>
          tx is Map && tx['company_code'] == widget.companyCode);

      // ✅ المزامنة التزايدية فقط (بدون تحميل كامل)
      final prefs = await SharedPreferences.getInstance();
      final lastSyncKey = '${ApiConstants.LAST_SYNC_DAILY}${widget.companyCode}';
      final lastSyncTime = prefs.getString(lastSyncKey);

      if (!hasLocalData || lastSyncTime == null) {
        // جهاز جديد أو لا توجد بيانات → تحميل كل البيانات (مرة واحدة فقط)
        print("📥 الذاكرة المحلية فارغة أو لا يوجد وقت مزامنة، جاري تحميل كل البيانات...");
        // await _dailyService.syncAllTransactions(widget.companyCode);
        // حفظ وقت المزامنة
        await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
        print("✅ تم تحميل كل البيانات وتخزينها محلياً");
      } else {
        // جهاز موجود → مزامنة تزايدية فقط
        print("📡 جاري جلب التحديثات التزايدية منذ: $lastSyncTime");
        // await _dailyService.syncChangesFromServer(widget.companyCode, lastSyncTime);
        // تحديث وقت المزامنة
        await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
        print("✅ تم تحديث البيانات من آخر مزامنة");
      }

      // الآن نستكمل حساب السيريال الأقصى (بعد التأكد من وجود البيانات)
      int maxSerial = 0;
      for (var item in dailyBox.values) {
        if (item is Map && item['company_code'] == widget.companyCode) {
          // فلترة حسب كود الفرع إذا كان محدداً وليس "all"
          if (widget.selectedBranchCode != null && widget.selectedBranchCode != "all") {
            if (item['branch_code']?.toString() != widget.selectedBranchCode) continue;
          }
          int currentSerial = int.tryParse(item['serial']?.toString() ?? '0') ?? 0;
          if (currentSerial > maxSerial) maxSerial = currentSerial;
        }
      }
      int nextSerial = maxSerial + 1;

      // جلب الأرصدة للفرع الحالي (تمرير كود الفرع)
      final summary = await _dailyService.getDailySummaryLocal(
        widget.companyCode,
        branchCode: widget.selectedBranchCode ?? 'all'
      );
      // ✅ تخزين الأرصدة في Hive (سيؤدي إلى تحديث ValueListenableBuilder)
      await Hive.box('daily_transactions_box').put("${widget.companyCode}_balances", summary['balances']);

      final Box codingBox = Hive.box('coding_box');
      List<Map<String, dynamic>> safesList = [];
      List<Map<String, dynamic>> typesList = [];

      if (!codingBox.containsKey("${widget.companyCode}_safes") || !codingBox.containsKey("${widget.companyCode}_types")) {
        final safes = await _codingService.getCodingList(companyCode: widget.companyCode, category: "safes");
        final types = await _codingService.getCodingList(companyCode: widget.companyCode, category: "types");
        safesList = safes.map((e) => Map<String, dynamic>.from(e.toMap())).toList();
        typesList = types.map((e) => Map<String, dynamic>.from(e.toMap())).toList();
      } else {
        var localSafes = codingBox.get("${widget.companyCode}_safes");
        safesList = (localSafes as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        var localTypes = codingBox.get("${widget.companyCode}_types");
        typesList = (localTypes as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }

      // ✅ إضافة التصفية هنا (بعد جلب الأنواع)
      typesList = typesList.where((item) {
        final name = item['name']?.toString() ?? '';
        return !name.contains('دخول بضاعة') && !name.contains('دفعة');
      }).toList();

      if (!mounted) {
        _isUpdating = false;
        return;
      }
      setState(() {
        _treasuryBalances = Map<String, double>.from(summary['balances'] ?? {});
        _treasuries = safesList;
        _categories = typesList;
        if (widget.editItem == null) _currentSerial = nextSerial;
        if (widget.editItem == null && _selectedTreasury == null && _treasuries.isNotEmpty) {
          var defaultSafe = _treasuries.firstWhere((s) => s['code']?.toString() == "1", orElse: () => _treasuries.first);
          if (defaultSafe.containsKey('name')) _selectedTreasury = defaultSafe['name'];
        }
        _isLoading = false;
        _isUpdating = false;
      });
    } catch (e) {
      if (!mounted) {
        _isUpdating = false;
        return;
      }
      setState(() {
        _isLoading = false;
        _isUpdating = false;
      });
      print("خطأ في جلب البيانات الافتتاحية: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isEditMode = widget.editItem != null;
    double screenWidth = MediaQuery.of(context).size.width;
    bool isWebOrDesktop = screenWidth > 600;
    final Box dailyBox = Hive.box('daily_transactions_box');

    // ✅ التحقق من صلاحية المعاينة للإذن بالوصول للصفحة (اختياري)
    bool canView = PermissionsService().canViewTransactions;
    bool canAdd = PermissionsService().canAddTransaction;
    bool canEdit = PermissionsService().canEditTransaction;
    bool canImport = PermissionsService().canImportExcel;

    // إذا لم تكن هناك صلاحية لعرض أو إضافة أو تعديل، نمنع الدخول
    if (!canView && !canAdd && !canEdit) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: const Text("حركة الخزينة", style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.black, Colors.indigo.shade900, Colors.black],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Text(
              "ليس لديك صلاحية للوصول إلى حركة الخزينة",
              style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 16),
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isEditMode ? "تعديل حركة" : "تسجيل يومية",
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 15),
              ),
              Text(
                "إذن رقم: $_currentSerial",
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                "${widget.branchName ?? _getBranchName(widget.selectedBranchCode)}",
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          toolbarHeight: 70,
          actions: [
            // ✅ صلاحية استيراد من اكسل
            if (!isEditMode && canImport)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                child: Tooltip(
                  message: "استيراد من إكسيل",
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.upload_file, color: Colors.greenAccent, size: 22),
                      onPressed: canImport ? _importFromExcel : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: Container(
          height: double.infinity,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.black, Colors.indigo.shade900, Colors.black],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : Center(
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: isWebOrDesktop ? 650 : double.infinity,
                      ),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(
                          horizontal: isWebOrDesktop ? 25 : 15,
                          vertical: 10,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // ✅ شاشات الأرصدة (تظهر فقط إذا كانت الصلاحية موجودة)
                            if (PermissionsService().canViewBalances)
                              ValueListenableBuilder(
                                valueListenable: dailyBox.listenable(keys: ["${widget.companyCode}_balances"]),
                                builder: (context, Box box, child) {
                                  final rawBalances = box.get("${widget.companyCode}_balances");
                                  if (rawBalances is Map && rawBalances.isNotEmpty) {
                                    Map<String, double> safeBalances = {};
                                    rawBalances.forEach((key, value) {
                                      safeBalances[key.toString()] = double.tryParse(value.toString()) ?? 0.0;
                                    });
                                    // ✅ تحديث المتغير المحلي عند تغير الأرصدة
                                    _treasuryBalances = safeBalances;
                                  }
                                  return _buildDynamicBalancesGrid();
                                },
                              ),
                            const SizedBox(height: 12),
                            _buildInputForm(),
                            const SizedBox(height: 15),
                            _buildMainActions(),
                            const SizedBox(height: 8),
                            _buildSecondaryActions(),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildDynamicBalancesGrid() {
    if (_treasuries.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        double availableWidth = constraints.maxWidth;
        if (availableWidth <= 0) return const SizedBox.shrink();

        double screenWidth = MediaQuery.of(context).size.width;
        int columnsCount = screenWidth > 500 ? 3 : 2;
        double spacing = 10.0;

        // حساب عرض البطاقة بناءً على العرض المتاح والمسافات بينها
        double cardWidth = (availableWidth - (spacing * (columnsCount - 1))) / columnsCount;
        cardWidth = cardWidth.clamp(80.0, double.infinity); // لمنع القيم الصغيرة جداً

        return Wrap(
          spacing: spacing,
          runSpacing: 10,
          alignment: WrapAlignment.center, // 🎯 توسيط الصف الأخير
          children: _treasuries.map((treasury) {
            String treasuryName = treasury['name'] ?? "خزينة غير معرفة";
            double liveBalance = _getLiveBalanceForTreasury(treasuryName);

            return SizedBox(
              width: cardWidth,
              child: AspectRatio(
                aspectRatio: screenWidth > 500 ? 2.1 : 1.7, // نفس النسبة السابقة
                child: GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 4,
                          child: Center(
                            child: Text(
                              treasuryName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.bold,
                                height: 0.8,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Expanded(
                          flex: 5,
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                liveBalance.toStringAsFixed(2),
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'Cairo',
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildInputForm() {
    // ✅ صلاحية الإضافة تتحكم في تمكين/تعطيل الحقول
    bool canAdd = PermissionsService().canAddTransaction;
    bool isEdit = widget.editItem != null;
    bool enabled = isEdit ? PermissionsService().canEditTransaction : canAdd;

    return GlassCard(
      child: Column(
        children: [
          _buildTextField(_amountController, "المبلغ", Icons.attach_money, isNumber: true, enabled: enabled),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: _buildDropdown("الخزينة", _selectedTreasury, _treasuries,
                    (val) => setState(() => _selectedTreasury = val), enabled: enabled),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDropdown("التصنيف", _selectedCategory, _categories, (val) {
                  setState(() {
                    _selectedCategory = val;
                    if (val == "فيزا") {
                      var visaTreasury = _treasuries.firstWhere(
                        (t) => t['code']?.toString() == "2",
                        orElse: () => {}
                      );
                      if (visaTreasury.isNotEmpty && visaTreasury.containsKey('name')) {
                        _selectedTreasury = visaTreasury['name'];
                      }
                    } else {
                      var cashTreasury = _treasuries.firstWhere(
                        (t) => t['code']?.toString() == "1",
                        orElse: () => {}
                      );
                      if (cashTreasury.isNotEmpty && cashTreasury.containsKey('name')) {
                        _selectedTreasury = cashTreasury['name'];
                      }
                    }
                  });
                }, enabled: enabled),
              ),
            ],
          ),
          const SizedBox(height: 15),
          _buildTextField(_statementController, "البيان", Icons.description, enabled: enabled),
          const SizedBox(height: 15),
          _buildDatePicker(enabled: enabled),
        ],
      ),
    );
  }

  Widget _buildMainActions() {
    bool isEdit = widget.editItem != null;
    bool canAdd = PermissionsService().canAddTransaction;
    bool canEdit = PermissionsService().canEditTransaction;
    bool isEnabled = isEdit ? canEdit : canAdd;

    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isEdit ? Colors.orange.withOpacity(0.3) : Colors.white.withOpacity(0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          side: BorderSide(color: isEdit ? Colors.orangeAccent : Colors.white24),
        ),
        onPressed: isEnabled ? _handleSave : null,
        child: Text(
          isEdit ? "تعديل الإذن" : "حفظ",
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
        ),
      ),
    );
  }

  void _handleSave() async {
    // التحقق من الصلاحية مرة أخرى
    bool isEdit = widget.editItem != null;
    if (isEdit && !PermissionsService().canEditTransaction) {
      _showSnackBar("ليس لديك صلاحية للتعديل", Colors.orange);
      return;
    }
    if (!isEdit && !PermissionsService().canAddTransaction) {
      _showSnackBar("ليس لديك صلاحية للإضافة", Colors.orange);
      return;
    }

    if (_amountController.text.isEmpty || _selectedTreasury == null || _selectedCategory == null) {
      _showSnackBar("برجاء إكمال البيانات", Colors.orange);
      return;
    }
    final double? parsedAmount = double.tryParse(_amountController.text.trim());
    if (parsedAmount == null || parsedAmount <= 0) {
      _showSnackBar("برجاء إدخال مبلغ صحيح أكبر من الصفر", Colors.orange);
      return;
    }

    setState(() => _isLoading = true);
    try {
      var matchingCategory = _categories.firstWhere((c) => c['name'] == _selectedCategory, orElse: () => {});
      String currentType = matchingCategory.isNotEmpty ? (matchingCategory['type'] ?? "وارد") : "وارد";
      int serialToSend = widget.editItem != null ? widget.editItem!['serial'] : 0;

      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: serialToSend,
        treasury: _selectedTreasury!,
        amount: parsedAmount,
        statement: _statementController.text,
        category: _selectedCategory!,
        date: _dateController.text,
        type: currentType,
        branchCode: widget.selectedBranchCode ?? 'all',    // تمرير كود الفرع (وليس الاسم)
        employee: widget.userName ?? "غير معروف",
      );

      if (mounted) {
        if (widget.editItem != null) {
          Navigator.pop(context, true);
        } else {
          _showSnackBar("تم الحفظ بنجاح وتحديث الذاكرة المحلية والشبكية التراكمية", Colors.green);
          _amountController.clear();
          _statementController.clear();
          // ✅ إعادة تحميل البيانات لتحديث الأرصدة فوراً
          _loadInitialData();
        }
      }
    } catch (e) {
      if (mounted) _showSnackBar("خطأ: $e", Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildDropdown(String label, String? value, List<Map<String, dynamic>> items, Function(String?) onChanged, {bool enabled = true}) {
    return DropdownButtonFormField<String>(
      value: value,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 12),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
        contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
      ),
      items: items.map((item) {
        return DropdownMenuItem<String>(
          value: item['name']?.toString(),
          child: Text(item['name']?.toString() ?? "")
        );
      }).toList(),
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, IconData icon, {bool isNumber = false, bool enabled = true}) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: enabled ? Colors.white70 : Colors.white38),
        labelText: label,
        labelStyle: TextStyle(color: enabled ? Colors.white70 : Colors.white38, fontFamily: 'Cairo'),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.cyanAccent)),
        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 15),
      ),
    );
  }

  Widget _buildDatePicker({bool enabled = true}) {
    return TextField(
      controller: _dateController,
      readOnly: true,
      enabled: enabled,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.calendar_today, color: enabled ? Colors.white70 : Colors.white38),
        labelText: "التاريخ",
        labelStyle: TextStyle(color: enabled ? Colors.white70 : Colors.white38, fontFamily: 'Cairo'),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
      ),
      onTap: enabled ? _pickDate : null,
    );
  }

  Widget _buildSecondaryActions() {
    bool canView = PermissionsService().canViewTransactions;
    bool canAdd = PermissionsService().canAddTransaction;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ✅ صلاحية المعاينة
        if (canView)
          TextButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DailyHistoryPage(
                    companyCode: widget.companyCode,
                    userName: widget.userName,
                    selectedBranchCode: widget.selectedBranchCode,
                  ),
                ),
              ).then((value) {
                // ✅ عند العودة من صفحة التاريخ، نعيد تحميل البيانات والأرصدة
                _loadInitialData();
              });
            },
            icon: const Icon(Icons.history, color: Colors.cyanAccent),
            label: const Text("المعاينة", style: TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo')),
          ),
        
        const SizedBox(height: 10),

        // ✅ التحويل بين الخزائن (يتطلب صلاحية الإضافة)
        if (canAdd)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: const BorderSide(color: Colors.cyanAccent, width: 1.0),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              backgroundColor: Colors.white.withOpacity(0.05),
            ),
            icon: const Icon(Icons.sync_alt, color: Colors.cyanAccent, size: 20),
            label: const Text(
              "تحويل بين الخزائن",
              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => TreasuryTransferPage(
                    companyCode: widget.companyCode,
                    userName: widget.userName,
                    selectedBranchCode: widget.selectedBranchCode,
                  ),
                ),
              ).then((value) {
                // ✅ عند العودة من صفحة التحويل، نعيد تحميل البيانات والأرصدة
                _loadInitialData();
              });
            },
          ),
      ],
    );
  }

  Future<void> _pickDate() async {
    DateTime? p = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2101));
    if (p != null) setState(() => _dateController.text = DateFormat('yyyy-MM-dd').format(p));
  }

  void _importFromExcel() async {
    // التحقق من صلاحية الاستيراد
    if (!PermissionsService().canImportExcel) {
      _showSnackBar("ليس لديك صلاحية للاستيراد", Colors.orange);
      return;
    }

    bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("تنبيه قبل الاستيراد", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold), textAlign: TextAlign.right),
        content: const Text(
          "يرجى التأكد من احتواء ملف الإكسيل على الأعمدة التالية في الصف الأول بأي ترتيب:\n"
          " 🌟 ( المبلغ  -  البيان  -  التصنيف  -  التاريخ )\n"
          " 💡 يمكن إضافة عمود اختياري باسم (الخزينة) لتحديد الخزينة لكل حركة.\n\n"
          "💡 النظام ذكي بما يكفي لتجاهل أي أعمدة إضافية أخرى بالملف والتعرف التلقائي على الحقول المطلوبة.",
          style: TextStyle(fontFamily: 'Cairo', fontSize: 14),
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("إلغاء", style: TextStyle(fontFamily: 'Cairo', color: Colors.red))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade900),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("موافق واختيار الملف", style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );
    if (result != null) {
      setState(() => _isLoading = true);
      try {
        var bytes = result.files.single.bytes;
        if (bytes == null && result.files.single.path != null) {
          bytes = File(result.files.single.path!).readAsBytesSync();
        }
        if (bytes == null) throw "تعذر قراءة بيانات الملف";
        var excel = excel_lib.Excel.decodeBytes(bytes);

        // تعريف أسماء الخزائن الافتراضية بناءً على الكود
        String cashTreasuryName = "الخزينة الرئيسية";
        String visaTreasuryName = "فيزا";
        var cashTreasuryObj = _treasuries.firstWhere((t) => t['code']?.toString() == "1", orElse: () => {});
        if (cashTreasuryObj.isNotEmpty && cashTreasuryObj.containsKey('name')) cashTreasuryName = cashTreasuryObj['name'];
        var visaTreasuryObj = _treasuries.firstWhere((t) => t['code']?.toString() == "2", orElse: () => {});
        if (visaTreasuryObj.isNotEmpty && visaTreasuryObj.containsKey('name')) visaTreasuryName = visaTreasuryObj['name'];

        // قائمة بأسماء الخزائن المتاحة (للتأكد من صحة المدخلات)
        List<String> treasuryNames = _treasuries.map((t) => t['name']?.toString() ?? "").where((n) => n.isNotEmpty).toList();

        for (var table in excel.tables.keys) {
          var rows = excel.tables[table]!.rows;
          if (rows.isEmpty) continue;
          // فهرسة الأعمدة المطلوبة
          int amountIdx = -1, statementIdx = -1, categoryIdx = -1, dateIdx = -1, treasuryIdx = -1;
          var headerRow = rows[0];
          for (int col = 0; col < headerRow.length; col++) {
            String headerVal = headerRow[col]?.value?.toString().trim() ?? "";
            if (headerVal == "المبلغ") amountIdx = col;
            if (headerVal == "البيان") statementIdx = col;
            if (headerVal == "التصنيف") categoryIdx = col;
            if (headerVal == "التاريخ") dateIdx = col;
            if (headerVal == "الخزينة" || headerVal == "خزينة") treasuryIdx = col; // ✅ دعم عمود الخزينة
          }
          // التأكد من وجود الأعمدة الأساسية
          if (amountIdx == -1 || statementIdx == -1 || categoryIdx == -1 || dateIdx == -1) {
            throw "الملف لا يحتوي على الأعمدة الأساسية المطلوبة: (المبلغ، البيان، التصنيف، التاريخ). يرجى مراجعة عناوين الأعمدة بالصف الأول.";
          }

          // معالجة الصفوف
          for (int i = 1; i < rows.length; i++) {
            var row = rows[i];
            if (row.isEmpty || amountIdx >= row.length || row[amountIdx] == null || row[amountIdx]?.value == null) continue;
            double amount = double.tryParse(row[amountIdx]!.value.toString().trim()) ?? 0.0;
            if (amount == 0.0) continue;
            String statement = (statementIdx < row.length && row[statementIdx] != null && row[statementIdx]?.value != null)
                ? row[statementIdx]!.value.toString().trim()
                : "";
            String categoryStr = (categoryIdx < row.length && row[categoryIdx] != null && row[categoryIdx]?.value != null)
                ? row[categoryIdx]!.value.toString().trim()
                : "عام";
            String rawDate = (dateIdx < row.length && row[dateIdx] != null && row[dateIdx]?.value != null)
                ? row[dateIdx]!.value.toString().trim()
                : DateFormat('yyyy-MM-dd').format(DateTime.now());
            String formattedDate = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;

            // ✅ تحديد الخزينة: إما من العمود المخصص أو تلقائياً حسب التصنيف
            String targetTreasury;
            if (treasuryIdx != -1 && treasuryIdx < row.length && row[treasuryIdx] != null && row[treasuryIdx]?.value != null) {
              String treasuryFromExcel = row[treasuryIdx]!.value.toString().trim();
              // إذا كانت القيمة موجودة في قائمة الخزائن، استخدمها، وإلا استخدم القيمة الافتراضية بناءً على التصنيف
              if (treasuryNames.contains(treasuryFromExcel)) {
                targetTreasury = treasuryFromExcel;
              } else {
                // إذا لم تكن الخزينة معروفة، نستخدم المنطق التلقائي القديم مع تحذير (يمكن إضافة تنبيه)
                // لكننا سنكتفي باستخدام الافتراضي مع تجاهل القيمة غير المعروفة
                targetTreasury = (categoryStr == "فيزا") ? visaTreasuryName : cashTreasuryName;
              }
            } else {
              // الطريقة القديمة: حسب التصنيف
              targetTreasury = (categoryStr == "فيزا") ? visaTreasuryName : cashTreasuryName;
            }

            // مطابقة التصنيف لتحديد النوع (وارد/صادر)
            var match = _categories.firstWhere((c) => c['name']?.toString().trim() == categoryStr, orElse: () => {});
            String calculatedType = match.isNotEmpty ? (match['type'] ?? "وارد") : "وارد";

            // حفظ الحركة
            await _dailyService.saveTransaction(
              companyCode: widget.companyCode,
              serial: 0,
              treasury: targetTreasury,
              amount: amount,
              statement: statement,
              category: categoryStr,
              date: formattedDate,
              type: calculatedType,
              branchCode: widget.selectedBranchCode ?? 'all',
              employee: widget.userName ?? "غير معروف",
            );
          }
        }
        _showSnackBar("تم الاستيراد المباشر والمزامنة بنجاح محلياً وسحابياً", Colors.green);
        // ✅ إعادة تحميل البيانات والأرصدة بعد الاستيراد
        _loadInitialData();
      } catch (e) {
        _showSnackBar("خطأ في الاستيراد: $e", Colors.red);
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: c)
  );
}