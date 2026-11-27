// frontend/lib/views/dashboard/daily_page.dart
import '../../services/cache_partitions.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/journal_save_intent.dart';
import '../../services/journal_save_client.dart';
import '../../services/journal_import_batch.dart';
import '../../services/treasury_transfer_service.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import '../../services/coding_service.dart';
import 'daily_history_page.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/permissions_service.dart'; // ✅ استيراد خدمة الصلاحيات
import '../../services/supplier_settlement_service.dart';

// صفحة إدخال اليومية
class DailyPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode; // كود الفرع (يُستخدم للفلترة والحفظ)
  final String? branchName; // اسم الفرع (للعرض فقط)
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

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<DailyPage> createState() => _DailyPageState();
}

// حالة الويدجت DailyPage: تدير بيانات الشاشة وتفاعلاتها
class _DailyPageState extends State<DailyPage> with WidgetsBindingObserver {
  // ✅ إضافة WidgetsBindingObserver للاستماع لعودة التطبيق
  final DailyService _dailyService = DailyService();
  final CodingService _codingService = CodingService();
  final SupplierSettlementService _settlementService =
      SupplierSettlementService();

  final _amountController = TextEditingController();

// يستجيب لتغيّر المبلغ
  void _onAmountChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  final _statementController = TextEditingController();
  final _dateController = TextEditingController();

  StreamSubscription<BoxEvent>? _treasuryEffectsSubscription;
  bool _isLoading = false;
  bool _isUpdating = false; // ✅ متغير علم لمنع التحديث المتكرر

  bool _saveBusy = false;
  bool _restoringJournal = true;
  bool _journalRestoreError = false;
  final String? _formOwnerUid = FirebaseAuth.instance.currentUser?.uid;
  late final JournalIntentStore _journalIntentStore =
      JournalIntentStore(tabId: '${JournalTabScope.current}:manual');
  JournalSaveIntent? _journalIntent;
  late final String? _editBaseVersion =
      widget.editItem?['updated_at']?.toString();
  StreamSubscription<User?>? _ownerSubscription;

  // يحدد هل النموذج يخص المستخدم الحالي
  bool get _sameFormOwner =>
      _formOwnerUid != null &&
      FirebaseAuth.instance.currentUser?.uid == _formOwnerUid;

  // يعيد رقم التسلسل المقصود
  int get _intentSerial =>
      int.tryParse(widget.editItem?['serial']?.toString() ?? '') ?? 0;

  // يعيد الفرع المقصود
  String get _intentBranch => widget.selectedBranchCode ?? 'all';

  Map<String, double> _treasuryBalances = {};

  int _currentSerial = 1;
  String? _selectedTreasury;
  String? _selectedCategory;
  String? _selectedSupplierForGoods;
  bool _linkGoodsToSettlement = false;
  List<String> _supplierNames = [];

  List<Map<String, dynamic>> _treasuries = [];
  List<Map<String, dynamic>> _categories = [];

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    try {
      _ownerSubscription = FirebaseAuth.instance.authStateChanges().listen((_) {
        if (mounted && !_sameFormOwner) setState(() {});
      });
    } catch (_) {}
    WidgetsBinding.instance.addObserver(this); // ✅ إضافة المراقب
    _amountController.addListener(() => setState(() {}));

    _loadInitialData();
    if (CachePartitions.isBoxOpen(TreasuryTransferService.effectsBox)) {
      _treasuryEffectsSubscription =
          CachePartitions.box(TreasuryTransferService.effectsBox)
              .watch()
              .listen((_) {
        if (mounted) unawaited(_refreshBalancesOnly());
      });
    }

    if (widget.editItem != null) {
      _amountController.text = widget.editItem!['amount']?.toString() ?? '';
      _statementController.text = widget.editItem!['statement'] ?? "";
      if (widget.editItem!['date'] != null) {
        String rawDate = widget.editItem!['date'].toString();
        _dateController.text =
            rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
      } else {
        _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
      }
      _currentSerial = widget.editItem!['serial'] ?? 1;
      _selectedTreasury = widget.editItem!['treasury'];
      _selectedCategory = widget.editItem!['category'];
      _linkGoodsToSettlement =
          widget.editItem!['link_id']?.toString().isNotEmpty == true;
      _selectedSupplierForGoods = widget.editItem!['supplier_name']?.toString();
    } else {
      _amountController.clear();
      _statementController.clear();
      _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    }
  }

  // يحدّث الأرصدة فقط
  Future<void> _refreshBalancesOnly() async {
    return CachePartitions.run(() async {
      try {
        final summary = await _dailyService.getDailySummaryLocal(
          widget.companyCode,
          branchCode: widget.selectedBranchCode ?? 'all',
        );

        if (!mounted) return;

        setState(() {
          _treasuryBalances =
              Map<String, double>.from(summary['balances'] ?? {});
        });
      } catch (e) {
        print("❌ خطأ في تحديث الأرصدة: $e");
      }
    });
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    _treasuryEffectsSubscription?.cancel();
    _ownerSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _amountController.removeListener(_onAmountChanged);
    _amountController.dispose();
    _statementController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  // ✅ عند عودة التطبيق إلى المقدمة، نحدث الأرصدة
  // يستجيب لتغيّر حالة التطبيق
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshBalancesOnly();
    }
  }

  // دالة مساعدة لعرض اسم الفرع من كوده (يمكن استدعاءها من أي مكان)
  // يعيد اسم الفرع من الكود
  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    final Box codingBox = CachePartitions.box('coding_box');
    final rawData =
        codingBox.get("${widget.companyCode}_branches", defaultValue: []);
    for (var item in rawData) {
      if (item['code']?.toString() == code)
        return item['name']?.toString() ?? "فرع غير معروف";
    }
    return "فرع غير معروف";
  }

  // يحسب الرصيد الحي للخزينة
  double _getLiveBalanceForTreasury(String treasuryName) {
    double currentBaseBalance = _treasuryBalances[treasuryName] ?? 0.0;

    if (_selectedTreasury == treasuryName && _selectedCategory != null) {
      double enteredAmount = double.tryParse(_amountController.text) ?? 0.0;
      if (widget.editItem != null &&
          widget.editItem!['treasury'] == treasuryName) {
        double originalAmount =
            double.tryParse(widget.editItem!['amount'].toString()) ?? 0.0;
        String originalType = widget.editItem!['type'] ?? "وارد";
        if (originalType == "وارد") {
          currentBaseBalance -= originalAmount;
        } else if (originalType == "صادر") {
          currentBaseBalance += originalAmount;
        }
      }
      var matchingCategory = _categories
          .firstWhere((c) => c['name'] == _selectedCategory, orElse: () => {});
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

  // يستعيد مسودة اليومية
  Future<void> _restoreJournal() async {
    return CachePartitions.run(() async {
      if (!_restoringJournal) return;
      try {
        if (!_sameFormOwner) throw StateError('Account changed');
        final pending = await _journalIntentStore.load(
            ownerUid: _formOwnerUid!,
            companyCode: widget.companyCode,
            branchCode: _intentBranch,
            serial: _intentSerial);
        if (!mounted || !_sameFormOwner) return;
        _journalIntent = pending;
        final values = pending?.payload;
        if (values != null) {
          _amountController.text = values['amount'].toString();
          _statementController.text = values['statement']?.toString() ?? '';
          _dateController.text = values['date']?.toString() ?? '';
          _selectedTreasury = values['treasury']?.toString();
          _selectedCategory = values['category']?.toString();
          _selectedSupplierForGoods = values['supplier_name']?.toString();
          _linkGoodsToSettlement = values['add_to_settlement'] == true;
        }
      } catch (_) {
        _journalRestoreError = true;
      } finally {
        _restoringJournal = false;
      }
    });
  }

  // يحمّل البيانات الأولية
  void _loadInitialData() async {
    return CachePartitions.run(() async {
      // ✅ منع التنفيذ إذا كان الـ Widget غير موجود أو قيد التحديث
      if (!mounted || _isUpdating) return;

      _isUpdating = true;
      setState(() => _isLoading = true);
      try {
        await _restoreJournal();
        if (!mounted || !_sameFormOwner) return;
        final Box dailyBox = CachePartitions.box('daily_transactions_box');

        // الآن نستكمل حساب السيريال الأقصى (بعد التأكد من وجود البيانات)
        int maxSerial = 0;
        for (var item in dailyBox.values) {
          if (item is Map && item['company_code'] == widget.companyCode) {
            // فلترة حسب كود الفرع إذا كان محدداً وليس "all"
            if (widget.selectedBranchCode != null &&
                widget.selectedBranchCode != "all") {
              if (item['branch_code']?.toString() != widget.selectedBranchCode)
                continue;
            }
            int currentSerial =
                int.tryParse(item['serial']?.toString() ?? '0') ?? 0;
            if (currentSerial > maxSerial) maxSerial = currentSerial;
          }
        }
        int nextSerial = maxSerial + 1;

        // جلب الأرصدة للفرع الحالي (تمرير كود الفرع)
        final Box codingBox = CachePartitions.box('coding_box');
        final rawSuppliers = codingBox.get('${widget.companyCode}_suppliers');
        if (rawSuppliers is List) {
          _supplierNames = rawSuppliers
              .whereType<Map>()
              .map((e) => e['name']?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .toList();
        }
        if (_supplierNames.isEmpty) {
          try {
            final suppliers = await _codingService.getCodingList(
              companyCode: widget.companyCode,
              category: 'suppliers',
            );
            _supplierNames = suppliers
                .map((e) => e.name)
                .where((name) => name.trim().isNotEmpty)
                .toList();
          } catch (_) {}
        }
        List<Map<String, dynamic>> safesList = [];
        List<Map<String, dynamic>> typesList = [];

        if (!codingBox.containsKey("${widget.companyCode}_safes") ||
            !codingBox.containsKey("${widget.companyCode}_types")) {
          final safes = await _codingService.getCodingList(
              companyCode: widget.companyCode, category: "safes");
          final types = await _codingService.getCodingList(
              companyCode: widget.companyCode, category: "types");
          safesList =
              safes.map((e) => Map<String, dynamic>.from(e.toMap())).toList();
          typesList =
              types.map((e) => Map<String, dynamic>.from(e.toMap())).toList();
        } else {
          var localSafes = codingBox.get("${widget.companyCode}_safes");
          safesList = (localSafes as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          var localTypes = codingBox.get("${widget.companyCode}_types");
          typesList = (localTypes as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }

        // ✅ إضافة التصفية هنا (بعد جلب الأنواع)
        typesList = typesList.where((item) {
          final name = item['name']?.toString() ?? '';
          return !name.contains('دخول بضاعة') && !name.contains('دفعة');
        }).toList();

        if (_journalIntent != null) {
          for (final pair in [
            (safesList, _selectedTreasury),
            (typesList, _selectedCategory)
          ]) {
            if (pair.$2 != null &&
                !pair.$1.any((item) => item['name'] == pair.$2)) {
              pair.$1.add({'name': pair.$2, 'code': 'pending'});
            }
          }
        }
        final summary = await _dailyService.getDailySummaryLocal(
            widget.companyCode,
            branchCode: widget.selectedBranchCode ?? 'all');
        if (!mounted) {
          _isUpdating = false;
          return;
        }
        setState(() {
          _treasuryBalances =
              Map<String, double>.from(summary['balances'] ?? {});
          _treasuries = safesList;
          _categories = typesList;
          if (widget.editItem == null) _currentSerial = nextSerial;
          if (widget.editItem == null &&
              _selectedTreasury == null &&
              _treasuries.isNotEmpty) {
            var defaultSafe = _treasuries.firstWhere(
                (s) => s['code']?.toString() == "1",
                orElse: () => _treasuries.first);
            if (defaultSafe.containsKey('name'))
              _selectedTreasury = defaultSafe['name'];
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
    });
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    if (!_sameFormOwner) {
      return const Scaffold(
          body: Center(
              child:
                  Text('تغيّر الحساب. افتح حركة الخزينة من الحساب الحالي.')));
    }
    bool isEditMode = widget.editItem != null;
    double screenWidth = MediaQuery.of(context).size.width;
    bool isWebOrDesktop = screenWidth > 600;
    final Box dailyBox = CachePartitions.box('daily_transactions_box');

    // ✅ التحقق من صلاحية المعاينة للإذن بالوصول للصفحة (اختياري)
    bool canAdd = PermissionsService().canAddTransaction;
    bool canView = PermissionsService().canViewTransactions;
    bool canEdit = PermissionsService().canEditTransaction;
    bool canImport = PermissionsService().canImportExcel;

    // إذا لم تكن هناك صلاحية لعرض أو إضافة أو تعديل، نمنع الدخول
    if (!canView && !canAdd && !canEdit) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text("حركة الخزينة",
              style: TextStyle(
                  fontFamily: 'Cairo', color: AppTheme.textMainFor(context))),
          backgroundColor: AppTheme.appBarBg,
          elevation: 0,
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: AppTheme.dashGradientMain(context),
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: Text(
              "ليس لديك صلاحية للوصول إلى حركة الخزينة",
              style: TextStyle(
                  color: AppTheme.textSoftFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 16),
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        return CachePartitions.run(() async {
          if (didPop) return;
          if (context.mounted) Navigator.pop(context);
        });
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
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  color: AppTheme.accentFor(context),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                "${widget.branchName ?? _getBranchName(widget.selectedBranchCode)}",
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: AppTheme.textSoftFor(context),
                ),
              ),
            ],
          ),
          backgroundColor: AppTheme.appBarBg,
          elevation: 0,
          centerTitle: true,
          toolbarHeight: 70,
          actions: [
            // ✅ صلاحية استيراد من اكسل
            if (!isEditMode && canImport)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                child: Tooltip(
                  message: "استيراد من إكسيل",
                  child: Container(
                    decoration: BoxDecoration(
                      color: GlassStyle.fill15For(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: GlassStyle.successBorder40For(context)),
                    ),
                    child: IconButton(
                      icon: Icon(Icons.upload_file,
                          color: AppTheme.successFor(context), size: 22),
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
              colors: AppTheme.dashGradientMain(context),
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: _isLoading
                ? Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.textMainFor(context)))
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
                              Builder(
                                builder: (context) {
                                  final String balanceKey =
                                      "${widget.companyCode}_balances_${widget.selectedBranchCode ?? 'all'}";

                                  return ValueListenableBuilder(
                                    valueListenable: dailyBox.listenable(
                                      keys: [balanceKey],
                                    ),
                                    builder: (context, Box box, child) {
                                      final rawBalances = box.get(balanceKey);

                                      if (rawBalances is Map &&
                                          rawBalances.isNotEmpty) {
                                        final Map<String, double> safeBalances =
                                            {};

                                        rawBalances.forEach((key, value) {
                                          safeBalances[key.toString()] =
                                              double.tryParse(
                                                      value.toString()) ??
                                                  0.0;
                                        });

                                        // ✅ تحديث الرصيد المحلي للفرع الحالي فقط
                                        _treasuryBalances = safeBalances;
                                      }

                                      return _buildDynamicBalancesGrid();
                                    },
                                  );
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

  // يبني شبكة أرصدة الخزائن
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
        double cardWidth =
            (availableWidth - (spacing * (columnsCount - 1))) / columnsCount;
        cardWidth =
            cardWidth.clamp(80.0, double.infinity); // لمنع القيم الصغيرة جداً

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
                aspectRatio:
                    screenWidth > 500 ? 2.1 : 1.7, // نفس النسبة السابقة
                child: GlassCard(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 4,
                          child: Center(
                            child: Text(
                              treasuryName,
                              style: TextStyle(
                                color: AppTheme.textMainFor(context),
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
                                style: TextStyle(
                                  color: AppTheme.successFor(context),
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

  // يبني نموذج الإدخال
  Widget _buildInputForm() {
    // ✅ صلاحية الإضافة تتحكم في تمكين/تعطيل الحقول
    bool canAdd = PermissionsService().canAddTransaction;
    bool isEdit = widget.editItem != null;
    bool enabled =
        (isEdit ? PermissionsService().canEditTransaction : canAdd) &&
            !_saveBusy &&
            !_restoringJournal &&
            !_journalRestoreError &&
            _journalIntent?.submitted != true;

    return GlassCard(
      child: Column(
        children: [
          _buildTextField(_amountController, "المبلغ", Icons.attach_money,
              isNumber: true, enabled: enabled),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: _buildDropdown("الخزينة", _selectedTreasury, _treasuries,
                    (val) => setState(() => _selectedTreasury = val),
                    enabled: enabled),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDropdown("التصنيف", _selectedCategory, _categories,
                    (val) {
                  setState(() {
                    _selectedCategory = val;
                    if (val == "فيزا") {
                      var visaTreasury = _treasuries.firstWhere(
                          (t) => t['code']?.toString() == "2",
                          orElse: () => {});
                      if (visaTreasury.isNotEmpty &&
                          visaTreasury.containsKey('name')) {
                        _selectedTreasury = visaTreasury['name'];
                      }
                    } else {
                      var cashTreasury = _treasuries.firstWhere(
                          (t) => t['code']?.toString() == "1",
                          orElse: () => {});
                      if (cashTreasury.isNotEmpty &&
                          cashTreasury.containsKey('name')) {
                        _selectedTreasury = cashTreasury['name'];
                      }
                    }
                  });
                }, enabled: enabled),
              ),
            ],
          ),
          const SizedBox(height: 15),
          if (_selectedCategory?.trim() == 'بضاعة') ...[
            Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'إضافة إذن تلقائي في تسويات الموردين',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                  ),
                ),
                value: _linkGoodsToSettlement,
                onChanged: enabled
                    ? (v) => setState(() => _linkGoodsToSettlement = v)
                    : null,
              ),
            ),
            if (_linkGoodsToSettlement)
              DropdownButtonFormField<String>(
                initialValue: _supplierNames.contains(_selectedSupplierForGoods)
                    ? _selectedSupplierForGoods
                    : null,
                decoration: const InputDecoration(labelText: 'المورد'),
                items: _supplierNames
                    .map((name) =>
                        DropdownMenuItem(value: name, child: Text(name)))
                    .toList(),
                onChanged: enabled
                    ? (v) => setState(() => _selectedSupplierForGoods = v)
                    : null,
              ),
            const SizedBox(height: 15),
          ],
          _buildTextField(_statementController, "البيان", Icons.description,
              enabled: enabled),
          const SizedBox(height: 15),
          _buildDatePicker(enabled: enabled),
        ],
      ),
    );
  }

  // يبني الأزرار الرئيسية
  Widget _buildMainActions() {
    bool isEdit = widget.editItem != null;
    bool canAdd = PermissionsService().canAddTransaction;
    bool canEdit = PermissionsService().canEditTransaction;
    bool isEnabled = (isEdit ? canEdit : canAdd) &&
        !_saveBusy &&
        !_restoringJournal &&
        !_journalRestoreError;

    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isEdit
              ? GlassStyle.warningOrangeFill30For(context)
              : GlassStyle.fill20For(context),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          side: BorderSide(
              color: isEdit
                  ? AppTheme.warningOrangeSoftFor(context)
                  : GlassStyle.line24For(context)),
        ),
        onPressed: isEnabled ? _handleSave : null,
        child: Text(
          _journalRestoreError
              ? 'تعذر استعادة الحفظ السابق'
              : _journalIntent?.submitted == true
                  ? 'تأكيد الحفظ السابق'
                  : isEdit
                      ? "تعديل الإذن"
                      : "حفظ",
          style: TextStyle(
              color: _journalIntent?.submitted == true || _journalRestoreError
                  ? AppTheme.textMainFor(context)
                  : Theme.of(context).colorScheme.onPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              fontFamily: 'Cairo'),
        ),
      ),
    );
  }

  // يتحقق من البيانات ويحفظها
  void _handleSave() async {
    return CachePartitions.run(() async {
      if (_saveBusy ||
          _isLoading ||
          _restoringJournal ||
          _journalRestoreError ||
          !_sameFormOwner) return;
      final isEdit = widget.editItem != null;
      if (isEdit && !PermissionsService().canEditTransaction ||
          !isEdit && !PermissionsService().canAddTransaction) {
        _showSnackBar(
            'ليس لديك صلاحية للحفظ', AppTheme.warningOrangeFor(context));
        return;
      }

      final retrying = _journalIntent?.submitted == true;
      double? parsedAmount;
      if (!retrying) {
        if (_amountController.text.isEmpty ||
            _selectedTreasury == null ||
            _selectedCategory == null) {
          _showSnackBar(
              'برجاء إكمال البيانات', AppTheme.warningOrangeFor(context));
          return;
        }
        parsedAmount = double.tryParse(_amountController.text.trim());
        if (parsedAmount == null ||
            !parsedAmount.isFinite ||
            parsedAmount <= 0) {
          _showSnackBar('برجاء إدخال مبلغ صحيح أكبر من الصفر',
              AppTheme.warningOrangeFor(context));
          return;
        }
        if (_selectedCategory?.trim() == 'بضاعة' &&
            _linkGoodsToSettlement &&
            (_selectedSupplierForGoods == null ||
                !_supplierNames.contains(_selectedSupplierForGoods))) {
          _showSnackBar('اختر المورد لربط الإذن بالتسويات',
              AppTheme.warningOrangeFor(context));
          return;
        }
      }
      setState(() {
        _saveBusy = true;
        _isLoading = true;
      });
      try {
        final intent = _journalIntent ??= JournalSaveIntent(
            ownerUid: _formOwnerUid!,
            companyCode: widget.companyCode,
            branchCode: _intentBranch,
            serial: _intentSerial);
        final Map<String, dynamic> result;
        if (retrying) {
          result = await _dailyService.saveCapturedTransaction(intent,
              store: _journalIntentStore);
        } else {
          final matchingCategory = _categories.firstWhere(
              (c) => c['name'] == _selectedCategory,
              orElse: () => {});
          final currentType = matchingCategory.isNotEmpty
              ? (matchingCategory['type'] ?? 'وارد')
              : 'وارد';
          result = await _dailyService.saveTransaction(
            companyCode: widget.companyCode,
            serial: _intentSerial,
            baseUpdatedAt: _editBaseVersion,
            treasury: _selectedTreasury!,
            amount: parsedAmount!,
            statement: _statementController.text,
            category: _selectedCategory!,
            date: _dateController.text,
            type: currentType,
            branchCode: _intentBranch,
            employee: widget.userName ?? 'غير معروف',
            linkId: widget.editItem?['link_id']?.toString() ??
                (_linkGoodsToSettlement
                    ? _settlementService.newLinkId()
                    : null),
            supplierName:
                _selectedCategory?.trim() == 'بضاعة' && _linkGoodsToSettlement
                    ? _selectedSupplierForGoods
                    : null,
            addToSettlement:
                _selectedCategory?.trim() == 'بضاعة' && _linkGoodsToSettlement,
            unlinkSettlement:
                widget.editItem?['link_id']?.toString().isNotEmpty == true &&
                    !(_selectedCategory?.trim() == 'بضاعة' &&
                        _linkGoodsToSettlement),
            intent: intent,
            intentStore: _journalIntentStore,
          );
        }
        if (!mounted || !_sameFormOwner || result['owner_changed'] == true)
          return;

        if (result['intent_pending'] == true) {
          _showSnackBar(
              'الحفظ مؤكد في الخادم. اضغط تأكيد الحفظ لإكمال التحديث المحلي.',
              AppTheme.warningOrangeFor(context));
          return;
        }
        _journalIntent = null;
        if (isEdit) {
          Navigator.pop(context, true);
        } else {
          final unavailable = result['available'] == false;
          _showSnackBar(
              unavailable
                  ? 'تأكد الحفظ السابق، لكن الإذن لم يعد متاحًا. راجع السجل.'
                  : result['refresh_pending'] == true
                      ? 'تم حفظ الإذن في الخادم. تحديث النسخة المحلية لم يكتمل بعد.'
                      : 'تم الحفظ بنجاح',
              unavailable || result['refresh_pending'] == true
                  ? AppTheme.warningOrangeFor(context)
                  : AppTheme.successStrongFor(context));
          _amountController.clear();
          _statementController.clear();

          await _refreshBalancesOnly();
        }
      } catch (error) {
        if (error is JournalSaveFailure && error.canReplace)
          _journalIntent = null;
        if (mounted && _sameFormOwner)
          _showSnackBar('خطأ: $error', AppTheme.dangerStrongFor(context));
      } finally {
        if (mounted)
          setState(() {
            _saveBusy = false;
            _isLoading = false;
          });
      }
    });
  }

  // يبني قائمة منسدلة
  Widget _buildDropdown(String label, String? value,
      List<Map<String, dynamic>> items, Function(String?) onChanged,
      {bool enabled = true}) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: AppTheme.dropdownBackground(context),
      style: TextStyle(
          color: AppTheme.textMainFor(context),
          fontSize: 13,
          fontFamily: 'Cairo'),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
            color: AppTheme.textSoftFor(context),
            fontFamily: 'Cairo',
            fontSize: 12),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: GlassStyle.line10For(context))),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
      ),
      items: items.map((item) {
        return DropdownMenuItem<String>(
            value: item['name']?.toString(),
            child: Text(item['name']?.toString() ?? ""));
      }).toList(),
      onChanged: enabled ? onChanged : null,
    );
  }

  // يبني حقل إدخال نصي
  Widget _buildTextField(
      TextEditingController ctrl, String label, IconData icon,
      {bool isNumber = false, bool enabled = true}) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      style: TextStyle(color: AppTheme.textMainFor(context)),
      decoration: InputDecoration(
        prefixIcon: Icon(icon,
            color: enabled
                ? AppTheme.textSoftFor(context)
                : AppTheme.textFaintFor(context)),
        labelText: label,
        labelStyle: TextStyle(
            color: enabled
                ? AppTheme.textSoftFor(context)
                : AppTheme.textFaintFor(context),
            fontFamily: 'Cairo'),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: GlassStyle.line10For(context))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppTheme.accentFor(context))),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 18, horizontal: 15),
      ),
    );
  }

  // يبني حقل التاريخ
  Widget _buildDatePicker({bool enabled = true}) {
    return TextField(
      controller: _dateController,
      readOnly: true,
      enabled: enabled,
      style: TextStyle(color: AppTheme.textMainFor(context)),
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.calendar_today,
            color: enabled
                ? AppTheme.textSoftFor(context)
                : AppTheme.textFaintFor(context)),
        labelText: "التاريخ",
        labelStyle: TextStyle(
            color: enabled
                ? AppTheme.textSoftFor(context)
                : AppTheme.textFaintFor(context),
            fontFamily: 'Cairo'),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: GlassStyle.line10For(context))),
      ),
      onTap: enabled ? _pickDate : null,
    );
  }

  // يبني الأزرار الثانوية
  Widget _buildSecondaryActions() {
    bool canView = PermissionsService().canViewTransactions;

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
            icon: Icon(Icons.history, color: AppTheme.accentFor(context)),
            label: Text("المعاينة",
                style: TextStyle(
                    color: AppTheme.accentFor(context), fontFamily: 'Cairo')),
          ),

        const SizedBox(height: 10),
      ],
    );
  }

  // يفتح نافذة اختيار التاريخ
  Future<void> _pickDate() async {
    return CachePartitions.run(() async {
      DateTime? p = await showDatePicker(
          context: context,
          initialDate: DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2101));
      if (p != null)
        setState(
            () => _dateController.text = DateFormat('yyyy-MM-dd').format(p));
    });
  }

  // يستورد الحركات من ملف Excel
  void _importFromExcel() async {
    return CachePartitions.run(() async {
      // التحقق من صلاحية الاستيراد
      if (_isLoading || _saveBusy || !_sameFormOwner) return;
      if (!PermissionsService().canImportExcel) {
        _showSnackBar(
            "ليس لديك صلاحية للاستيراد", AppTheme.warningOrangeFor(context));
        return;
      }

      bool? proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("تنبيه قبل الاستيراد",
              style:
                  TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
              textAlign: TextAlign.right),
          content: const Text(
            "يرجى التأكد من احتواء ملف الإكسيل على الأعمدة التالية في الصف الأول بأي ترتيب:\n"
            " 🌟 ( المبلغ  -  البيان  -  التصنيف  -  التاريخ )\n"
            " 💡 يمكن إضافة عمود اختياري باسم (الخزينة) لتحديد الخزينة لكل حركة.\n\n"
            "💡 النظام ذكي بما يكفي لتجاهل أي أعمدة إضافية أخرى بالملف والتعرف التلقائي على الحقول المطلوبة.",
            style: TextStyle(fontFamily: 'Cairo', fontSize: 14),
            textAlign: TextAlign.right,
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text("إلغاء",
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        color: AppTheme.dangerStrongFor(context)))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.buttonPrimaryBg),
              onPressed: () => Navigator.pop(context, true),
              child: Text("موافق واختيار الملف",
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: Theme.of(context).colorScheme.onPrimary)),
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
          var cashTreasuryObj = _treasuries.firstWhere(
              (t) => t['code']?.toString() == "1",
              orElse: () => {});
          if (cashTreasuryObj.isNotEmpty && cashTreasuryObj.containsKey('name'))
            cashTreasuryName = cashTreasuryObj['name'];
          var visaTreasuryObj = _treasuries.firstWhere(
              (t) => t['code']?.toString() == "2",
              orElse: () => {});
          if (visaTreasuryObj.isNotEmpty && visaTreasuryObj.containsKey('name'))
            visaTreasuryName = visaTreasuryObj['name'];

          // قائمة بأسماء الخزائن المتاحة (للتأكد من صحة المدخلات)
          List<String> treasuryNames = _treasuries
              .map((t) => t['name']?.toString() ?? "")
              .where((n) => n.isNotEmpty)
              .toList();

          final importRows = <Map<String, dynamic>>[];
          for (var table in excel.tables.keys) {
            var rows = excel.tables[table]!.rows;
            if (rows.isEmpty) continue;
            // فهرسة الأعمدة المطلوبة
            int amountIdx = -1,
                statementIdx = -1,
                categoryIdx = -1,
                dateIdx = -1,
                treasuryIdx = -1;
            var headerRow = rows[0];
            for (int col = 0; col < headerRow.length; col++) {
              String headerVal = headerRow[col]?.value?.toString().trim() ?? "";
              if (headerVal == "المبلغ") amountIdx = col;
              if (headerVal == "البيان") statementIdx = col;
              if (headerVal == "التصنيف") categoryIdx = col;
              if (headerVal == "التاريخ") dateIdx = col;
              if (headerVal == "الخزينة" || headerVal == "خزينة")
                treasuryIdx = col; // ✅ دعم عمود الخزينة
            }
            // التأكد من وجود الأعمدة الأساسية
            if (amountIdx == -1 ||
                statementIdx == -1 ||
                categoryIdx == -1 ||
                dateIdx == -1) {
              throw "الملف لا يحتوي على الأعمدة الأساسية المطلوبة: (المبلغ، البيان، التصنيف، التاريخ). يرجى مراجعة عناوين الأعمدة بالصف الأول.";
            }

            // معالجة الصفوف
            for (int i = 1; i < rows.length; i++) {
              var row = rows[i];
              if (row.isEmpty ||
                  amountIdx >= row.length ||
                  row[amountIdx] == null ||
                  row[amountIdx]?.value == null) continue;
              double amount =
                  double.tryParse(row[amountIdx]!.value.toString().trim()) ??
                      0.0;
              if (amount == 0.0) continue;
              String statement = (statementIdx < row.length &&
                      row[statementIdx] != null &&
                      row[statementIdx]?.value != null)
                  ? row[statementIdx]!.value.toString().trim()
                  : "";
              String categoryStr = (categoryIdx < row.length &&
                      row[categoryIdx] != null &&
                      row[categoryIdx]?.value != null)
                  ? row[categoryIdx]!.value.toString().trim()
                  : "عام";
              String rawDate = (dateIdx < row.length &&
                      row[dateIdx] != null &&
                      row[dateIdx]?.value != null)
                  ? row[dateIdx]!.value.toString().trim()
                  : DateFormat('yyyy-MM-dd').format(DateTime.now());
              String formattedDate =
                  rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;

              // ✅ تحديد الخزينة: إما من العمود المخصص أو تلقائياً حسب التصنيف
              String targetTreasury;
              if (treasuryIdx != -1 &&
                  treasuryIdx < row.length &&
                  row[treasuryIdx] != null &&
                  row[treasuryIdx]?.value != null) {
                String treasuryFromExcel =
                    row[treasuryIdx]!.value.toString().trim();
                // إذا كانت القيمة موجودة في قائمة الخزائن، استخدمها، وإلا استخدم القيمة الافتراضية بناءً على التصنيف
                if (treasuryNames.contains(treasuryFromExcel)) {
                  targetTreasury = treasuryFromExcel;
                } else {
                  // إذا لم تكن الخزينة معروفة، نستخدم المنطق التلقائي القديم مع تحذير (يمكن إضافة تنبيه)
                  // لكننا سنكتفي باستخدام الافتراضي مع تجاهل القيمة غير المعروفة
                  targetTreasury = (categoryStr == "فيزا")
                      ? visaTreasuryName
                      : cashTreasuryName;
                }
              } else {
                // الطريقة القديمة: حسب التصنيف
                targetTreasury = (categoryStr == "فيزا")
                    ? visaTreasuryName
                    : cashTreasuryName;
              }

              // مطابقة التصنيف لتحديد النوع (وارد/صادر)
              var match = _categories.firstWhere(
                  (c) => c['name']?.toString().trim() == categoryStr,
                  orElse: () => {});
              String calculatedType =
                  match.isNotEmpty ? (match['type'] ?? "وارد") : "وارد";

              importRows.add({
                'company_code': widget.companyCode,
                'serial': 0,
                'treasury': targetTreasury,
                'amount': amount,
                'statement': statement,
                'category': categoryStr,
                'date': formattedDate,
                'type': calculatedType,
                'branch_code': _intentBranch,
                'employee': widget.userName ?? 'غير معروف',
                'link_id': null,
                'supplier_name': null,
                'add_to_settlement': false,
                'unlink_settlement': false,
              });
            }
          }
          await JournalImportBatch(
                  ownerUid: _formOwnerUid!,
                  companyCode: widget.companyCode,
                  branchCode: _intentBranch,
                  bytes: bytes)
              .run(
            rows: importRows,
            stillAuthorized: () =>
                _sameFormOwner &&
                PermissionsService().canImportExcel &&
                PermissionsService().canAccessBranch(_intentBranch),
            submit: (intent, store) =>
                _dailyService.saveCapturedTransaction(intent, store: store),
          );
          if (!mounted || !_sameFormOwner) return;
          _showSnackBar("تم تأكيد استيراد كل الصفوف في الخادم",
              AppTheme.successStrongFor(context));
          // ✅ إعادة تحميل البيانات والأرصدة بعد الاستيراد
          _loadInitialData();
        } catch (e) {
          if (mounted && _sameFormOwner)
            _showSnackBar(
                "لم يكتمل الاستيراد: $e. أعد اختيار نفس الملف لاستكمال المحاولة المحفوظة.",
                AppTheme.dangerStrongFor(context));
        } finally {
          if (mounted) setState(() => _isLoading = false);
        }
      }
    });
  }

  // يعرض رسالة سريعة بالنص واللون المحددين
  void _showSnackBar(String m, Color c) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(m,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: c));
}
