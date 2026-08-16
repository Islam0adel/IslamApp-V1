// lib/views/dashboard/supplier_history_page.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/supplier_service.dart';
import '../../models/supplier_transaction_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';
import 'supplier_page.dart';

// ============================================================
// صفحة معاينة المشتريات
// ============================================================

class SupplierHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? userName;

  const SupplierHistoryPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.userName,
  });

  @override
  State<SupplierHistoryPage> createState() => _SupplierHistoryPageState();
}

class _SupplierHistoryPageState extends State<SupplierHistoryPage> {
  final SupplierService _supplierService = SupplierService();

  // البيانات
  List<SupplierTransactionModel> _transactions = [];
  bool _isLoading = true;
  bool _isInitializing = false;

  // الفلاتر
  String? _selectedSupplierCode = 'all';
  String? _filterStore = 'all';
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();

  // القوائم
  List<Map<String, String>> _suppliers = [];
  List<Map<String, String>> _stores = [];

  // التفاصيل
  SupplierTransactionModel? _selectedTransaction;
  bool _showDetails = false;

  // إجماليات الفترة
  double _totalPurchases = 0.0;
  double _totalSettlements = 0.0;
  double _supplierRemaining = 0.0;

  @override
  void initState() {
    super.initState();
    _selectedSupplierCode = 'all';
    _filterStore = 'all';
    _initialize();
  }

  // ==========================================================
  // الفروع
  // ==========================================================

  bool get _isAllBranches {
    final code = widget.selectedBranchCode?.trim();
    return code == null || code.isEmpty || code == 'all' || code == 'الكل' || code == 'كل الفروع';
  }

  String? get _effectiveBranchCode => _isAllBranches ? null : widget.selectedBranchCode;

  // ==========================================================
  // التهيئة
  // ==========================================================

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

  // ==========================================================
  // تحميل القوائم
  // ==========================================================

  Future<void> _loadDropdowns() async {
    final box = Hive.box('coding_box');

    _suppliers = [{'code': 'all', 'name': 'كل الموردين'}];
    final suppliers = box.get('${widget.companyCode}_suppliers') as List? ?? [];

    for (final item in suppliers) {
      if (item is! Map) continue;

      final code = item['code']?.toString() ?? '';
      final name = item['name']?.toString() ?? '';

      if (code.isEmpty || name.isEmpty) continue;
      _suppliers.add({'code': code, 'name': name});
    }

    _stores = [{'code': 'all', 'name': 'كل المخازن'}];
    final stores = box.get('${widget.companyCode}_stores') as List? ?? [];

    for (final item in stores) {
      if (item is! Map) continue;

      final code = item['code']?.toString() ?? '';
      final name = item['name']?.toString() ?? '';

      if (code.isEmpty || name.isEmpty) continue;
      _stores.add({'code': code, 'name': name});
    }

    if (mounted) setState(() {});
  }

  // ==========================================================
  // تحميل بيانات المشتريات
  // ==========================================================

  Future<void> _loadData() async {
    if (mounted) setState(() => _isLoading = true);

    try {
      String? supplierName;

      if (_selectedSupplierCode != null && _selectedSupplierCode != 'all') {
        final found = _suppliers.firstWhere(
          (s) => s['code'] == _selectedSupplierCode,
          orElse: () => {},
        );
        supplierName = found['name'];
      }

      final startDate = DateFormat('yyyy-MM-dd').format(_fromDate);
      final endDate = DateFormat('yyyy-MM-dd').format(_toDate);

      final transactions = await _supplierService.getSupplierTransactions(
        companyCode: widget.companyCode,
        branchCode: _effectiveBranchCode,
        supplierName: supplierName,
        startDate: startDate,
        endDate: endDate,
      );

      List<SupplierTransactionModel> filtered = transactions;

      if (_filterStore != null && _filterStore != 'all') {
        filtered = filtered.where((t) => t.storeCode == _filterStore).toList();
      }

      filtered.sort((a, b) {
        final dateCompare = b.date.compareTo(a.date);
        if (dateCompare != 0) return dateCompare;
        return b.serial.compareTo(a.serial);
      });

      final purchasesTotal = filtered.fold<double>(
        0.0,
        (sum, item) => sum + item.totalAmount,
      );

      final settlementTotal = await _calculateSettlementTotal(
        supplierName: supplierName,
      );

      final remaining = purchasesTotal - settlementTotal;

      if (!mounted) return;

      setState(() {
        _transactions = filtered;
        _totalPurchases = purchasesTotal;
        _totalSettlements = settlementTotal;
        _supplierRemaining = remaining;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ خطأ في تحميل حركات الموردين: $e');

      if (!mounted) return;

      setState(() {
        _transactions = [];
        _totalPurchases = 0.0;
        _totalSettlements = 0.0;
        _supplierRemaining = 0.0;
        _isLoading = false;
      });
    }
  }

  // ==========================================================
  // حساب إجمالي تسويات المورد
  // ==========================================================

  Future<double> _calculateSettlementTotal({String? supplierName}) async {
    double total = 0.0;
    final box = Hive.box('supplier_settlement_box');

    final from = DateFormat('yyyy-MM-dd').format(_fromDate);
    final to = DateFormat('yyyy-MM-dd').format(_toDate);

    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! List) continue;

      for (final item in raw) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);

        if (map['is_deleted'] == true) continue;
        if (map['company_code']?.toString() != widget.companyCode) continue;

        if (!_isAllBranches && map['branch_code']?.toString() != widget.selectedBranchCode) {
          continue;
        }

        if (supplierName != null && map['supplier_name']?.toString() != supplierName) {
          continue;
        }

        final date = map['date']?.toString() ?? '';

        if (date.compareTo(from) < 0 || date.compareTo(to) > 0) continue;

        total += _toDouble(map['amount']);
      }
    }

    return total;
  }

  // ==========================================================
  // أسماء البيانات
  // ==========================================================

  String _getStoreName(String? code) {
    if (code == null || code == 'all') return 'كل المخازن';

    final found = _stores.firstWhere(
      (s) => s['code'] == code,
      orElse: () => {},
    );

    return found['name'] ?? code;
  }

  String _getBranchName(String? codeOrName) {
    if (codeOrName == null || codeOrName.isEmpty || codeOrName == 'all' || codeOrName == 'الكل' || codeOrName == 'كل الفروع') {
      return 'كل الفروع';
    }

    final box = Hive.box('coding_box');
    final raw = box.get('${widget.companyCode}_branches', defaultValue: []);

    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;

        if (item['code']?.toString() == codeOrName || item['name']?.toString() == codeOrName) {
          return item['name']?.toString() ?? codeOrName;
        }
      }
    }

    return codeOrName;
  }

  Future<String> _getCompanyName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('company_name') ?? 'شركتي';
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '0') ?? 0.0;
  }

  String _formatCurrency(double amount) => NumberFormat('#,##0.00', 'en_US').format(amount);

  // ==========================================================
  // التفاصيل والتنقل
  // ==========================================================

  void _showTransactionDetails(SupplierTransactionModel model) {
    setState(() {
      _selectedTransaction = model;
      _showDetails = true;
    });
  }

  void _goBackToList() {
    setState(() {
      _showDetails = false;
      _selectedTransaction = null;
    });
  }

  void _editTransaction(SupplierTransactionModel model) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => SupplierPage(
          companyCode: widget.companyCode,
          selectedBranchCode: model.branchCode,
          userName: widget.userName,
          editItem: model,
        ),
      ),
    ).then((_) => _loadData());
  }

  void _confirmDelete(SupplierTransactionModel model) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.indigo.shade900,
        title: const Text(
          'تأكيد الحذف',
          style: TextStyle(color: Colors.white, fontFamily: 'Cairo'),
        ),
        content: Text(
          'هل أنت متأكد من حذف فاتورة المورد رقم ${model.serial}؟',
          style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white, fontFamily: 'Cairo')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);

              if (model.docId == null) {
                _showSnackBar('رقم الحركة غير موجود', Colors.red);
                return;
              }

              final deleted = await _supplierService.deleteSupplierTransaction(
                widget.companyCode,
                model.docId!,
              );

              if (deleted) {
                _showSnackBar('تم حذف الفاتورة بنجاح', Colors.green);
                await _loadData();
              } else {
                _showSnackBar('فشل حذف الفاتورة', Colors.red);
              }
            },
            child: const Text('حذف', style: TextStyle(color: Colors.red, fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // التصدير العام
  // ==========================================================

  Future<void> _exportExcel() async {
    if (_transactions.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', Colors.orange);
      return;
    }

    try {
      final companyName = await _getCompanyName();
      final branchName = _isAllBranches ? 'كل الفروع' : _getBranchName(widget.selectedBranchCode);
      final period = '${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}';

      final data = _transactions.map((t) => {
        'رقم الإذن': t.serial,
        'التاريخ': t.date,
        'الفرع': _getBranchName(t.branchCode),
        'المورد': t.supplierName,
        'المخزن': _getStoreName(t.storeCode),
        'إجمالي الفاتورة': t.totalAmount,
        'عدد الأصناف': t.items.length,
        'إضافة للمخزن': t.isAddToStore ? 'نعم' : 'لا',
        'الموظف': t.employee,
      }).toList();

      const headers = [
        'رقم الإذن',
        'التاريخ',
        'الفرع',
        'المورد',
        'المخزن',
        'إجمالي الفاتورة',
        'عدد الأصناف',
        'إضافة للمخزن',
        'الموظف',
      ];

      await ExportService.exportToExcel(
        data,
        'تقرير المشتريات',
        headers,
        headers,
        companyName: companyName,
        branchName: branchName,
        period: period,
        supplierName: _selectedSupplierCode == 'all' ? null : _getSupplierName(_selectedSupplierCode),
        summary: {
          'إجمالي المشتريات': _totalPurchases,
          'إجمالي الدفعات': _totalSettlements,
          'المتبقي': _supplierRemaining,
        },
      );

      _showSnackBar('تم تصدير Excel بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
    }
  }

  Future<void> _exportPDF() async {
    if (_transactions.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', Colors.orange);
      return;
    }

    try {
      final companyName = await _getCompanyName();
      final branchName = _isAllBranches ? 'كل الفروع' : _getBranchName(widget.selectedBranchCode);
      final period = '${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}';

      final data = _transactions.map((t) => {
        'رقم الإذن': t.serial,
        'التاريخ': t.date,
        'الفرع': _getBranchName(t.branchCode),
        'المورد': t.supplierName,
        'المخزن': _getStoreName(t.storeCode),
        'إجمالي الفاتورة': t.totalAmount,
        'عدد الأصناف': t.items.length,
        'إضافة للمخزن': t.isAddToStore ? 'نعم' : 'لا',
        'الموظف': t.employee,
      }).toList();

      const headers = [
        'رقم الإذن',
        'التاريخ',
        'الفرع',
        'المورد',
        'المخزن',
        'إجمالي الفاتورة',
        'عدد الأصناف',
        'إضافة للمخزن',
        'الموظف',
      ];

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير المشتريات',
        headers: headers,
        keys: headers,
        companyName: companyName,
        branchName: branchName,
        period: period,
        supplierName: _selectedSupplierCode == 'all' ? null : _getSupplierName(_selectedSupplierCode),
        summary: {
          'totalAmount': _totalPurchases,
          'إجمالي الدفعات': _totalSettlements,
          'المتبقي': _supplierRemaining,
        },
        totalAmount: _totalPurchases,
      );

      _showSnackBar('تم تصدير PDF بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
    }
  }

  String? _getSupplierName(String? code) {
    if (code == null || code == 'all') return null;

    final found = _suppliers.firstWhere(
      (s) => s['code'] == code,
      orElse: () => {},
    );

    return found['name'];
  }

  // ==========================================================
  // تصدير إذن واحد
  // ==========================================================

  Future<void> _exportSingleExcel(SupplierTransactionModel inv) async {
    try {
      final companyName = await _getCompanyName();
      final branchName = _getBranchName(inv.branchCode);

      final data = inv.items.map((item) => {
        'الكود': item.code,
        'الصنف': item.name,
        'الكمية': item.quantity,
        'السعر': item.price,
        'نسبة الخصم': item.discountRate,
        'مبلغ الخصم': item.discountAmount,
        'الإجمالي': item.total,
      }).toList();

      const headers = [
        'الكود',
        'الصنف',
        'الكمية',
        'السعر',
        'نسبة الخصم',
        'مبلغ الخصم',
        'الإجمالي',
      ];

      final totalQuantity = inv.items.fold<double>(0.0, (sum, item) => sum + item.quantity);

      await ExportService.exportToExcel(
        data,
        'حركة_مورد_${inv.serial}_${inv.date}',
        headers,
        headers,
        companyName: companyName,
        branchName: branchName,
        storeName: _getStoreName(inv.storeCode),
        serial: inv.serial.toString(),
        date: inv.date,
        supplierName: inv.supplierName,
        employee: inv.employee,
        summary: {
          'إجمالي الكمية': totalQuantity,
          'إجمالي المشتريات': inv.totalAmount,
        },
      );

      _showSnackBar('تم تصدير الإذن بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
    }
  }

  Future<void> _exportSinglePDF(SupplierTransactionModel inv) async {
    try {
      final companyName = await _getCompanyName();
      final branchName = _getBranchName(inv.branchCode);

      final data = inv.items.map((item) => {
        'الكود': item.code,
        'الصنف': item.name,
        'الكمية': item.quantity,
        'السعر': item.price,
        'نسبة الخصم': item.discountRate,
        'مبلغ الخصم': item.discountAmount,
        'الإجمالي': item.total,
      }).toList();

      const headers = [
        'الكود',
        'الصنف',
        'الكمية',
        'السعر',
        'نسبة الخصم',
        'مبلغ الخصم',
        'الإجمالي',
      ];

      final totalQuantity = inv.items.fold<double>(0.0, (sum, item) => sum + item.quantity);

      await ExportService.exportToPDF(
        data: data,
        title: 'حركة مورد - ${inv.supplierName}',
        headers: headers,
        keys: headers,
        companyName: companyName,
        branchName: branchName,
        storeName: _getStoreName(inv.storeCode),
        serial: inv.serial.toString(),
        date: inv.date,
        supplierName: inv.supplierName,
        employee: inv.employee,
        summary: {
          'totalQuantity': totalQuantity,
          'totalAmount': inv.totalAmount,
        },
        totalAmount: inv.totalAmount,
      );

      _showSnackBar('تم تصدير الإذن بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
    }
  }

  // ==========================================================
  // SnackBar
  // ==========================================================

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

  // ==========================================================
  // Build
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canViewSupplierHistory) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'معاينة المشتريات',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'Cairo',
            ),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.black, Color(0xFF1A237E), Colors.black],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Text(
              'ليس لديك صلاحية لعرض المشتريات',
              style: TextStyle(
                color: Colors.white70,
                fontFamily: 'Cairo',
                fontSize: 16,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showDetails ? 'تفاصيل الحركة' : 'معاينة المشتريات',
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'Cairo',
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: _showDetails ? _goBackToList : () => Navigator.pop(context),
        ),
        actions: [
          if (!_showDetails && PermissionsService().canExportSupplier)
            IconButton(
              icon: const Icon(Icons.download, color: Colors.blueAccent),
              onPressed: _exportExcel,
              tooltip: 'تصدير Excel',
            ),
          if (!_showDetails && PermissionsService().canExportSupplier)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
              onPressed: _exportPDF,
              tooltip: 'تصدير PDF',
            ),
          if (!_showDetails)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed: () async {
                setState(() => _isLoading = true);

                try {
                  await _supplierService.syncChangesFromServer(widget.companyCode);
                  await _loadData();
                } catch (e) {
                  _showSnackBar('فشل التحديث: $e', Colors.red);
                } finally {
                  if (mounted) setState(() => _isLoading = false);
                }
              },
              tooltip: 'تحديث من السيرفر',
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Color(0xFF1A237E), Colors.black],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _showDetails && _selectedTransaction != null
                  ? _buildDetailsView(_selectedTransaction!)
                  : _buildListView(),
        ),
      ),
    );
  }

  // ==========================================================
  // القائمة
  // ==========================================================

  Widget _buildListView() {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return Column(
      children: [
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: isMobile
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        SizedBox(width: 130, child: _buildSupplierFilter()),
                        const SizedBox(width: 6),
                        SizedBox(width: 130, child: _buildStoreFilter()),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 110,
                          child: _buildDatePicker(
                            label: 'من',
                            date: _fromDate,
                            onChanged: (d) {
                              if (d == null) return;
                              setState(() => _fromDate = d);
                              _loadData();
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 110,
                          child: _buildDatePicker(
                            label: 'إلى',
                            date: _toDate,
                            onChanged: (d) {
                              if (d == null) return;
                              setState(() => _toDate = d);
                              _loadData();
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white70, size: 18),
                          onPressed: _clearFilters,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  )
                : Row(
                    children: [
                      Expanded(child: _buildSupplierFilter()),
                      const SizedBox(width: 12),
                      Expanded(child: _buildStoreFilter()),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildDatePicker(
                          label: 'من',
                          date: _fromDate,
                          onChanged: (d) {
                            if (d == null) return;
                            setState(() => _fromDate = d);
                            _loadData();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildDatePicker(
                          label: 'إلى',
                          date: _toDate,
                          onChanged: (d) {
                            if (d == null) return;
                            setState(() => _toDate = d);
                            _loadData();
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white70),
                        onPressed: _clearFilters,
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),
        _buildPeriodSummary(),
        const SizedBox(height: 6),
        Expanded(
          child: _transactions.isEmpty
              ? const Center(
                  child: Text(
                    'لا توجد مشتريات',
                    style: TextStyle(
                      color: Colors.white70,
                      fontFamily: 'Cairo',
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _transactions.length,
                  itemBuilder: (c, i) => _buildTransactionCard(_transactions[i]),
                ),
        ),
      ],
    );
  }

  // ==========================================================
  // إجماليات الفترة
  // ==========================================================

  Widget _buildPeriodSummary() {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(
              child: _buildSummaryBox(
                'إجمالي المشتريات',
                _formatCurrency(_totalPurchases),
                Colors.greenAccent,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _buildSummaryBox(
                'إجمالي الدفعات',
                _formatCurrency(_totalSettlements),
                Colors.redAccent,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _buildSummaryBox(
                'المتبقي',
                _formatCurrency(_supplierRemaining),
                _supplierRemaining >= 0 ? Colors.cyanAccent : Colors.orangeAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 9,
              fontFamily: 'Cairo',
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // بطاقة الفاتورة
  // ==========================================================

  Widget _buildTransactionCard(SupplierTransactionModel t) {
    return Card(
      color: Colors.white.withOpacity(0.05),
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showTransactionDetails(t),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.cyanAccent.withOpacity(0.15),
                    child: Text(
                      '${t.serial}',
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.supplierName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'إذن رقم: ${t.serial}',
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 10,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'التاريخ: ${t.date}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 10,
                          ),
                        ),
                        Text(
                          'الفرع: ${_getBranchName(t.branchCode)}',
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 10,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'الموظف: ${t.employee.isEmpty ? 'غير محدد' : t.employee}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: t.isAddToStore ? Colors.greenAccent.withOpacity(0.15) : Colors.grey.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: t.isAddToStore ? Colors.greenAccent.withOpacity(0.3) : Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: Text(
                      t.isAddToStore ? 'مضاف للمخزن' : 'بدون إضافة',
                      style: TextStyle(
                        color: t.isAddToStore ? Colors.greenAccent : Colors.grey,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildInfoChip('المخزن', _getStoreName(t.storeCode), Colors.blueAccent, false),
                  _buildInfoChip('الإجمالي', _formatCurrency(t.totalAmount), Colors.greenAccent, false),
                  _buildInfoChip('الأصناف', t.items.length.toString(), Colors.orange, false),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (PermissionsService().canEditSupplierTransaction)
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.orange, size: 18),
                      onPressed: () => _editTransaction(t),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  if (PermissionsService().canDeleteSupplierTransaction)
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                      onPressed: () => _confirmDelete(t),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios, color: Colors.cyanAccent, size: 16),
                    onPressed: () => _showTransactionDetails(t),
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

  // ==========================================================
  // Info Chip
  // ==========================================================

  Widget _buildInfoChip(String label, String value, Color color, bool isMobile) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.15), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: Colors.white60, fontSize: isMobile ? 8 : 10)),
          const SizedBox(width: 4),
          Text(value, style: TextStyle(color: color, fontSize: isMobile ? 9 : 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ==========================================================
  // فلتر المورد
  // ==========================================================

  Widget _buildSupplierFilter() {
    return DropdownButtonFormField<String?>(
      value: _selectedSupplierCode,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: const InputDecoration(
        labelText: 'المورد',
        labelStyle: TextStyle(color: Colors.white70, fontSize: 10),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
      ),
      items: _suppliers.map(
        (s) => DropdownMenuItem<String?>(
          value: s['code'],
          child: Text(s['name'] ?? '', style: const TextStyle(fontSize: 10)),
        ),
      ).toList(),
      onChanged: (val) {
        setState(() => _selectedSupplierCode = val ?? 'all');
        _loadData();
      },
    );
  }

  // ==========================================================
  // فلتر المخزن
  // ==========================================================

  Widget _buildStoreFilter() {
    return DropdownButtonFormField<String?>(
      value: _filterStore,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: const InputDecoration(
        labelText: 'المخزن',
        labelStyle: TextStyle(color: Colors.white70, fontSize: 10),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
      ),
      items: _stores.map(
        (s) => DropdownMenuItem<String?>(
          value: s['code'],
          child: Text(s['name'] ?? '', style: const TextStyle(fontSize: 10)),
        ),
      ).toList(),
      onChanged: (val) {
        setState(() => _filterStore = val ?? 'all');
        _loadData();
      },
    );
  }

  // ==========================================================
  // التاريخ
  // ==========================================================

  Widget _buildDatePicker({
    required String label,
    required DateTime date,
    required Function(DateTime?) onChanged,
  }) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(2020),
          lastDate: DateTime(2101),
        );

        if (picked != null) onChanged(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label: ', style: const TextStyle(color: Colors.white60, fontSize: 10)),
            const SizedBox(width: 4),
            Text(
              DateFormat('yyyy-MM-dd').format(date),
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
            const Icon(Icons.calendar_today, color: Colors.amber, size: 12),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // إعادة الفلاتر
  // ==========================================================

  void _clearFilters() {
    setState(() {
      _selectedSupplierCode = 'all';
      _filterStore = 'all';
      _fromDate = DateTime.now().subtract(const Duration(days: 30));
      _toDate = DateTime.now();
    });

    _loadData();
  }

  // ==========================================================
  // تفاصيل الفاتورة
  // ==========================================================

  Widget _buildDetailsView(SupplierTransactionModel t) {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'إذن رقم ${t.serial}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'المورد: ${t.supplierName}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'الفرع: ${_getBranchName(t.branchCode)}',
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 12,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'المخزن: ${_getStoreName(t.storeCode)}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'التاريخ: ${t.date}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              'الموظف: ${t.employee.isEmpty ? 'غير محدد' : t.employee}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                                fontFamily: 'Cairo',
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: t.isAddToStore ? Colors.greenAccent.withOpacity(0.15) : Colors.grey.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: t.isAddToStore ? Colors.greenAccent.withOpacity(0.3) : Colors.grey.withOpacity(0.3),
                          ),
                        ),
                        child: Text(
                          t.isAddToStore ? 'مضاف للمخزن' : 'بدون إضافة',
                          style: TextStyle(
                            color: t.isAddToStore ? Colors.greenAccent : Colors.grey,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24, height: 16),
                  Row(
                    children: [
                      Expanded(child: _buildDetailItem('المخزن', _getStoreName(t.storeCode), Icons.store)),
                      Expanded(child: _buildDetailItem('الإجمالي', _formatCurrency(t.totalAmount), Icons.attach_money, color: Colors.greenAccent)),
                      Expanded(child: _buildDetailItem('عدد الأصناف', t.items.length.toString(), Icons.list_alt, color: Colors.blueAccent)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (PermissionsService().canEditSupplierTransaction)
                        TextButton.icon(
                          onPressed: () => _editTransaction(t),
                          icon: const Icon(Icons.edit, color: Colors.orange, size: 16),
                          label: const Text('تعديل', style: TextStyle(color: Colors.orange, fontSize: 12, fontFamily: 'Cairo')),
                        ),
                      if (PermissionsService().canDeleteSupplierTransaction)
                        TextButton.icon(
                          onPressed: () => _confirmDelete(t),
                          icon: const Icon(Icons.delete, color: Colors.red, size: 16),
                          label: const Text('حذف', style: TextStyle(color: Colors.red, fontSize: 12, fontFamily: 'Cairo')),
                        ),
                      if (PermissionsService().canExportSupplier)
                        TextButton.icon(
                          onPressed: () => _exportSingleExcel(t),
                          icon: const Icon(Icons.download, color: Colors.blueAccent, size: 16),
                          label: const Text('Excel', style: TextStyle(color: Colors.blueAccent, fontSize: 12)),
                        ),
                      if (PermissionsService().canExportSupplier)
                        TextButton.icon(
                          onPressed: () => _exportSinglePDF(t),
                          icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent, size: 16),
                          label: const Text('PDF', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
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
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: isMobile ? _buildMobileItemsTable(t) : _buildDesktopItemsTable(t),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text(
                        'إجمالي الكميات',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                          fontFamily: 'Cairo',
                        ),
                      ),
                      Text(
                        t.items.fold<double>(0.0, (sum, i) => sum + i.quantity).toStringAsFixed(0),
                        style: const TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Container(width: 1, height: 30, color: Colors.white24),
                  Column(
                    children: [
                      const Text(
                        'إجمالي المشتريات',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                          fontFamily: 'Cairo',
                        ),
                      ),
                      Text(
                        _formatCurrency(t.totalAmount),
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // جدول الأصناف للموبايل
  // ==========================================================

  Widget _buildMobileItemsTable(SupplierTransactionModel t) {
    const double colWidth = 55.0;
    const double nameWidth = 70.0;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _tableHeader('#', 30, Colors.cyan),
              _tableHeader('الكود', colWidth, Colors.cyan),
              _tableHeader('الصنف', nameWidth, Colors.cyan),
              _tableHeader('الكمية', colWidth, Colors.cyan),
              _tableHeader('السعر', colWidth, Colors.greenAccent),
              _tableHeader('الخصم%', colWidth, Colors.amber),
              _tableHeader('مبلغ الخصم', colWidth, Colors.amber),
              _tableHeader('الإجمالي', colWidth, Colors.greenAccent),
            ],
          ),
          const SizedBox(height: 4),
          ...t.items.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;

            return Row(
              children: [
                _tableCell('${index + 1}', 30, Colors.white54),
                _tableCell(item.code, colWidth, Colors.white70),
                _tableCell(item.name, nameWidth, Colors.white),
                _tableCell(item.quantity.toStringAsFixed(0), colWidth, Colors.white70),
                _tableCell(_formatCurrency(item.price), colWidth, Colors.greenAccent),
                _tableCell(item.discountRate.toStringAsFixed(1), colWidth, Colors.amber),
                _tableCell(_formatCurrency(item.discountAmount), colWidth, Colors.amber),
                _tableCell(_formatCurrency(item.total), colWidth, Colors.greenAccent),
              ],
            );
          }),
        ],
      ),
    );
  }

  // ==========================================================
  // جدول الأصناف لسطح المكتب
  // ==========================================================

  Widget _buildDesktopItemsTable(SupplierTransactionModel t) {
    return Column(
      children: [
        const Row(
          children: [
            Expanded(
              flex: 1,
              child: Text('#', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
            Expanded(
              flex: 1,
              child: Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
            Expanded(
              flex: 2,
              child: Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
            Expanded(
              flex: 1,
              child: Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
            Expanded(
              flex: 1,
              child: Text('السعر', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
            Expanded(
              flex: 1,
              child: Text('الخصم%', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
            Expanded(
              flex: 1,
              child: Text('مبلغ الخصم', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
            Expanded(
              flex: 1,
              child: Text('الإجمالي', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 9)),
            ),
          ],
        ),
        const Divider(color: Colors.white10),
        ...t.items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(flex: 1, child: _tableDesktopText('${index + 1}', Colors.white54)),
                Expanded(flex: 1, child: _tableDesktopText(item.code, Colors.white70)),
                Expanded(flex: 2, child: _tableDesktopText(item.name, Colors.white)),
                Expanded(flex: 1, child: _tableDesktopText(item.quantity.toStringAsFixed(0), Colors.white70)),
                Expanded(flex: 1, child: _tableDesktopText(_formatCurrency(item.price), Colors.greenAccent)),
                Expanded(flex: 1, child: _tableDesktopText(item.discountRate.toStringAsFixed(1), Colors.amber)),
                Expanded(flex: 1, child: _tableDesktopText(_formatCurrency(item.discountAmount), Colors.amber)),
                Expanded(flex: 1, child: _tableDesktopText(_formatCurrency(item.total), Colors.greenAccent)),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ==========================================================
  // Table helpers
  // ==========================================================

  Widget _tableHeader(String text, double width, Color color) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 8,
        ),
      ),
    );
  }

  Widget _tableCell(String text, double width, Color color) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Text(
          text,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 8),
        ),
      ),
    );
  }

  Widget _tableDesktopText(String text, Color color) {
    return Text(
      text,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 9),
    );
  }

  // ==========================================================
  // Detail item
  // ==========================================================

  Widget _buildDetailItem(
    String label,
    String value,
    IconData icon, {
    Color? color,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.cyanAccent, size: 14),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 9,
                  fontFamily: 'Cairo',
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: color ?? Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
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

  @override
  void dispose() {
    super.dispose();
  }
}