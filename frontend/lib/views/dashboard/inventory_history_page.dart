// lib/views/dashboard/inventory_history_page.dart

import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/inventory_service.dart';
import '../../models/inventory_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';
import 'inventory_page.dart';

class InventoryHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? branchName;

  const InventoryHistoryPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.branchName,
  });

  @override
  State<InventoryHistoryPage> createState() => _InventoryHistoryPageState();
}

class _InventoryHistoryPageState extends State<InventoryHistoryPage> {
  final InventoryService _inventoryService = InventoryService();

  List<InventoryModel> _inventories = [];
  List<Map<String, String>> _stores = [];

  bool _isLoading = true;
  bool _isInitializing = false;

  String? _filterStoreCode;
  String? _filterDate;

  InventoryModel? _selectedInventory;
  bool _showDetails = false;

  VoidCallback? _inventoryBoxListener;

  static const List<String> _itemHeaders = [
    'الكود',
    'الصنف',
    'الكمية',
    'سعر الجملة',
    'قيمة الجملة',
    'سعر البيع',
    'قيمة البيع',
  ];

  // ============================================================
  // Init / Dispose
  // ============================================================

  @override
  void initState() {
    super.initState();
    _inventoryBoxListener = _onInventoryBoxChanged;
    Hive.box('inventory_box')
        .listenable()
        .addListener(_inventoryBoxListener!);
    _initialize();
  }

  @override
  void dispose() {
    if (_inventoryBoxListener != null) {
      Hive.box('inventory_box')
          .listenable()
          .removeListener(_inventoryBoxListener!);
    }
    super.dispose();
  }

  void _onInventoryBoxChanged() {
    if (mounted) _loadData();
  }

  // ============================================================
  // التهيئة
  // ============================================================

  Future<void> _initialize() async {
    if (_isInitializing) return;
    _isInitializing = true;

    await _loadDropdowns();
    await _loadData();

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _isInitializing = false;
    });
  }

  // ============================================================
  // تحميل المخازن
  // ============================================================

  Future<void> _loadDropdowns() async {
    final box = Hive.box('coding_box');
    _stores = [{'code': 'all', 'name': 'كل المخازن'}];

    final raw = box.get(
      '${widget.companyCode}_stores',
      defaultValue: [],
    );

    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;

        final code = item['code']?.toString() ?? '';
        final name = item['name']?.toString() ?? '';

        if (code.isEmpty || name.isEmpty) continue;

        _stores.add({'code': code, 'name': name});
      }
    }

    if (mounted) setState(() {});
  }

  // ============================================================
  // هل المستخدم على كل الفروع؟
  // ============================================================

  bool get _isAllBranches {
    final code = widget.selectedBranchCode?.trim();

    return code == null ||
        code.isEmpty ||
        code == 'all' ||
        code == 'الكل' ||
        code == 'كل الفروع';
  }

  // ============================================================
  // تحميل البيانات
  // ============================================================

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final box = Hive.box('inventory_box');
      final List<InventoryModel> all = [];

      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! List) continue;

        for (final item in raw) {
          if (item is! Map || item['is_deleted'] == true) continue;

          if (item['company_code']?.toString() != widget.companyCode) {
            continue;
          }

          try {
            all.add(
              InventoryModel.fromMap(
                Map<String, dynamic>.from(item),
              ),
            );
          } catch (e) {
            debugPrint('⚠️ فشل تحويل عنصر الجرد: $e');
          }
        }
      }

      if (!_isAllBranches) {
        all.removeWhere(
          (inv) => inv.branchCode != widget.selectedBranchCode,
        );
      }

      if (_filterStoreCode != null && _filterStoreCode != 'all') {
        all.removeWhere(
          (inv) => inv.storeCode != _filterStoreCode,
        );
      }

      if (_filterDate != null && _filterDate!.isNotEmpty) {
        all.removeWhere(
          (inv) => inv.date != _filterDate,
        );
      }

      all.sort((a, b) {
        final dateCompare = b.date.compareTo(a.date);
        if (dateCompare != 0) return dateCompare;
        return (b.serial ?? 0).compareTo(a.serial ?? 0);
      });

      if (!mounted) return;

      setState(() {
        _inventories = all;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('❌ خطأ في تحميل الجردات: $e');

      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ============================================================
  // تحديث من السيرفر
  // ============================================================

  Future<void> _refreshFromServer() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      await _inventoryService.syncChangesFromServer(widget.companyCode);
      await _loadData();

      if (mounted) {
        _showSnackBar('تم تحديث الجرد بنجاح', AppTheme.successStrongFor(context));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('فشل التحديث: $e', AppTheme.dangerStrongFor(context));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ============================================================
  // أسماء الفرع والمخزن والشركة
  // ============================================================

  String _getBranchName(String? code) {
    if (code == null ||
        code.isEmpty ||
        code == 'all' ||
        code == 'الكل' ||
        code == 'كل الفروع') {
      return 'كل الفروع';
    }

    final box = Hive.box('coding_box');
    final raw = box.get(
      '${widget.companyCode}_branches',
      defaultValue: [],
    );

    if (raw is List) {
      for (final item in raw) {
        if (item is Map &&
            (item['code']?.toString() == code ||
                item['name']?.toString() == code)) {
          return item['name']?.toString() ?? code;
        }
      }
    }

    return 'فرع غير معروف';
  }

  String _getStoreName(String? code) {
    if (code == null || code.isEmpty || code == 'all') {
      return 'كل المخازن';
    }

    final found = _stores.firstWhere(
      (s) => s['code'] == code,
      orElse: () => {},
    );

    return found['name'] ?? code;
  }

  Future<String> _getCompanyName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('company_name') ?? 'شركتي';
  }

  // ============================================================
  // تنسيق الأرقام
  // ============================================================

  String _formatQuantity(double value) {
    return NumberFormat('#,##0.##', 'en_US').format(value);
  }

  String _formatCurrency(double value) {
    return NumberFormat('#,##0.00', 'en_US').format(value);
  }

  double _getTotalQuantity(InventoryModel inv) {
    return inv.items.fold<double>(
  0.0,
  (sum, item) => sum + item.quantity,
);
  }

  // ============================================================
  // تفاصيل / تعديل / حذف
  // ============================================================

  void _showInventoryDetails(InventoryModel model) {
    setState(() {
      _selectedInventory = model;
      _showDetails = true;
    });
  }

  void _goBackToList() {
    setState(() {
      _showDetails = false;
      _selectedInventory = null;
    });
  }

  void _editInventory(InventoryModel model) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => InventoryPage(
          companyCode: widget.companyCode,
          editItem: model,
        ),
      ),
    ).then((_) => _loadData());
  }

  void _confirmDelete(InventoryModel model) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        title: Text(
          'تأكيد الحذف',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
          ),
        ),
        content: Text(
          'هل أنت متأكد من حذف جرد ${model.date} - إذن ${model.serial ?? ''}؟',
          style: TextStyle(
            color: AppTheme.textSoftFor(context),
            fontFamily: 'Cairo',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'إلغاء',
              style: TextStyle(color: AppTheme.textMainFor(context)),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);

              if (model.docId == null) {
                _showSnackBar('رقم الجرد غير موجود', AppTheme.dangerStrongFor(context));
                return;
              }

              final deleted = await _inventoryService.deleteInventory(
                widget.companyCode,
                model.docId!,
              );

              if (deleted) {
                _showSnackBar('تم الحذف بنجاح', AppTheme.successStrongFor(context));
                await _loadData();
              } else {
                _showSnackBar('فشل الحذف', AppTheme.dangerStrongFor(context));
              }
            },
            child: Text(
              'حذف',
              style: TextStyle(color: AppTheme.dangerStrongFor(context)),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // تجهيز بيانات التصدير
  // ============================================================

  List<Map<String, dynamic>> _getItemExportData(
    InventoryModel inv,
  ) {
    return inv.items.map(
      (item) => {
        'الكود': item.code,
        'الصنف': item.name,
        'الكمية': item.quantity,
        'سعر الجملة': item.wholesalePrice,
        'قيمة الجملة': item.wholesaleValue,
        'سعر البيع': item.retailPrice,
        'قيمة البيع': item.retailValue,
      },
    ).toList();
  }

  // ============================================================
  // تصدير إذن واحد Excel
  // ============================================================

  Future<void> _exportSingleExcel(InventoryModel inv) async {
    try {
      final companyName = await _getCompanyName();
      final branchName = _getBranchName(inv.branchCode);
      final data = _getItemExportData(inv);

      await ExportService.exportToExcel(
        data,
        'جرد_${inv.date}_${inv.serial ?? ''}',
        _itemHeaders,
        _itemHeaders,
        companyName: companyName,
        branchName: branchName,
        storeName: _getStoreName(inv.storeCode),
        serial: inv.serial?.toString(),
        date: inv.date,
        summary: {
          'إجمالي الكمية': _getTotalQuantity(inv),
          'إجمالي الجملة': inv.totalWholesale,
          'إجمالي البيع': inv.totalRetail,
        },
      );

      _showSnackBar('تم تصدير الإذن بنجاح', AppTheme.successStrongFor(context));
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', AppTheme.dangerStrongFor(context));
    }
  }

  // ============================================================
  // تصدير إذن واحد PDF
  // ============================================================

  Future<void> _exportSinglePDF(InventoryModel inv) async {
    try {
      final companyName = await _getCompanyName();
      final branchName = _getBranchName(inv.branchCode);
      final data = _getItemExportData(inv);

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير جرد المخزون',
        headers: _itemHeaders,
        keys: _itemHeaders,
        companyName: companyName,
        branchName: branchName,
        storeName: _getStoreName(inv.storeCode),
        serial: inv.serial?.toString(),
        date: inv.date,
        summary: {
          'totalQuantity': _getTotalQuantity(inv),
          'totalWholesale': inv.totalWholesale,
          'totalRetail': inv.totalRetail,
        },
        totalAmount: inv.totalWholesale,
      );

      _showSnackBar('تم تصدير الإذن بنجاح', AppTheme.successStrongFor(context));
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', AppTheme.dangerStrongFor(context));
    }
  }

  // ============================================================
  // تصدير كل الجردات Excel
  // ============================================================

  Future<void> _exportAllExcel() async {
    if (_inventories.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', AppTheme.warningOrangeFor(context));
      return;
    }

    try {
      final companyName = await _getCompanyName();
      final branchName = widget.branchName ??
          (_isAllBranches
              ? 'كل الفروع'
              : _getBranchName(widget.selectedBranchCode));

      final data = _inventories.map(
        (inv) => {
          'رقم الإذن': inv.serial ?? '',
          'التاريخ': inv.date,
          'الفرع': _getBranchName(inv.branchCode),
          'المخزن': _getStoreName(inv.storeCode),
          'النوع': inv.inventoryType == 'general'
              ? 'جرد عام'
              : 'جرد محدد',
          'إجمالي الجملة': inv.totalWholesale,
          'إجمالي البيع': inv.totalRetail,
          'عدد الأصناف': inv.items.length,
          'إجمالي الكميات': _getTotalQuantity(inv),
        },
      ).toList();

      const headers = [
        'رقم الإذن',
        'التاريخ',
        'الفرع',
        'المخزن',
        'النوع',
        'إجمالي الجملة',
        'إجمالي البيع',
        'عدد الأصناف',
        'إجمالي الكميات',
      ];

      await ExportService.exportToExcel(
        data,
        'الجردات_${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
        headers,
        headers,
        companyName: companyName,
        branchName: branchName,
        period: _filterDate ?? 'كل التواريخ',
        summary: {
          'إجمالي الكميات': _inventories.fold<double>(
            0.0,
            (sum, inv) => sum + _getTotalQuantity(inv),
          ),
          'إجمالي الجملة': _inventories.fold<double>(
            0.0,
            (sum, inv) => sum + inv.totalWholesale,
          ),
          'إجمالي البيع': _inventories.fold<double>(
            0.0,
            (sum, inv) => sum + inv.totalRetail,
          ),
        },
      );

      _showSnackBar('تم تصدير جميع الجردات بنجاح', AppTheme.successStrongFor(context));
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', AppTheme.dangerStrongFor(context));
    }
  }

  // ============================================================
  // تصدير كل الجردات PDF
  // ============================================================

  Future<void> _exportAllPDF() async {
    if (_inventories.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', AppTheme.warningOrangeFor(context));
      return;
    }

    try {
      final companyName = await _getCompanyName();
      final branchName = widget.branchName ??
          (_isAllBranches
              ? 'كل الفروع'
              : _getBranchName(widget.selectedBranchCode));

      final data = _inventories.map(
        (inv) => {
          'رقم الإذن': inv.serial ?? '',
          'التاريخ': inv.date,
          'الفرع': _getBranchName(inv.branchCode),
          'المخزن': _getStoreName(inv.storeCode),
          'النوع': inv.inventoryType == 'general'
              ? 'جرد عام'
              : 'جرد محدد',
          'إجمالي الجملة': inv.totalWholesale,
          'إجمالي البيع': inv.totalRetail,
          'عدد الأصناف': inv.items.length,
          'إجمالي الكميات': _getTotalQuantity(inv),
        },
      ).toList();

      const headers = [
        'رقم الإذن',
        'التاريخ',
        'الفرع',
        'المخزن',
        'النوع',
        'إجمالي الجملة',
        'إجمالي البيع',
        'عدد الأصناف',
        'إجمالي الكميات',
      ];

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير الجردات المجمعة',
        headers: headers,
        keys: headers,
        companyName: companyName,
        branchName: branchName,
        period: _filterDate ?? 'كل التواريخ',
        summary: {
          'totalQuantity': _inventories.fold(
            0.0,
            (sum, inv) => sum + _getTotalQuantity(inv),
          ),
          'totalWholesale': _inventories.fold(
            0.0,
            (sum, inv) => sum + inv.totalWholesale,
          ),
          'totalRetail': _inventories.fold(
            0.0,
            (sum, inv) => sum + inv.totalRetail,
          ),
        },
        totalAmount: _inventories.fold<double>(
          0.0,
          (sum, inv) => sum + inv.totalWholesale,
        ),
      );

      _showSnackBar('تم تصدير جميع الجردات بنجاح', AppTheme.successStrongFor(context));
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', AppTheme.dangerStrongFor(context));
    }
  }

  // ============================================================
  // SnackBar
  // ============================================================

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canViewInventory) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            'معاينة الجرد',
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
            ),
          ),
          backgroundColor: AppTheme.appBarBg,
        ),
        body: Center(
          child: Text(
            'ليس لديك صلاحية لعرض الجرد',
            style: TextStyle(
              color: AppTheme.textSoftFor(context),
              fontFamily: 'Cairo',
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showDetails ? 'تفاصيل الجرد' : 'معاينة الجرد',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
          ),
        ),
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppTheme.textMainFor(context)),
          onPressed: _showDetails
              ? _goBackToList
              : () => Navigator.pop(context),
        ),
        actions: [
          if (!_showDetails &&
              PermissionsService().canExportInventory)
            IconButton(
              icon: Icon(
                Icons.download,
                color: AppTheme.infoFor(context),
              ),
              onPressed: _exportAllExcel,
              tooltip: 'تصدير Excel',
            ),
          if (!_showDetails &&
              PermissionsService().canExportInventory)
            IconButton(
              icon: Icon(
                Icons.picture_as_pdf,
                color: AppTheme.dangerFor(context),
              ),
              onPressed: _exportAllPDF,
              tooltip: 'تصدير PDF',
            ),
          if (!_showDetails)
            IconButton(
              icon: Icon(
                Icons.refresh,
                color: AppTheme.textMainFor(context),
              ),
              onPressed: _refreshFromServer,
              tooltip: 'تحديث من السيرفر',
            ),
        ],
      ),
      body: Container(
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
                    color: AppTheme.textMainFor(context),
                  ),
                )
              : _showDetails &&
                      _selectedInventory != null
                  ? _buildDetailsView(
                      _selectedInventory!,
                    )
                  : _buildListView(),
        ),
      ),
    );
  }

  // ============================================================
  // القائمة
  // ============================================================

  Widget _buildListView() {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final displayBranchName = widget.branchName ??
        _getBranchName(widget.selectedBranchCode);

    return Column(
      children: [
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Icon(
                  Icons.storefront,
                  color: AppTheme.accentFor(context),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'الفرع الحالي: $displayBranchName',
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Cairo',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    value: _filterStoreCode,
                    dropdownColor: AppTheme.dropdownBackground(context),
                    style: TextStyle(color: AppTheme.textMainFor(context)),
                    decoration: const InputDecoration(
                      labelText: 'المخزن',
                      isDense: true,
                    ),
                    items: _stores.map(
                      (s) => DropdownMenuItem<String?>(
                        value: s['code'],
                        child: Text(s['name'] ?? ''),
                      ),
                    ).toList(),
                    onChanged: (val) {
                      setState(() => _filterStoreCode = val);
                      _loadData();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey(_filterDate),
                    initialValue: _filterDate ?? '',
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'التاريخ',
                      suffixIcon:
                          Icon(Icons.calendar_today),
                      isDense: true,
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _filterDate != null
                            ? DateTime.tryParse(_filterDate!) ??
                                DateTime.now()
                            : DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2101),
                      );

                      if (picked == null) return;

                      setState(
                        () => _filterDate =
                            DateFormat('yyyy-MM-dd')
                                .format(picked),
                      );

                      _loadData();
                    },
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.clear,
                    color: AppTheme.textSoftFor(context),
                  ),
                  onPressed: () {
                    setState(() {
                      _filterStoreCode = null;
                      _filterDate = null;
                    });
                    _loadData();
                  },
                  tooltip: 'إلغاء الفلاتر',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _inventories.isEmpty
              ? Center(
                  child: Text(
                    'لا توجد جردات',
                    style: TextStyle(
                      color: AppTheme.textSoftFor(context),
                      fontFamily: 'Cairo',
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _inventories.length,
                  itemBuilder: (c, i) =>
                      _buildInventoryCard(
                    _inventories[i],
                    isMobile,
                  ),
                ),
        ),
      ],
    );
  }

  // ============================================================
  // بطاقة الجرد
  // ============================================================

  Widget _buildInventoryCard(
    InventoryModel inv,
    bool isMobile,
  ) {
    return Card(
      color: GlassStyle.fill05For(context),
      margin: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 4,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showInventoryDetails(inv),
        child: Padding(
          padding: EdgeInsets.all(isMobile ? 8 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: isMobile ? 16 : 20,
                    backgroundColor:
                        GlassStyle.accentFill20For(context),
                    child: Text(
                      '${inv.serial ?? ''}',
                      style: TextStyle(
                        color: AppTheme.accentFor(context),
                        fontWeight: FontWeight.bold,
                        fontSize: isMobile ? 10 : 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_getBranchName(inv.branchCode)} - ${_getStoreName(inv.storeCode)}',
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontSize: isMobile ? 12 : 14,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'إذن رقم: ${inv.serial ?? ''}',
                          style: TextStyle(
                            color: AppTheme.accentFor(context),
                            fontSize: isMobile ? 10 : 11,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'التاريخ: ${inv.date}',
                          style: TextStyle(
                            color: AppTheme.textMutedFor(context),
                            fontSize: isMobile ? 10 : 12,
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: inv.inventoryType == 'general'
                          ? GlassStyle.successFill15For(context)
                          : GlassStyle.warningOrangeSoftFill15For(context),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      inv.inventoryType == 'general'
                          ? 'جرد عام'
                          : 'جرد محدد',
                      style: TextStyle(
                        color: inv.inventoryType == 'general'
                            ? AppTheme.successFor(context)
                            : AppTheme.warningOrangeSoftFor(context),
                        fontSize: isMobile ? 8 : 10,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: isMobile ? 4 : 8,
                runSpacing: 4,
                children: [
                  _buildInfoChip(
                    'الأصناف',
                    inv.items.length.toString(),
                    AppTheme.infoFor(context),
                    isMobile,
                  ),
                  _buildInfoChip(
                    'إجمالي الكمية',
                    _formatQuantity(_getTotalQuantity(inv)),
                    AppTheme.accentFor(context),
                    isMobile,
                  ),
                  _buildInfoChip(
                    'إجمالي الجملة',
                    _formatCurrency(inv.totalWholesale),
                    AppTheme.successFor(context),
                    isMobile,
                  ),
                  _buildInfoChip(
                    'إجمالي البيع',
                    _formatCurrency(inv.totalRetail),
                    AppTheme.warningFor(context),
                    isMobile,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (PermissionsService().canEditInventory)
                    IconButton(
                      icon: Icon(
                        Icons.edit,
                        color: AppTheme.warningOrangeFor(context),
                        size: 18,
                      ),
                      onPressed: () => _editInventory(inv),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  if (PermissionsService().canDeleteInventory)
                    IconButton(
                      icon: Icon(
                        Icons.delete,
                        color: AppTheme.dangerStrongFor(context),
                        size: 18,
                      ),
                      onPressed: () => _confirmDelete(inv),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  IconButton(
                    icon: Icon(
                      Icons.arrow_forward_ios,
                      color: AppTheme.accentFor(context),
                      size: 16,
                    ),
                    onPressed: () =>
                        _showInventoryDetails(inv),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Info Chip
  // ============================================================

  Widget _buildInfoChip(
    String label,
    String value,
    Color color,
    bool isMobile,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 6 : 8,
        vertical: isMobile ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withOpacity(0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontSize: isMobile ? 8 : 10,
              fontFamily: 'Cairo',
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: isMobile ? 9 : 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // التفاصيل
  // ============================================================

  Widget _buildDetailsView(
    InventoryModel inv,
  ) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              'إذن جرد رقم ${inv.serial ?? ''}',
                              style: TextStyle(
                                color: AppTheme.textMainFor(context),
                                fontSize: isMobile ? 16 : 18,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'الفرع: ${_getBranchName(inv.branchCode)}',
                              style: TextStyle(
                                color: AppTheme.successFor(context),
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'المخزن: ${_getStoreName(inv.storeCode)}',
                              style: TextStyle(
                                color: AppTheme.textMutedFor(context),
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'التاريخ: ${inv.date}',
                              style: TextStyle(
                                color: AppTheme.textMutedFor(context),
                                fontFamily: 'Cairo',
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        inv.inventoryType == 'general'
                            ? 'جرد عام'
                            : 'جرد محدد',
                        style: TextStyle(
                          color: inv.inventoryType == 'general'
                              ? AppTheme.successFor(context)
                              : AppTheme.warningOrangeSoftFor(context),
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 10 : 12,
                          fontFamily: 'Cairo',
                        ),
                      ),
                    ],
                  ),
                  Divider(color: GlassStyle.line24For(context)),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDetailItem(
                          'عدد الأصناف',
                          inv.items.length.toString(),
                          Icons.list_alt,
                          isMobile,
                        ),
                      ),
                      Expanded(
                        child: _buildDetailItem(
                          'إجمالي الكمية',
                          _formatQuantity(
                            _getTotalQuantity(inv),
                          ),
                          Icons.numbers,
                          isMobile,
                        ),
                      ),
                      Expanded(
                        child: _buildDetailItem(
                          'إجمالي الجملة',
                          _formatCurrency(
                            inv.totalWholesale,
                          ),
                          Icons.attach_money,
                          isMobile,
                        ),
                      ),
                      Expanded(
                        child: _buildDetailItem(
                          'إجمالي البيع',
                          _formatCurrency(
                            inv.totalRetail,
                          ),
                          Icons.sell,
                          isMobile,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (PermissionsService()
                          .canEditInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _editInventory(inv),
                          icon: Icon(
                            Icons.edit,
                            color: AppTheme.warningOrangeFor(context),
                          ),
                          label: Text(
                            'تعديل',
                            style: TextStyle(
                              color: AppTheme.warningOrangeFor(context),
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ),
                      if (PermissionsService()
                          .canDeleteInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _confirmDelete(inv),
                          icon: Icon(
                            Icons.delete,
                            color: AppTheme.dangerStrongFor(context),
                          ),
                          label: Text(
                            'حذف',
                            style: TextStyle(
                              color: AppTheme.dangerStrongFor(context),
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ),
                      if (PermissionsService()
                          .canExportInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _exportSingleExcel(inv),
                          icon: Icon(
                            Icons.download,
                            color: AppTheme.infoFor(context),
                          ),
                          label: Text(
                            'Excel',
                            style: TextStyle(
                              color: AppTheme.infoFor(context),
                            ),
                          ),
                        ),
                      if (PermissionsService()
                          .canExportInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _exportSinglePDF(inv),
                          icon: Icon(
                            Icons.picture_as_pdf,
                            color: AppTheme.dangerFor(context),
                          ),
                          label: Text(
                            'PDF',
                            style: TextStyle(
                              color: AppTheme.dangerFor(context),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    'تفاصيل الأصناف',
                    style: TextStyle(
                      color: AppTheme.accentFor(context),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Cairo',
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildItemsTable(inv, isMobile),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceAround,
                children: [
                  _buildTotalBox(
                    'إجمالي الكمية',
                    _formatQuantity(
                      _getTotalQuantity(inv),
                    ),
                    AppTheme.accentFor(context),
                  ),
                  _buildVerticalDivider(),
                  _buildTotalBox(
                    'إجمالي الجملة',
                    _formatCurrency(
                      inv.totalWholesale,
                    ),
                    AppTheme.successFor(context),
                  ),
                  _buildVerticalDivider(),
                  _buildTotalBox(
                    'إجمالي البيع',
                    _formatCurrency(
                      inv.totalRetail,
                    ),
                    AppTheme.warningFor(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // جدول الأصناف
  // ============================================================

  Widget _buildItemsTable(
    InventoryModel inv,
    bool isMobile,
  ) {
    const codeWidth = 60.0;
    const nameWidth = 85.0;
    const qtyWidth = 60.0;
    const valueWidth = 70.0;

    if (isMobile) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _tableHeader('#', 30, AppTheme.accentAltFor(context)),
                _tableHeader('الكود', codeWidth, AppTheme.accentAltFor(context)),
                _tableHeader('الصنف', nameWidth, AppTheme.accentAltFor(context)),
                _tableHeader('الكمية', qtyWidth, AppTheme.accentAltFor(context)),
                _tableHeader(
                  'سعر الجملة',
                  valueWidth,
                  AppTheme.successFor(context),
                ),
                _tableHeader(
                  'قيمة الجملة',
                  valueWidth,
                  AppTheme.successFor(context),
                ),
                _tableHeader(
                  'سعر البيع',
                  valueWidth,
                  AppTheme.warningFor(context),
                ),
                _tableHeader(
                  'قيمة البيع',
                  valueWidth,
                  AppTheme.warningFor(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ...inv.items.asMap().entries.map(
              (entry) => Row(
                children: [
                  _tableCell(
                    '${entry.key + 1}',
                    30,
                    AppTheme.textHintFor(context),
                  ),
                  _tableCell(
                    entry.value.code,
                    codeWidth,
                    AppTheme.textSoftFor(context),
                  ),
                  _tableCell(
                    entry.value.name,
                    nameWidth,
                    AppTheme.textMainFor(context),
                  ),
                  _tableCell(
                    _formatQuantity(
                      entry.value.quantity,
                    ),
                    qtyWidth,
                    AppTheme.textSoftFor(context),
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.wholesalePrice,
                    ),
                    valueWidth,
                    AppTheme.successFor(context),
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.wholesaleValue,
                    ),
                    valueWidth,
                    AppTheme.successFor(context),
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.retailPrice,
                    ),
                    valueWidth,
                    AppTheme.warningFor(context),
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.retailValue,
                    ),
                    valueWidth,
                    AppTheme.warningFor(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: const [
            Expanded(child: Text('#', textAlign: TextAlign.center)),
            Expanded(child: Text('الكود', textAlign: TextAlign.center)),
            Expanded(flex: 2, child: Text('الصنف', textAlign: TextAlign.center)),
            Expanded(child: Text('الكمية', textAlign: TextAlign.center)),
            Expanded(child: Text('سعر الجملة', textAlign: TextAlign.center)),
            Expanded(child: Text('قيمة الجملة', textAlign: TextAlign.center)),
            Expanded(child: Text('سعر البيع', textAlign: TextAlign.center)),
            Expanded(child: Text('قيمة البيع', textAlign: TextAlign.center)),
          ],
        ),
        Divider(color: GlassStyle.line10For(context)),
        ...inv.items.asMap().entries.map(
          (entry) {
            final item = entry.value;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: _tableDesktopText(
                      '${entry.key + 1}',
                      AppTheme.textHintFor(context),
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      item.code,
                      AppTheme.textSoftFor(context),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _tableDesktopText(
                      item.name,
                      AppTheme.textMainFor(context),
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatQuantity(item.quantity),
                      AppTheme.textSoftFor(context),
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.wholesalePrice,
                      ),
                      AppTheme.successFor(context),
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.wholesaleValue,
                      ),
                      AppTheme.successFor(context),
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.retailPrice,
                      ),
                      AppTheme.warningFor(context),
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.retailValue,
                      ),
                      AppTheme.warningFor(context),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  // ============================================================
  // إجماليات
  // ============================================================

  Widget _buildTotalBox(
    String label,
    String value,
    Color color,
  ) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontSize: 10,
            fontFamily: 'Cairo',
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _buildVerticalDivider() {
    return Container(
      width: 1,
      height: 30,
      color: GlassStyle.line24For(context),
    );
  }

  // ============================================================
  // أدوات الجدول
  // ============================================================

  Widget _tableHeader(
    String text,
    double width,
    Color color,
  ) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 8,
          fontFamily: 'Cairo',
        ),
      ),
    );
  }

  Widget _tableCell(
    String text,
    double width,
    Color color,
  ) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 4,
          horizontal: 2,
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 8,
          ),
        ),
      ),
    );
  }

  Widget _tableDesktopText(
    String text,
    Color color,
  ) {
    return Text(
      text,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontSize: 9,
      ),
    );
  }

  // ============================================================
  // Detail Item
  // ============================================================

  Widget _buildDetailItem(
    String label,
    String value,
    IconData icon,
    bool isMobile,
  ) {
    return Row(
      children: [
        Icon(
          icon,
          color: AppTheme.accentFor(context),
          size: isMobile ? 14 : 16,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontSize: isMobile ? 8 : 10,
                  fontFamily: 'Cairo',
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: isMobile ? 10 : 12,
                  fontFamily: 'Cairo',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}