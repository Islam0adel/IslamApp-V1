import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';

import '../../services/export_service.dart';

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


  List<Map<String, dynamic>> _allSettlements = [];
  List<Map<String, dynamic>> _filteredSettlements = [];

  List<String> _suppliers = [];

  String? _selectedSupplier;
  DateTime _fromDate =
      DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // ============================================================
  // تحميل الدفعات من Hive
  // ============================================================

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final box =
          Hive.box('supplier_settlement_box');

      final List<Map<String, dynamic>> data = [];

      for (final key in box.keys) {
        final raw = box.get(key);

        if (raw is! List) continue;

        for (final value in raw) {
          if (value is! Map) continue;

          final map =
              Map<String, dynamic>.from(value);

          if (map['is_deleted'] == true) continue;

          if (map['company_code']?.toString() !=
              widget.companyCode) {
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
        (a, b) =>
            (b['date']?.toString() ?? '')
                .compareTo(
              a['date']?.toString() ?? '',
            ),
      );

      final Set<String> supplierSet = {};

      for (final item in data) {
        final name =
            item['supplier_name']
                    ?.toString()
                    .trim() ??
                '';

        if (name.isNotEmpty) {
          supplierSet.add(name);
        }
      }

      _allSettlements = data;
      _suppliers = supplierSet.toList()..sort();

      _applyFilters();
    } catch (e) {
      debugPrint(
        '❌ خطأ في تحميل معاينة التسويات: $e',
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ============================================================
  // الفلترة
  // ============================================================

  void _applyFilters() {
    final from =
        DateFormat('yyyy-MM-dd').format(_fromDate);

    final to =
        DateFormat('yyyy-MM-dd').format(_toDate);

    _filteredSettlements =
        _allSettlements.where((item) {
      final date =
          item['date']?.toString() ?? '';

      if (date.compareTo(from) < 0 ||
          date.compareTo(to) > 0) {
        return false;
      }

      if (_selectedSupplier != null &&
          _selectedSupplier!.isNotEmpty &&
          item['supplier_name']?.toString() !=
              _selectedSupplier) {
        return false;
      }

      return true;
    }).toList();

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // اسم الخزينة
  // ============================================================

  String _getTreasuryName(String? codeOrName) {
    if (codeOrName == null ||
        codeOrName.isEmpty) {
      return 'غير محدد';
    }

    final box =
        Hive.box('coding_box');

    final raw =
        box.get(
              '${widget.companyCode}_safes',
              defaultValue: [],
            );

    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          if (item['code']?.toString() ==
                  codeOrName ||
              item['name']?.toString() ==
                  codeOrName) {
            return item['name']
                    ?.toString() ??
                codeOrName;
          }
        }
      }
    }

    return codeOrName;
  }

  // ============================================================
  // تنسيق المبلغ
  // ============================================================

  String _formatCurrency(dynamic value) {
    final amount = value is num
        ? value.toDouble()
        : double.tryParse(
              value?.toString() ?? '0',
            ) ??
            0.0;

    return NumberFormat(
      '#,##0.00',
      'en_US',
    ).format(amount);
  }

  // ============================================================
  // اختيار التاريخ
  // ============================================================

  Future<void> _pickDate(
    bool isFrom,
  ) async {
    final picked = await showDatePicker(
      context: context,
      initialDate:
          isFrom ? _fromDate : _toDate,
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

    _applyFilters();
  }

  // ============================================================
  // إعادة تعيين الفلاتر
  // ============================================================

  void _clearFilters() {
    setState(() {
      _selectedSupplier = null;
      _fromDate =
          DateTime.now().subtract(
        const Duration(days: 30),
      );
      _toDate = DateTime.now();
    });

    _applyFilters();
  }

  // ============================================================
  // إجمالي الدفعات
  // ============================================================

  double get _totalAmount {
    return _filteredSettlements.fold(
      0.0,
      (sum, item) =>
          sum +
          (item['amount'] is num
              ? (item['amount'] as num).toDouble()
              : double.tryParse(
                    item['amount']
                            ?.toString() ??
                        '0',
                  ) ??
                  0.0),
    );
  }

  // ============================================================
  // تصدير Excel
  // ============================================================

  Future<void> _exportExcel() async {
    if (_filteredSettlements.isEmpty) {
      _showSnackBar(
        'لا توجد بيانات للتصدير',
        Colors.orange,
      );
      return;
    }

    try {
      final data =
          _filteredSettlements.map((item) {
        return {
          'رقم الدفعة':
              item['serial'] ?? '',
          'التاريخ':
              item['date'] ?? '',
          'المورد':
              item['supplier_name'] ?? '',
          'طريقة الدفع':
              item['payment_method'] ?? '',
          'الخزينة':
              _getTreasuryName(
            item['treasury']?.toString(),
          ),
          'المبلغ':
              item['amount'] ?? 0,
          'البيان':
              item['statement'] ?? '',
          'الموظف':
              item['employee'] ?? '',
        };
      }).toList();

      const headers = [
        'رقم الدفعة',
        'التاريخ',
        'المورد',
        'طريقة الدفع',
        'الخزينة',
        'المبلغ',
        'البيان',
        'الموظف',
      ];

      await ExportService.exportToExcel(
        data,
        'تسويات_الموردين_${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
        headers,
        headers,
      );

      _showSnackBar(
        'تم التصدير بنجاح',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'فشل التصدير: $e',
        Colors.red,
      );
    }
  }

  // ============================================================
  // تصدير PDF
  // ============================================================

  Future<void> _exportPDF() async {
    if (_filteredSettlements.isEmpty) {
      _showSnackBar(
        'لا توجد بيانات للتصدير',
        Colors.orange,
      );
      return;
    }

    try {
      final data =
          _filteredSettlements.map((item) {
        return {
          'رقم الدفعة':
              item['serial'] ?? '',
          'التاريخ':
              item['date'] ?? '',
          'المورد':
              item['supplier_name'] ?? '',
          'طريقة الدفع':
              item['payment_method'] ?? '',
          'الخزينة':
              _getTreasuryName(
            item['treasury']?.toString(),
          ),
          'المبلغ':
              item['amount'] ?? 0,
          'البيان':
              item['statement'] ?? '',
        };
      }).toList();

      const headers = [
        'رقم الدفعة',
        'التاريخ',
        'المورد',
        'طريقة الدفع',
        'الخزينة',
        'المبلغ',
        'البيان',
      ];

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير تسويات الموردين',
        headers: headers,
        keys: headers,
        summary: {
          'totalAmount': _totalAmount,
        },
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
    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Cairo',
          ),
        ),
        backgroundColor: color,
      ),
    );
  }

  // ============================================================
  // بطاقة الحركة
  // ============================================================

  Widget _buildSettlementCard(
    Map<String, dynamic> item,
  ) {
    final amount =
        item['amount'] ?? 0;

    return Card(
      color:
          Colors.white.withOpacity(0.05),
      margin:
          const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 4,
      ),
      shape:
          RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(10),
      ),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(10),
        onTap: () =>
            _showDetails(item),
        child: Padding(
          padding:
              const EdgeInsets.all(10),
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 17,
                    backgroundColor:
                        Colors.amber
                            .withOpacity(0.15),
                    child: Text(
                      '${item['serial'] ?? ''}',
                      style:
                          const TextStyle(
                        color:
                            Colors.amber,
                        fontSize: 10,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          item['supplier_name']
                                  ?.toString() ??
                              '',
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                            fontSize: 14,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                        Text(
                          'التاريخ: ${item['date'] ?? ''}',
                          style:
                              const TextStyle(
                            color:
                                Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _formatCurrency(
                      amount,
                    ),
                    style:
                        const TextStyle(
                      color:
                          Colors.redAccent,
                      fontSize: 15,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 8,
              ),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .spaceAround,
                children: [
                  _infoChip(
                    'الخزينة',
                    _getTreasuryName(
                      item['treasury']
                          ?.toString(),
                    ),
                    Colors.blueAccent,
                  ),
                  _infoChip(
                    'طريقة الدفع',
                    item['payment_method']
                            ?.toString() ??
                        '',
                    Colors.cyanAccent,
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
      padding:
          const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 4,
      ),
      decoration:
          BoxDecoration(
        color:
            color.withOpacity(0.08),
        borderRadius:
            BorderRadius.circular(7),
        border: Border.all(
          color:
              color.withOpacity(0.2),
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
      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF0F172A),
          title: const Text(
            'تفاصيل الدفعة',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'Cairo',
            ),
          ),
          content: Column(
            mainAxisSize:
                MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment
                    .start,
            children: [
              _detailText(
                'رقم الدفعة',
                '${item['serial'] ?? ''}',
              ),
              _detailText(
                'التاريخ',
                '${item['date'] ?? ''}',
              ),
              _detailText(
                'المورد',
                '${item['supplier_name'] ?? ''}',
              ),
              _detailText(
                'المبلغ',
                _formatCurrency(
                  item['amount'],
                ),
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
                '${item['employee'] ?? ''}',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed:
                  () => Navigator.pop(
                context,
              ),
              child: const Text(
                'إغلاق',
                style:
                    TextStyle(
                  color:
                      Colors.cyanAccent,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _detailText(
    String label,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 4,
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style:
                  const TextStyle(
                color:
                    Colors.white54,
                fontFamily:
                    'Cairo',
              ),
            ),
            TextSpan(
              text: value,
              style:
                  const TextStyle(
                color:
                    Colors.white,
                fontFamily:
                    'Cairo',
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
  Widget build(
    BuildContext context,
  ) {
    if (!PermissionsService()
        .canShowSupplierSettlements) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'معاينة التسويات',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'Cairo',
            ),
          ),
          backgroundColor:
              Colors.transparent,
        ),
        body: Container(
          decoration:
              const BoxDecoration(
            gradient:
                LinearGradient(
              colors: [
                Colors.black,
                Color(0xFF1A237E),
                Colors.black,
              ],
            ),
          ),
          child:
              const Center(
            child: Text(
              'ليس لديك صلاحية لعرض التسويات',
              style:
                  TextStyle(
                color:
                    Colors.white70,
                fontFamily:
                    'Cairo',
              ),
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
            fontWeight:
                FontWeight.bold,
          ),
        ),
        backgroundColor:
            Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          if (PermissionsService()
              .canExportSupplierSettlement)
            IconButton(
              icon: const Icon(
                Icons.download,
                color:
                    Colors.blueAccent,
              ),
              onPressed:
                  _exportExcel,
            ),
          if (PermissionsService()
              .canExportSupplierSettlement)
            IconButton(
              icon: const Icon(
                Icons.picture_as_pdf,
                color:
                    Colors.redAccent,
              ),
              onPressed:
                  _exportPDF,
            ),
          IconButton(
            icon: const Icon(
              Icons.refresh,
              color: Colors.white,
            ),
            onPressed: _loadData,
          ),
        ],
      ),
      body: Container(
        decoration:
            const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.black,
              Color(0xFF1A237E),
              Colors.black,
            ],
            begin:
                Alignment.topLeft,
            end:
                Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              GlassCard(
                child: Padding(
                  padding:
                      const EdgeInsets.all(
                    8,
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child:
                                DropdownButtonFormField<
                                    String?>(
                              value:
                                  _selectedSupplier,
                              dropdownColor:
                                  Colors.indigo
                                      .shade900,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                                fontSize:
                                    12,
                              ),
                              decoration:
                                  const InputDecoration(
                                labelText:
                                    'المورد',
                                labelStyle:
                                    TextStyle(
                                  color:
                                      Colors.white70,
                                  fontSize:
                                      10,
                                ),
                                isDense:
                                    true,
                              ),
                              items: [
                                const DropdownMenuItem<
                                    String?>(
                                  value:
                                      null,
                                  child:
                                      Text(
                                    'كل الموردين',
                                  ),
                                ),
                                ..._suppliers
                                    .map(
                                  (
                                    name,
                                  ) =>
                                      DropdownMenuItem<
                                          String?>(
                                    value:
                                        name,
                                    child:
                                        Text(
                                      name,
                                    ),
                                  ),
                                ),
                              ],
                              onChanged:
                                  (value) {
                                setState(
                                  () =>
                                      _selectedSupplier =
                                          value,
                                );
                                _applyFilters();
                              },
                            ),
                          ),
                          IconButton(
                            icon:
                                const Icon(
                              Icons.clear,
                              color:
                                  Colors.white70,
                            ),
                            onPressed:
                                _clearFilters,
                          ),
                        ],
                      ),
                      const SizedBox(
                        height: 6,
                      ),
                      Row(
                        children: [
                          Expanded(
                            child:
                                _dateButton(
                              'من',
                              _fromDate,
                              () =>
                                  _pickDate(
                                true,
                              ),
                            ),
                          ),
                          const SizedBox(
                            width: 6,
                          ),
                          Expanded(
                            child:
                                _dateButton(
                              'إلى',
                              _toDate,
                              () =>
                                  _pickDate(
                                false,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(
                height: 6,
              ),
              Expanded(
                child:
                    _isLoading
                        ? const Center(
                            child:
                                CircularProgressIndicator(
                              color:
                                  Colors.white,
                            ),
                          )
                        : _filteredSettlements
                                .isEmpty
                            ? const Center(
                                child:
                                    Text(
                                  'لا توجد دفعات',
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.white60,
                                    fontFamily:
                                        'Cairo',
                                  ),
                                ),
                              )
                            : ListView.builder(
                                itemCount:
                                    _filteredSettlements
                                        .length,
                                itemBuilder:
                                    (context,
                                        index) =>
                                        _buildSettlementCard(
                                  _filteredSettlements[
                                      index],
                                ),
                              ),
              ),
              Container(
                padding:
                    const EdgeInsets.all(
                  12,
                ),
                decoration:
                    BoxDecoration(
                  color: Colors.white
                      .withOpacity(
                          0.05),
                  border:
                      const Border(
                    top:
                        BorderSide(
                      color:
                          Colors.white24,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment
                          .spaceAround,
                  children: [
                    const Text(
                      'إجمالي الدفعات',
                      style:
                          TextStyle(
                        color:
                            Colors.white60,
                        fontFamily:
                            'Cairo',
                      ),
                    ),
                    Text(
                      _formatCurrency(
                        _totalAmount,
                      ),
                      style:
                          const TextStyle(
                        color:
                            Colors.redAccent,
                        fontSize:
                            18,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateButton(
    String label,
    DateTime date,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 7,
        ),
        decoration:
            BoxDecoration(
          color: Colors.white
              .withOpacity(0.05),
          borderRadius:
              BorderRadius.circular(7),
          border: Border.all(
            color: Colors.white24,
          ),
        ),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment
                  .center,
          children: [
            Text(
              '$label: ',
              style:
                  const TextStyle(
                color:
                    Colors.white60,
                fontSize:
                    10,
              ),
            ),
            Text(
              DateFormat(
                'yyyy-MM-dd',
              ).format(date),
              style:
                  const TextStyle(
                color:
                    Colors.white,
                fontSize:
                    10,
              ),
            ),
            const SizedBox(
              width: 4,
            ),
            const Icon(
              Icons.calendar_today,
              color:
                  Colors.amber,
              size: 12,
            ),
          ],
        ),
      ),
    );
  }
}