// lib/views/dashboard/inventory_history_page.dart

import 'package:flutter/material.dart';
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
        _showSnackBar('تم تحديث الجرد بنجاح', Colors.green);
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('فشل التحديث: $e', Colors.red);
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
        backgroundColor: Colors.indigo.shade900,
        title: const Text(
          'تأكيد الحذف',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Cairo',
          ),
        ),
        content: Text(
          'هل أنت متأكد من حذف جرد ${model.date} - إذن ${model.serial ?? ''}؟',
          style: const TextStyle(
            color: Colors.white70,
            fontFamily: 'Cairo',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'إلغاء',
              style: TextStyle(color: Colors.white),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);

              if (model.docId == null) {
                _showSnackBar('رقم الجرد غير موجود', Colors.red);
                return;
              }

              final deleted = await _inventoryService.deleteInventory(
                widget.companyCode,
                model.docId!,
              );

              if (deleted) {
                _showSnackBar('تم الحذف بنجاح', Colors.green);
                await _loadData();
              } else {
                _showSnackBar('فشل الحذف', Colors.red);
              }
            },
            child: const Text(
              'حذف',
              style: TextStyle(color: Colors.red),
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

      _showSnackBar('تم تصدير الإذن بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
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

      _showSnackBar('تم تصدير الإذن بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
    }
  }

  // ============================================================
  // تصدير كل الجردات Excel
  // ============================================================

  Future<void> _exportAllExcel() async {
    if (_inventories.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', Colors.orange);
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

      _showSnackBar('تم تصدير جميع الجردات بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
    }
  }

  // ============================================================
  // تصدير كل الجردات PDF
  // ============================================================

  Future<void> _exportAllPDF() async {
    if (_inventories.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', Colors.orange);
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

      _showSnackBar('تم تصدير جميع الجردات بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
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
          title: const Text(
            'معاينة الجرد',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'Cairo',
            ),
          ),
          backgroundColor: Colors.transparent,
        ),
        body: const Center(
          child: Text(
            'ليس لديك صلاحية لعرض الجرد',
            style: TextStyle(
              color: Colors.white70,
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
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'Cairo',
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: _showDetails
              ? _goBackToList
              : () => Navigator.pop(context),
        ),
        actions: [
          if (!_showDetails &&
              PermissionsService().canExportInventory)
            IconButton(
              icon: const Icon(
                Icons.download,
                color: Colors.blueAccent,
              ),
              onPressed: _exportAllExcel,
              tooltip: 'تصدير Excel',
            ),
          if (!_showDetails &&
              PermissionsService().canExportInventory)
            IconButton(
              icon: const Icon(
                Icons.picture_as_pdf,
                color: Colors.redAccent,
              ),
              onPressed: _exportAllPDF,
              tooltip: 'تصدير PDF',
            ),
          if (!_showDetails)
            IconButton(
              icon: const Icon(
                Icons.refresh,
                color: Colors.white,
              ),
              onPressed: _refreshFromServer,
              tooltip: 'تحديث من السيرفر',
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.black,
              Color(0xFF1A237E),
              Colors.black,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: Colors.white,
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
                const Icon(
                  Icons.storefront,
                  color: Colors.cyanAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'الفرع الحالي: $displayBranchName',
                    style: const TextStyle(
                      color: Colors.white,
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
                    dropdownColor: Colors.indigo.shade900,
                    style: const TextStyle(color: Colors.white),
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
                  icon: const Icon(
                    Icons.clear,
                    color: Colors.white70,
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
              ? const Center(
                  child: Text(
                    'لا توجد جردات',
                    style: TextStyle(
                      color: Colors.white70,
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
      color: Colors.white.withOpacity(0.05),
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
                        Colors.cyanAccent.withOpacity(0.2),
                    child: Text(
                      '${inv.serial ?? ''}',
                      style: TextStyle(
                        color: Colors.cyanAccent,
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
                            color: Colors.white,
                            fontSize: isMobile ? 12 : 14,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'إذن رقم: ${inv.serial ?? ''}',
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: isMobile ? 10 : 11,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'التاريخ: ${inv.date}',
                          style: TextStyle(
                            color: Colors.white60,
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
                          ? Colors.greenAccent.withOpacity(0.15)
                          : Colors.orangeAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      inv.inventoryType == 'general'
                          ? 'جرد عام'
                          : 'جرد محدد',
                      style: TextStyle(
                        color: inv.inventoryType == 'general'
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
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
                    Colors.blueAccent,
                    isMobile,
                  ),
                  _buildInfoChip(
                    'إجمالي الكمية',
                    _formatQuantity(_getTotalQuantity(inv)),
                    Colors.cyanAccent,
                    isMobile,
                  ),
                  _buildInfoChip(
                    'إجمالي الجملة',
                    _formatCurrency(inv.totalWholesale),
                    Colors.greenAccent,
                    isMobile,
                  ),
                  _buildInfoChip(
                    'إجمالي البيع',
                    _formatCurrency(inv.totalRetail),
                    Colors.amber,
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
                      icon: const Icon(
                        Icons.edit,
                        color: Colors.orange,
                        size: 18,
                      ),
                      onPressed: () => _editInventory(inv),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  if (PermissionsService().canDeleteInventory)
                    IconButton(
                      icon: const Icon(
                        Icons.delete,
                        color: Colors.red,
                        size: 18,
                      ),
                      onPressed: () => _confirmDelete(inv),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_forward_ios,
                      color: Colors.cyanAccent,
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
              color: Colors.white60,
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
                                color: Colors.white,
                                fontSize: isMobile ? 16 : 18,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'الفرع: ${_getBranchName(inv.branchCode)}',
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'المخزن: ${_getStoreName(inv.storeCode)}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'التاريخ: ${inv.date}',
                              style: const TextStyle(
                                color: Colors.white60,
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
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: isMobile ? 10 : 12,
                          fontFamily: 'Cairo',
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
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
                          icon: const Icon(
                            Icons.edit,
                            color: Colors.orange,
                          ),
                          label: const Text(
                            'تعديل',
                            style: TextStyle(
                              color: Colors.orange,
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ),
                      if (PermissionsService()
                          .canDeleteInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _confirmDelete(inv),
                          icon: const Icon(
                            Icons.delete,
                            color: Colors.red,
                          ),
                          label: const Text(
                            'حذف',
                            style: TextStyle(
                              color: Colors.red,
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ),
                      if (PermissionsService()
                          .canExportInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _exportSingleExcel(inv),
                          icon: const Icon(
                            Icons.download,
                            color: Colors.blueAccent,
                          ),
                          label: const Text(
                            'Excel',
                            style: TextStyle(
                              color: Colors.blueAccent,
                            ),
                          ),
                        ),
                      if (PermissionsService()
                          .canExportInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _exportSinglePDF(inv),
                          icon: const Icon(
                            Icons.picture_as_pdf,
                            color: Colors.redAccent,
                          ),
                          label: const Text(
                            'PDF',
                            style: TextStyle(
                              color: Colors.redAccent,
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
                  const Text(
                    'تفاصيل الأصناف',
                    style: TextStyle(
                      color: Colors.cyanAccent,
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
                    Colors.cyanAccent,
                  ),
                  _buildVerticalDivider(),
                  _buildTotalBox(
                    'إجمالي الجملة',
                    _formatCurrency(
                      inv.totalWholesale,
                    ),
                    Colors.greenAccent,
                  ),
                  _buildVerticalDivider(),
                  _buildTotalBox(
                    'إجمالي البيع',
                    _formatCurrency(
                      inv.totalRetail,
                    ),
                    Colors.amber,
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
                _tableHeader('#', 30, Colors.cyan),
                _tableHeader('الكود', codeWidth, Colors.cyan),
                _tableHeader('الصنف', nameWidth, Colors.cyan),
                _tableHeader('الكمية', qtyWidth, Colors.cyan),
                _tableHeader(
                  'سعر الجملة',
                  valueWidth,
                  Colors.greenAccent,
                ),
                _tableHeader(
                  'قيمة الجملة',
                  valueWidth,
                  Colors.greenAccent,
                ),
                _tableHeader(
                  'سعر البيع',
                  valueWidth,
                  Colors.amber,
                ),
                _tableHeader(
                  'قيمة البيع',
                  valueWidth,
                  Colors.amber,
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
                    Colors.white54,
                  ),
                  _tableCell(
                    entry.value.code,
                    codeWidth,
                    Colors.white70,
                  ),
                  _tableCell(
                    entry.value.name,
                    nameWidth,
                    Colors.white,
                  ),
                  _tableCell(
                    _formatQuantity(
                      entry.value.quantity,
                    ),
                    qtyWidth,
                    Colors.white70,
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.wholesalePrice,
                    ),
                    valueWidth,
                    Colors.greenAccent,
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.wholesaleValue,
                    ),
                    valueWidth,
                    Colors.greenAccent,
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.retailPrice,
                    ),
                    valueWidth,
                    Colors.amber,
                  ),
                  _tableCell(
                    _formatCurrency(
                      entry.value.retailValue,
                    ),
                    valueWidth,
                    Colors.amber,
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
        const Divider(color: Colors.white10),
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
                      Colors.white54,
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      item.code,
                      Colors.white70,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _tableDesktopText(
                      item.name,
                      Colors.white,
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatQuantity(item.quantity),
                      Colors.white70,
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.wholesalePrice,
                      ),
                      Colors.greenAccent,
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.wholesaleValue,
                      ),
                      Colors.greenAccent,
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.retailPrice,
                      ),
                      Colors.amber,
                    ),
                  ),
                  Expanded(
                    child: _tableDesktopText(
                      _formatCurrency(
                        item.retailValue,
                      ),
                      Colors.amber,
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
          style: const TextStyle(
            color: Colors.white60,
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
      color: Colors.white24,
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
          color: Colors.cyanAccent,
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
                  color: Colors.white60,
                  fontSize: isMobile ? 8 : 10,
                  fontFamily: 'Cairo',
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: Colors.white,
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