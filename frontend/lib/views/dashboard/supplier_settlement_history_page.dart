// lib/views/dashboard/supplier_settlement_history_page.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/supplier_settlement_model.dart';
import '../../services/supplier_service.dart';
import '../../services/supplier_settlement_service.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';
import '../../views/widgets/glass_card.dart';
import 'supplier_settlement_page.dart';

class SupplierSettlementHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;

  const SupplierSettlementHistoryPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
  });

  @override
  State<SupplierSettlementHistoryPage> createState() =>
      _SupplierSettlementHistoryPageState();
}

class _SupplierSettlementHistoryPageState
    extends State<SupplierSettlementHistoryPage> {
  final SupplierService _supplierService = SupplierService();
  final SupplierSettlementService _settlementService =
      SupplierSettlementService();

  List<Map<String, dynamic>> _allSettlements = [];
  List<Map<String, dynamic>> _filteredSettlements = [];
  List<String> _suppliers = [];

  String? _selectedSupplier;
  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();

  double _totalPurchases = 0.0;
  double _totalSettlements = 0.0;
  double _remainingBalance = 0.0;
  double _previousBalance = 0.0;
double _totalSupplierBalance = 0.0;

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // ============================================================
  // تحميل التسويات من Hive
  // ============================================================

  Future<void> _loadData() async {
    if (mounted) setState(() => _isLoading = true);

    try {
      final box = Hive.box('supplier_settlement_box');
      final List<Map<String, dynamic>> data = [];

      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! List) continue;

        for (final value in raw) {
          if (value is! Map) continue;

          final map = Map<String, dynamic>.from(value);

          if (map['is_deleted'] == true) continue;
          if (map['company_code']?.toString() != widget.companyCode) {
            continue;
          }

          if (widget.selectedBranchCode != null &&
              widget.selectedBranchCode != 'all' &&
              map['branch_code']?.toString() !=
                  widget.selectedBranchCode) {
            continue;
          }

          data.add(map);
        }
      }

      data.sort(
        (a, b) => (b['date']?.toString() ?? '')
            .compareTo(a['date']?.toString() ?? ''),
      );

      final supplierSet = <String>{};

      for (final item in data) {
        final name = item['supplier_name']?.toString().trim() ?? '';
        if (name.isNotEmpty) supplierSet.add(name);
      }

      _allSettlements = data;
      _suppliers = supplierSet.toList()..sort();

      await _applyFilters();

      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('❌ خطأ في تحميل معاينة التسويات: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ============================================================
  // الفلترة + حساب إجماليات الفترة
  // ============================================================

  Future<void> _applyFilters() async {
  final from = DateFormat('yyyy-MM-dd').format(_fromDate);
  final to = DateFormat('yyyy-MM-dd').format(_toDate);

  _filteredSettlements = _allSettlements.where((item) {
    final date = item['date']?.toString() ?? '';
    if (date.compareTo(from) < 0 || date.compareTo(to) > 0) return false;
    if (_selectedSupplier != null && _selectedSupplier!.isNotEmpty && item['supplier_name']?.toString() != _selectedSupplier) return false;
    return true;
  }).toList();

  await _calculatePeriodTotals(); // إعادة حساب الإجماليات بعد الفلترة

  if (mounted) setState(() {});
}

  // ============================================================
  // حساب:
  // المشتريات
  // الدفعات
  // المتبقي
  // ============================================================

  Future<void> _calculatePeriodTotals() async {
  try {
    final fromDateStr = DateFormat('yyyy-MM-dd').format(_fromDate);
    final toDateStr = DateFormat('yyyy-MM-dd').format(_toDate);

    final purchases = await _supplierService.getSupplierTransactions(
      companyCode: widget.companyCode,
      branchCode: widget.selectedBranchCode,
      supplierName: _selectedSupplier,
      startDate: fromDateStr,
      endDate: toDateStr,
    );

    double purchasesTotal = 0.0;
    for (final purchase in purchases) {
      purchasesTotal += purchase.totalAmount;
    }

    double settlementsTotal = 0.0;
    for (final item in _filteredSettlements) {
      settlementsTotal += _toDouble(item['amount']);
    }

    // الرصيد السابق (قبل تاريخ البداية)
    final previousPurchases = await _supplierService.getSupplierTransactions(
      companyCode: widget.companyCode,
      branchCode: widget.selectedBranchCode,
      supplierName: _selectedSupplier,
      startDate: null,
      endDate: DateFormat('yyyy-MM-dd').format(_fromDate.subtract(const Duration(days: 1))),
    );

    double prevPurchasesTotal = 0.0;
    for (final p in previousPurchases) {
      prevPurchasesTotal += p.totalAmount;
    }

    double prevSettlementsTotal = 0.0;
    final box = Hive.box('supplier_settlement_box');
    final beforeDate = DateFormat('yyyy-MM-dd').format(_fromDate.subtract(const Duration(days: 1)));

    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! List) continue;

      for (final item in raw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        if (map['company_code']?.toString() != widget.companyCode) continue;
        if (widget.selectedBranchCode != null && widget.selectedBranchCode != 'all' && map['branch_code']?.toString() != widget.selectedBranchCode) continue;
        if (_selectedSupplier != null && map['supplier_name']?.toString() != _selectedSupplier) continue;
        final date = map['date']?.toString() ?? '';
        if (date.compareTo(beforeDate) > 0) continue;
        prevSettlementsTotal += _toDouble(map['amount']);
      }
    }

    final previousBalance = prevPurchasesTotal - prevSettlementsTotal;
    final remaining = purchasesTotal - settlementsTotal;
    final totalBalance = previousBalance + remaining;

    _totalPurchases = purchasesTotal;
    _totalSettlements = settlementsTotal;
    _remainingBalance = remaining;
    _previousBalance = previousBalance;
    _totalSupplierBalance = totalBalance;

    if (mounted) setState(() {});
  } catch (e) {
    debugPrint('❌ خطأ في حساب إجماليات المورد: $e');
    _totalPurchases = 0.0;
    _totalSettlements = 0.0;
    _remainingBalance = 0.0;
    _previousBalance = 0.0;
    _totalSupplierBalance = 0.0;
  }
}

  double _toDouble(dynamic value) {
  double result;
  if (value is num) {
    result = value.toDouble();
  } else {
    result = double.tryParse(value?.toString() ?? '0') ?? 0.0;
  }
  // تصحيح الصفر السالب
  if (result.abs() < 0.0001) {
    result = 0.0;
  }
  return result;
}

  // ============================================================
  // اسم الخزينة
  // ============================================================

  String _getTreasuryName(String? codeOrName) {
    if (codeOrName == null || codeOrName.isEmpty) {
      return 'غير محدد';
    }

    final box = Hive.box('coding_box');
    final raw = box.get(
      '${widget.companyCode}_safes',
      defaultValue: [],
    );

    if (raw is List) {
      for (final item in raw) {
        if (item is Map &&
            (item['code']?.toString() == codeOrName ||
                item['name']?.toString() == codeOrName)) {
          return item['name']?.toString() ?? codeOrName;
        }
      }
    }

    return codeOrName;
  }

  // ============================================================
  // اسم الفرع
  // ============================================================

  String _getBranchName(String? codeOrName) {
    if (codeOrName == null ||
        codeOrName.isEmpty ||
        codeOrName == 'all') {
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
            (item['code']?.toString() == codeOrName ||
                item['name']?.toString() == codeOrName)) {
          return item['name']?.toString() ?? codeOrName;
        }
      }
    }

    return codeOrName;
  }

  // ============================================================
  // تنسيق المبلغ
  // ============================================================

  String _formatCurrency(dynamic value) {
  double numValue = _toDouble(value);
  // تصحيح الصفر السالب
  if (numValue.abs() < 0.0001) {
    numValue = 0.0;
  }
  return NumberFormat('#,##0.00', 'en_US').format(numValue);
}

  // ============================================================
  // اختيار التاريخ
  // ============================================================

  Future<void> _pickDate(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _fromDate : _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2101),
    );

    if (picked == null) return;

    setState(() {
      if (isFrom) {
        _fromDate = picked;
      } else {
        _toDate = picked;
      }
    });

    await _applyFilters();
  }

  // ============================================================
  // إعادة تعيين الفلاتر
  // ============================================================

  Future<void> _clearFilters() async {
    setState(() {
      _selectedSupplier = null;
      _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
      _toDate = DateTime.now();
    });

    await _applyFilters();
  }

  // ============================================================
  // إجمالي الدفعات
  // ============================================================

  double get _totalAmount => _totalSettlements;
  
  // ============================================================
  // تعديل التسوية
  // ============================================================

  Future<void> _editSettlement(
    Map<String, dynamic> item,
  ) async {
    final model = SupplierSettlementModel.fromMap(item);

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SupplierSettlementPage(
          companyCode: widget.companyCode,
          selectedBranchCode: widget.selectedBranchCode,
          userName: item['employee']?.toString(),
          editItem: model,
        ),
      ),
    );

    if (result == true) {
      await _loadData();
    }
  }

  // ============================================================
  // حذف التسوية
  // ============================================================

  Future<void> _deleteSettlement(
    Map<String, dynamic> item,
  ) async {
    final docId = item['doc_id']?.toString();

    if (docId == null || docId.isEmpty) {
      _showSnackBar(
        'رقم الحركة غير موجود',
        Colors.red,
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text(
          'تأكيد الحذف',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Cairo',
          ),
        ),
        content: Text(
          'هل تريد حذف الدفعة رقم ${item['serial'] ?? ''}؟',
          style: const TextStyle(
            color: Colors.white70,
            fontFamily: 'Cairo',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'إلغاء',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'حذف',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final success = await _settlementService.deleteSettlement(
      widget.companyCode,
      docId,
    );

    if (success) {
      _showSnackBar(
        'تم حذف الدفعة بنجاح',
        Colors.green,
      );
      await _loadData();
    } else {
      _showSnackBar(
        'فشل حذف الدفعة',
        Colors.red,
      );
    }
  }

  // ============================================================
  // تصدير Excel
  // ============================================================

  Future<void> _exportExcel() async {
    if (_filteredSettlements.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', Colors.orange);
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final companyName =
          prefs.getString('company_name') ?? 'شركتي';
      final branchName =
          _getBranchName(widget.selectedBranchCode);
      final period =
          '${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى '
          '${DateFormat('yyyy-MM-dd').format(_toDate)}';

      final data = _filteredSettlements.map((item) => {
            'رقم الإذن': item['serial'] ?? '',
            'التاريخ': item['date'] ?? '',
            'الفرع': _getBranchName(
              item['branch_code']?.toString(),
            ),
            'المورد': item['supplier_name'] ?? '',
            'طريقة الدفع': item['payment_method'] ?? '',
            'الخزينة': _getTreasuryName(
              item['treasury']?.toString(),
            ),
            'المبلغ': item['amount'] ?? 0,
            'البيان': item['statement'] ?? '',
            'الموظف': item['employee'] ?? 'غير محدد',
          }).toList();

      const headers = [
        'رقم الإذن',
        'التاريخ',
        'الفرع',
        'المورد',
        'طريقة الدفع',
        'الخزينة',
        'المبلغ',
        'البيان',
        'الموظف',
      ];

      await ExportService.exportToExcel(
        data,
        'تقرير تسويات الموردين',
        headers,
        headers,
        companyName: companyName,
        branchName: branchName,
        period: period,
        supplierName: _selectedSupplier,
        summary: {
          'إجمالي المشتريات': _totalPurchases,
          'إجمالي الدفعات': _totalSettlements,
          'المتبقي': _remainingBalance,
        },
      );

      _showSnackBar(
        'تم تصدير Excel بنجاح',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'فشل تصدير Excel: $e',
        Colors.red,
      );
    }
  }

  // ============================================================
  // تصدير PDF
  // ============================================================

  Future<void> _exportPDF() async {
    if (_filteredSettlements.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', Colors.orange);
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final companyName =
          prefs.getString('company_name') ?? 'شركتي';
      final branchName =
          _getBranchName(widget.selectedBranchCode);
      final period =
          '${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى '
          '${DateFormat('yyyy-MM-dd').format(_toDate)}';

      final data = _filteredSettlements.map((item) => {
            'رقم الإذن': item['serial'] ?? '',
            'التاريخ': item['date'] ?? '',
            'الفرع': _getBranchName(
              item['branch_code']?.toString(),
            ),
            'المورد': item['supplier_name'] ?? '',
            'طريقة الدفع': item['payment_method'] ?? '',
            'الخزينة': _getTreasuryName(
              item['treasury']?.toString(),
            ),
            'المبلغ': item['amount'] ?? 0,
            'البيان': item['statement'] ?? '',
            'الموظف': item['employee'] ?? 'غير محدد',
          }).toList();

      const headers = [
        'رقم الإذن',
        'التاريخ',
        'الفرع',
        'المورد',
        'طريقة الدفع',
        'الخزينة',
        'المبلغ',
        'البيان',
        'الموظف',
      ];

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير تسويات الموردين',
        headers: headers,
        keys: headers,
        companyName: companyName,
        branchName: branchName,
        period: period,
        supplierName: _selectedSupplier,
        summary: {
          'totalPurchases': _totalPurchases,
          'totalAmount': _totalSettlements,
          'remainingBalance': _remainingBalance,
        },
        totalAmount: _totalSettlements,
      );

      _showSnackBar(
        'تم تصدير PDF بنجاح',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'فشل تصدير PDF: $e',
        Colors.red,
      );
    }
  }

  // ============================================================
  // SnackBar
  // ============================================================

  void _showSnackBar(
    String message,
    Color color,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: color,
      ),
    );
  }

  // ============================================================
  // بطاقة الإجماليات
  // ============================================================

  Widget _buildTotalsCard() {
  // قائمة العناصر الخمسة
  final items = [
    _buildTotalItem('الرصيد السابق', _previousBalance, Colors.blueAccent),
    _buildTotalItem('مشتريات الفترة', _totalPurchases, Colors.cyanAccent),
    _buildTotalItem('دفعات الفترة', _totalSettlements, Colors.redAccent),
    _buildTotalItem('المتبقي', _remainingBalance, Colors.greenAccent),
    _buildTotalItem('إجمالي رصيد المورد', _totalSupplierBalance, Colors.purpleAccent),
  ];

  // على الشاشات الصغيرة: 3 في السطر الأول و 2 في الثاني
  final firstRowItems = [items[1], items[2], items[3]]; // مشتريات, دفعات, المتبقي
  final secondRowItems = [items[0], items[4]]; // الرصيد السابق, إجمالي رصيد المورد

  return GlassCard(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Column(
        children: [
          // السطر الأول (3 عناصر)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: firstRowItems.map((item) => Expanded(child: item)).toList(),
          ),
          const SizedBox(height: 8),
          // السطر الثاني (2 عناصر)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: secondRowItems.map((item) => Expanded(child: item)).toList(),
          ),
        ],
      ),
    ),
  );
}

  Widget _buildTotalItem(String title, double value, Color color) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        title,
        style: const TextStyle(
          color: Colors.white60,
          fontFamily: 'Cairo',
          fontSize: 10,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        _formatCurrency(value),
        style: TextStyle(
          color: color,
          fontSize: 15,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );
}

  // ============================================================
  // بطاقة الحركة
  // ============================================================

  Widget _buildSettlementCard(
    Map<String, dynamic> item,
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
        onTap: () => _showDetails(item),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 17,
                    backgroundColor:
                        Colors.amber.withOpacity(0.15),
                    child: Text(
                      '${item['serial'] ?? ''}',
                      style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
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
                          item['supplier_name']?.toString() ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'إذن رقم: ${item['serial'] ?? ''}',
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 10,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'التاريخ: ${item['date'] ?? ''}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 10,
                          ),
                        ),
                        Text(
                          'الفرع: ${_getBranchName(item['branch_code']?.toString())}',
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 10,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          'الموظف: ${item['employee']?.toString() ?? 'غير محدد'}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _formatCurrency(item['amount']),
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceAround,
                children: [
                  _infoChip(
                    'الخزينة',
                    _getTreasuryName(
                      item['treasury']?.toString(),
                    ),
                    Colors.blueAccent,
                  ),
                  _infoChip(
                    'طريقة الدفع',
                    item['payment_method']?.toString() ?? '',
                    Colors.cyanAccent,
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // ✅ أزرار التعديل والحذف حسب الصلاحيات
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (PermissionsService()
                      .canEditSupplierSettlement)
                    TextButton.icon(
                      onPressed: () => _editSettlement(item),
                      icon: const Icon(
                        Icons.edit,
                        color: Colors.amber,
                        size: 18,
                      ),
                      label: const Text(
                        'تعديل',
                        style: TextStyle(
                          color: Colors.amber,
                          fontFamily: 'Cairo',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  if (PermissionsService()
                      .canDeleteSupplierSettlement)
                    TextButton.icon(
                      onPressed: () => _deleteSettlement(item),
                      icon: const Icon(
                        Icons.delete,
                        color: Colors.redAccent,
                        size: 18,
                      ),
                      label: const Text(
                        'حذف',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontFamily: 'Cairo',
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoChip(
    String label,
    String value,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: color.withOpacity(0.2),
        ),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontSize: 10,
        ),
      ),
    );
  }

  // ============================================================
  // تفاصيل الدفعة
  // ============================================================

  void _showDetails(
    Map<String, dynamic> item,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text(
          'تفاصيل الدفعة',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Cairo',
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailText('رقم الإذن', '${item['serial'] ?? ''}'),
            _detailText('التاريخ', '${item['date'] ?? ''}'),
            _detailText(
              'الفرع',
              _getBranchName(item['branch_code']?.toString()),
            ),
            _detailText(
              'المورد',
              '${item['supplier_name'] ?? ''}',
            ),
            _detailText(
              'المبلغ',
              _formatCurrency(item['amount']),
            ),
            _detailText(
              'طريقة الدفع',
              '${item['payment_method'] ?? ''}',
            ),
            _detailText(
              'الخزينة',
              _getTreasuryName(
                item['treasury']?.toString(),
              ),
            ),
            _detailText(
              'البيان',
              '${item['statement'] ?? ''}',
            ),
            _detailText(
              'الموظف',
              '${item['employee'] ?? 'غير محدد'}',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'إغلاق',
              style: TextStyle(
                color: Colors.cyanAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailText(
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: Colors.white54,
                fontFamily: 'Cairo',
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'Cairo',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // Build
  // ============================================================

  @override
Widget build(BuildContext context) {
  if (!PermissionsService().canShowSupplierSettlements) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'معاينة التسويات',
          style: TextStyle(color: Colors.white, fontFamily: 'Cairo'),
        ),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Color(0xFF1A237E), Colors.black],
          ),
        ),
        child: const Center(
          child: Text(
            'ليس لديك صلاحية لعرض التسويات',
            style: TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
          ),
        ),
      ),
    );
  }

  return Scaffold(
    appBar: AppBar(
      title: const Text(
        'معاينة تسويات الموردين',
        style: TextStyle(
          color: Colors.white,
          fontFamily: 'Cairo',
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      actions: [
        if (PermissionsService().canExportSupplierSettlement)
          IconButton(
            icon: const Icon(Icons.download, color: Colors.blueAccent),
            onPressed: _exportExcel,
          ),
        if (PermissionsService().canExportSupplierSettlement)
          IconButton(
            icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
            onPressed: _exportPDF,
          ),
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white),
          onPressed: _loadData,
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
            : CustomScrollView(
                slivers: [
                  // الفلاتر
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String?>(
                                      value: _selectedSupplier,
                                      dropdownColor: Colors.indigo.shade900,
                                      style: const TextStyle(color: Colors.white, fontSize: 12),
                                      decoration: const InputDecoration(
                                        labelText: 'المورد',
                                        labelStyle: TextStyle(color: Colors.white70, fontSize: 10),
                                        isDense: true,
                                      ),
                                      items: [
                                        const DropdownMenuItem<String?>(
                                          value: null,
                                          child: Text('كل الموردين'),
                                        ),
                                        ..._suppliers.map(
                                          (name) => DropdownMenuItem<String?>(
                                            value: name,
                                            child: Text(name),
                                          ),
                                        ),
                                      ],
                                      onChanged: (value) async {
                                        setState(() => _selectedSupplier = value);
                                        await _applyFilters();
                                      },
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.clear, color: Colors.white70),
                                    onPressed: _clearFilters,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: _dateButton('من', _fromDate, () => _pickDate(true)),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _dateButton('إلى', _toDate, () => _pickDate(false)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // الإجماليات
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: _buildTotalsCard(),
                    ),
                  ),
                  // قائمة التسويات
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        if (_filteredSettlements.isEmpty) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(20),
                              child: Text(
                                'لا توجد دفعات',
                                style: TextStyle(color: Colors.white60, fontFamily: 'Cairo'),
                              ),
                            ),
                          );
                        }
                        return _buildSettlementCard(_filteredSettlements[index]);
                      },
                      childCount: _filteredSettlements.isEmpty ? 1 : _filteredSettlements.length,
                    ),
                  ),
                  // إجمالي الدفعات في الأسفل
                  SliverToBoxAdapter(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        border: const Border(top: BorderSide(color: Colors.white24)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          const Text(
                            'إجمالي الدفعات',
                            style: TextStyle(
                              color: Colors.white60,
                              fontFamily: 'Cairo',
                            ),
                          ),
                          Text(
                            _formatCurrency(_totalAmount),
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    ),
  );
}

  // ============================================================
  // زر التاريخ
  // ============================================================

  Widget _dateButton(
    String label,
    DateTime date,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: Colors.white24,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$label: ',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 10,
              ),
            ),
            Text(
              DateFormat('yyyy-MM-dd').format(date),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.calendar_today,
              color: Colors.amber,
              size: 12,
            ),
          ],
        ),
      ),
    );
  }
}