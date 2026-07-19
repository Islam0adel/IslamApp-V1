// lib/views/dashboard/supplier_history_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/supplier_service.dart';
import '../../models/supplier_transaction_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';
import 'supplier_page.dart';

class SupplierHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;

  const SupplierHistoryPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
  });

  @override
  State<SupplierHistoryPage> createState() => _SupplierHistoryPageState();
}

class _SupplierHistoryPageState extends State<SupplierHistoryPage> {
  final SupplierService _supplierService = SupplierService();

  // البيانات
  List<SupplierTransactionModel> _transactions = [];
  bool _isLoading = true;

  // الفلاتر
  String? _filterSupplier;
  String? _filterStore;
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();

  // قوائم المنسدلة
  List<Map<String, String>> _suppliers = [];
  List<Map<String, String>> _stores = [];

  // متغيرات التفاصيل
  SupplierTransactionModel? _selectedTransaction;
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadDropdowns();
  }

  Future<void> _loadDropdowns() async {
    final box = Hive.box('coding_box');

    // تحميل الموردين (مع خيار الكل)
    _suppliers = [{'code': 'all', 'name': 'كل الموردين'}];
    var suppliers = box.get('${widget.companyCode}_suppliers') as List? ?? [];
    for (var item in suppliers) {
      _suppliers.add({'code': item['code'].toString(), 'name': item['name'].toString()});
    }

    // تحميل المخازن (مع خيار الكل)
    _stores = [{'code': 'all', 'name': 'كل المخازن'}];
    var stores = box.get('${widget.companyCode}_stores') as List? ?? [];
    for (var item in stores) {
      _stores.add({'code': item['code'].toString(), 'name': item['name'].toString()});
    }

    setState(() {});
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final transactions = await _supplierService.getSupplierTransactions(
        companyCode: widget.companyCode,
        branchCode: widget.selectedBranchCode,
        supplierName: _filterSupplier != null && _filterSupplier != 'all'
            ? _filterSupplier
            : null,
        startDate: DateFormat('yyyy-MM-dd').format(_fromDate),
        endDate: DateFormat('yyyy-MM-dd').format(_toDate),
      );

      // فلترة المخزن (إذا كان محدداً)
      List<SupplierTransactionModel> filtered = transactions;
      if (_filterStore != null && _filterStore != 'all') {
        filtered = filtered.where((t) => t.storeCode == _filterStore).toList();
      }

      setState(() {
        _transactions = filtered;
        _isLoading = false;
      });
    } catch (e) {
      print('خطأ في تحميل حركات الموردين: $e');
      setState(() => _isLoading = false);
    }
  }

  String _getStoreName(String? code) {
    if (code == null || code == 'all') return 'كل المخازن';
    final found = _stores.firstWhere((s) => s['code'] == code, orElse: () => {});
    return found['name'] ?? code;
  }

  String _getSupplierName(String? name) {
    return name ?? 'غير معروف';
  }

  String _formatCurrency(double amount) {
    return NumberFormat('#,##0.00', 'ar_EG').format(amount);
  }

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
          selectedBranchCode: widget.selectedBranchCode,
          // يمكن تمرير بيانات التعديل هنا
        ),
      ),
    ).then((_) => _loadData());
  }

  void _confirmDelete(SupplierTransactionModel model) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.indigo.shade900,
        title: const Text('تأكيد الحذف', style: TextStyle(color: Colors.white)),
        content: Text(
          'هل أنت متأكد من حذف حركة المورد رقم ${model.serial}؟',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (model.docId != null) {
                final deleted = await _supplierService.deleteSupplierTransaction(
                  widget.companyCode,
                  model.docId!,
                );
                if (deleted) {
                  _showSnackBar('تم الحذف بنجاح', Colors.green);
                  _loadData();
                } else {
                  _showSnackBar('فشل الحذف', Colors.red);
                }
              }
            },
            child: const Text('حذف', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ================== التصدير ==================

  Future<void> _exportExcel() async {
    if (_transactions.isEmpty) {
      _showSnackBar('لا توجد بيانات للتصدير', Colors.orange);
      return;
    }
    try {
      List<Map<String, dynamic>> data = _transactions.map((t) => {
        'رقم الإذن': t.serial,
        'التاريخ': t.date,
        'المورد': t.supplierName,
        'المخزن': _getStoreName(t.storeCode),
        'طريقة الدفع': t.paymentMethod,
        'الإجمالي': t.totalAmount,
        'المدفوع': t.paidAmount,
        'عدد الأصناف': t.items.length,
        'إضافة للمخزن': t.isAddToStore ? 'نعم' : 'لا',
      }).toList();

      await ExportService.exportToExcel(
        data,
        'حركات_الموردين_${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
        ['رقم الإذن', 'التاريخ', 'المورد', 'المخزن', 'طريقة الدفع', 'الإجمالي', 'المدفوع', 'عدد الأصناف', 'إضافة للمخزن'],
        ['رقم الإذن', 'التاريخ', 'المورد', 'المخزن', 'طريقة الدفع', 'الإجمالي', 'المدفوع', 'عدد الأصناف', 'إضافة للمخزن'],
      );
      _showSnackBar('تم التصدير بنجاح', Colors.green);
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
      List<Map<String, dynamic>> data = _transactions.map((t) => {
        'رقم الإذن': t.serial,
        'التاريخ': t.date,
        'المورد': t.supplierName,
        'المخزن': _getStoreName(t.storeCode),
        'طريقة الدفع': t.paymentMethod,
        'الإجمالي': t.totalAmount,
        'المدفوع': t.paidAmount,
        'عدد الأصناف': t.items.length,
        'إضافة للمخزن': t.isAddToStore ? 'نعم' : 'لا',
      }).toList();

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير حركات الموردين',
        headers: ['رقم الإذن', 'التاريخ', 'المورد', 'المخزن', 'طريقة الدفع', 'الإجمالي', 'المدفوع', 'عدد الأصناف', 'إضافة للمخزن'],
        keys: ['رقم الإذن', 'التاريخ', 'المورد', 'المخزن', 'طريقة الدفع', 'الإجمالي', 'المدفوع', 'عدد الأصناف', 'إضافة للمخزن'],
      );
      _showSnackBar('تم التصدير بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل تصدير PDF: $e', Colors.red);
    }
  }

  // ================== تصدير إذن واحد ==================

  Future<void> _exportSingleExcel(SupplierTransactionModel inv) async {
    try {
      List<Map<String, dynamic>> data = inv.items.map((item) => {
        'الكود': item.code,
        'الصنف': item.name,
        'الكمية': item.quantity,
        'السعر': item.price,
        'النوع': item.type,
        'نسبة الخصم': item.discountRate,
        'مبلغ الخصم': item.discountAmount,
        'الإجمالي': item.total,
      }).toList();

      await ExportService.exportToExcel(
        data,
        'حركة_مورد_${inv.serial}_${inv.date}',
        ['الكود', 'الصنف', 'الكمية', 'السعر', 'النوع', 'نسبة الخصم', 'مبلغ الخصم', 'الإجمالي'],
        ['الكود', 'الصنف', 'الكمية', 'السعر', 'النوع', 'نسبة الخصم', 'مبلغ الخصم', 'الإجمالي'],
      );
      _showSnackBar('تم تصدير الإذن بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل التصدير: $e', Colors.red);
    }
  }

  Future<void> _exportSinglePDF(SupplierTransactionModel inv) async {
    try {
      List<Map<String, dynamic>> data = inv.items.map((item) => {
        'الكود': item.code,
        'الصنف': item.name,
        'الكمية': item.quantity,
        'السعر': item.price,
        'النوع': item.type,
        'نسبة الخصم': item.discountRate,
        'مبلغ الخصم': item.discountAmount,
        'الإجمالي': item.total,
      }).toList();

      final summary = {
        'totalQuantity': inv.items.fold(0.0, (s, i) => s + i.quantity),
        'totalAmount': inv.totalAmount,
        'totalPaid': inv.paidAmount,
      };

      await ExportService.exportToPDF(
        data: data,
        title: 'حركة مورد - ${inv.supplierName}',
        headers: ['الكود', 'الصنف', 'الكمية', 'السعر', 'النوع', 'نسبة الخصم', 'مبلغ الخصم', 'الإجمالي'],
        keys: ['الكود', 'الصنف', 'الكمية', 'السعر', 'النوع', 'نسبة الخصم', 'مبلغ الخصم', 'الإجمالي'],
        summary: summary,
        serial: inv.serial.toString(),
        date: inv.date,
        branchName: 'الفرع ${inv.branchCode}',
        storeName: _getStoreName(inv.storeCode),
      );
      _showSnackBar('تم تصدير الإذن بنجاح', Colors.green);
    } catch (e) {
      _showSnackBar('فشل تصدير PDF: $e', Colors.red);
    }
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ================== البناء ==================

  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canViewSupplierHistory) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('معاينة حركات الموردين', style: TextStyle(color: Colors.white)),
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
              'ليس لديك صلاحية لعرض حركات الموردين',
              style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 16),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showDetails ? 'تفاصيل الحركة' : 'معاينة حركات الموردين',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(_showDetails ? Icons.arrow_back : Icons.arrow_back, color: Colors.white),
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
              onPressed: _loadData,
              tooltip: 'تحديث',
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

  // ================== عرض القائمة ==================

  Widget _buildListView() {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return Column(
      children: [
        // فلاتر
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: isMobile
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 130,
                          child: _buildSupplierFilter(),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 130,
                          child: _buildStoreFilter(),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 110,
                          child: _buildDatePicker(
                            label: 'من',
                            date: _fromDate,
                            onChanged: (d) {
                              setState(() => _fromDate = d!);
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
                              setState(() => _toDate = d!);
                              _loadData();
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white70, size: 18),
                          onPressed: () {
                            setState(() {
                              _filterSupplier = 'all';
                              _filterStore = 'all';
                              _fromDate = DateTime.now().subtract(const Duration(days: 30));
                              _toDate = DateTime.now();
                              _loadData();
                            });
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  )
                : Row(
                    children: [
                      Expanded(child: _buildSupplierFilter()),
                      const SizedBox(width: 8),
                      Expanded(child: _buildStoreFilter()),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildDatePicker(
                          label: 'من',
                          date: _fromDate,
                          onChanged: (d) {
                            setState(() => _fromDate = d!);
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
                            setState(() => _toDate = d!);
                            _loadData();
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white70),
                        onPressed: () {
                          setState(() {
                            _filterSupplier = 'all';
                            _filterStore = 'all';
                            _fromDate = DateTime.now().subtract(const Duration(days: 30));
                            _toDate = DateTime.now();
                            _loadData();
                          });
                        },
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),

        // قائمة الحركات
        Expanded(
          child: _transactions.isEmpty
              ? const Center(child: Text('لا توجد حركات', style: TextStyle(color: Colors.white70)))
              : ListView.builder(
                  itemCount: _transactions.length,
                  itemBuilder: (c, i) {
                    final t = _transactions[i];
                    return Card(
                      color: Colors.white.withOpacity(0.05),
                      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _showTransactionDetails(t),
                        child: Padding(
                          padding: const EdgeInsets.all(10.0),
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
                                      style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          t.supplierName,
                                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                        ),
                                        Text(
                                          'التاريخ: ${t.date}',
                                          style: const TextStyle(color: Colors.white60, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: t.isAddToStore
                                          ? Colors.greenAccent.withOpacity(0.15)
                                          : Colors.grey.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: t.isAddToStore
                                            ? Colors.greenAccent.withOpacity(0.3)
                                            : Colors.grey.withOpacity(0.3),
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
                                  _buildInfoChip('طريقة الدفع', t.paymentMethod, Colors.amber, false),
                                  _buildInfoChip('الإجمالي', _formatCurrency(t.totalAmount), Colors.greenAccent, false),
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
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildInfoChip(String label, String value, Color color, bool isMobile) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

  // ================== دوال الفلاتر ==================

  Widget _buildSupplierFilter() {
    return DropdownButtonFormField<String?>(
      value: _filterSupplier,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: const InputDecoration(
        labelText: 'المورد',
        labelStyle: TextStyle(color: Colors.white70, fontSize: 10),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        border: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.cyanAccent),
        ),
      ),
      items: _suppliers.map((s) {
        return DropdownMenuItem<String?>(
          value: s['code'],
          child: Text(s['name'] ?? '', style: const TextStyle(fontSize: 10)),
        );
      }).toList(),
      onChanged: (val) {
        setState(() {
          if (val == 'all') {
            _filterSupplier = null;
          } else {
            _filterSupplier = _suppliers.firstWhere((s) => s['code'] == val)['name'];
          }
          _loadData();
        });
      },
    );
  }

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
        border: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.cyanAccent),
        ),
      ),
      items: _stores.map((s) {
        return DropdownMenuItem<String?>(
          value: s['code'],
          child: Text(s['name'] ?? '', style: const TextStyle(fontSize: 10)),
        );
      }).toList(),
      onChanged: (val) {
        setState(() {
          _filterStore = val;
          _loadData();
        });
      },
    );
  }

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

  // ================== عرض التفاصيل ==================

  Widget _buildDetailsView(SupplierTransactionModel t) {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // بطاقة المعلومات
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
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            Text('المورد: ${t.supplierName}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                            Text('التاريخ: ${t.date}', style: const TextStyle(color: Colors.white60, fontSize: 13)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: t.isAddToStore
                              ? Colors.greenAccent.withOpacity(0.15)
                              : Colors.grey.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: t.isAddToStore
                                ? Colors.greenAccent.withOpacity(0.3)
                                : Colors.grey.withOpacity(0.3),
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
                      Expanded(child: _buildDetailItem('طريقة الدفع', t.paymentMethod, Icons.payment)),
                      Expanded(child: _buildDetailItem('الخزينة', t.treasury, Icons.account_balance_wallet)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDetailItem(
                          'الإجمالي',
                          _formatCurrency(t.totalAmount),
                          Icons.attach_money,
                          color: Colors.greenAccent,
                        ),
                      ),
                      Expanded(
                        child: _buildDetailItem(
                          'المدفوع',
                          _formatCurrency(t.paidAmount),
                          Icons.money_off,
                          color: Colors.amber,
                        ),
                      ),
                      Expanded(
                        child: _buildDetailItem(
                          'عدد الأصناف',
                          t.items.length.toString(),
                          Icons.list_alt,
                          color: Colors.blueAccent,
                        ),
                      ),
                    ],
                  ),
                  // أزرار التصدير
                  if (PermissionsService().canExportSupplier)
                    const SizedBox(height: 8),
                  if (PermissionsService().canExportSupplier)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => _exportSingleExcel(t),
                          icon: const Icon(Icons.download, color: Colors.blueAccent, size: 16),
                          label: const Text('Excel', style: TextStyle(color: Colors.blueAccent, fontSize: 12)),
                        ),
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

          // جدول الأصناف
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'تفاصيل الأصناف',
                    style: TextStyle(color: Colors.cyanAccent, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),

                  // الجدول
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                    child: isMobile
                        ? SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                const SizedBox(width: 4),
                                ..._buildMobileHeaders(),
                                const SizedBox(width: 4),
                              ],
                            ),
                          )
                        : Row(
                            children: [
                              Expanded(flex: 0, child: const Text('#', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 1, child: const Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 2, child: const Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 1, child: const Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 1, child: const Text('السعر', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 1, child: const Text('النوع', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 1, child: const Text('الخصم%', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 1, child: const Text('مبلغ الخصم', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9))),
                              Expanded(flex: 1, child: const Text('الإجمالي', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 9))),
                            ],
                          ),
                  ),
                  const SizedBox(height: 4),

                  // صفوف البيانات
                  isMobile
                      ? ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: t.items.length,
                          separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                          itemBuilder: (ctx, idx) {
                            final item = t.items[idx];
                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  const SizedBox(width: 4),
                                  ..._buildMobileRow(idx, item),
                                  const SizedBox(width: 4),
                                ],
                              ),
                            );
                          },
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: t.items.length,
                          separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                          itemBuilder: (ctx, idx) {
                            final item = t.items[idx];
                            return Row(
                              children: [
                                Expanded(flex: 0, child: Text('${idx + 1}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 9))),
                                Expanded(flex: 1, child: Text(item.code, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 9))),
                                Expanded(flex: 2, child: Text(item.name, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 10))),
                                Expanded(flex: 1, child: Text(item.quantity.toStringAsFixed(0), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 9))),
                                Expanded(flex: 1, child: Text(_formatCurrency(item.price), textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent, fontSize: 9))),
                                Expanded(flex: 1, child: Text(item.type, textAlign: TextAlign.center, style: TextStyle(color: item.type.contains('وارد') ? Colors.greenAccent : Colors.amber, fontSize: 9))),
                                Expanded(flex: 1, child: Text(item.discountRate.toStringAsFixed(1), textAlign: TextAlign.center, style: const TextStyle(color: Colors.amber, fontSize: 9))),
                                Expanded(flex: 1, child: Text(_formatCurrency(item.discountAmount), textAlign: TextAlign.center, style: const TextStyle(color: Colors.amber, fontSize: 9))),
                                Expanded(flex: 1, child: Text(_formatCurrency(item.total), textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 9))),
                              ],
                            );
                          },
                        ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // بطاقة الإجماليات
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text('إجمالي الكميات', style: TextStyle(color: Colors.white60, fontSize: 11)),
                      Text(
                        t.items.fold(0.0, (s, i) => s + i.quantity).toStringAsFixed(0),
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Container(width: 1, height: 30, color: Colors.white24),
                  Column(
                    children: [
                      const Text('إجمالي المبلغ', style: TextStyle(color: Colors.white60, fontSize: 11)),
                      Text(
                        _formatCurrency(t.totalAmount),
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Container(width: 1, height: 30, color: Colors.white24),
                  Column(
                    children: [
                      const Text('المبلغ المدفوع', style: TextStyle(color: Colors.white60, fontSize: 11)),
                      Text(
                        _formatCurrency(t.paidAmount),
                        style: const TextStyle(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ===== دوال مساعدة للتفاصيل (موبايل) =====

  List<Widget> _buildMobileHeaders() {
    const double colWidth = 55.0;
    const double nameColWidth = 70.0;
    return [
      SizedBox(width: 30, child: const Text('#', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: colWidth, child: const Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: nameColWidth, child: const Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: colWidth, child: const Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: colWidth, child: const Text('السعر', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: colWidth, child: const Text('النوع', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: colWidth, child: const Text('خصم%', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: colWidth, child: const Text('مبلغ الخصم', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 8))),
      SizedBox(width: colWidth, child: const Text('الإجمالي', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 8))),
    ];
  }

  List<Widget> _buildMobileRow(int idx, SupplierItem item) {
    const double colWidth = 55.0;
    const double nameColWidth = 70.0;
    return [
      SizedBox(width: 30, child: Text('${idx + 1}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 8))),
      SizedBox(width: colWidth, child: Text(item.code, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 8))),
      SizedBox(width: nameColWidth, child: Text(item.name, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 9))),
      SizedBox(width: colWidth, child: Text(item.quantity.toStringAsFixed(0), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 8))),
      SizedBox(width: colWidth, child: Text(_formatCurrency(item.price), textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent, fontSize: 8))),
      SizedBox(width: colWidth, child: Text(item.type, textAlign: TextAlign.center, style: TextStyle(color: item.type.contains('وارد') ? Colors.greenAccent : Colors.amber, fontSize: 8))),
      SizedBox(width: colWidth, child: Text(item.discountRate.toStringAsFixed(1), textAlign: TextAlign.center, style: const TextStyle(color: Colors.amber, fontSize: 8))),
      SizedBox(width: colWidth, child: Text(_formatCurrency(item.discountAmount), textAlign: TextAlign.center, style: const TextStyle(color: Colors.amber, fontSize: 8))),
      SizedBox(width: colWidth, child: Text(_formatCurrency(item.total), textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 8))),
    ];
  }

  Widget _buildDetailItem(String label, String value, IconData icon, {Color? color}) {
    return Row(
      children: [
        Icon(icon, color: Colors.cyanAccent, size: 14),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.white60, fontSize: 9)),
              Text(
                value,
                style: TextStyle(color: color ?? Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}