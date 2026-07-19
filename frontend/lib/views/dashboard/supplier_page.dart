// lib/views/dashboard/supplier_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/supplier_service.dart';
import '../../services/coding_service.dart';
import '../../models/supplier_transaction_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import 'supplier_history_page.dart';
import 'coding_page.dart';

class SupplierPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? userName;

  const SupplierPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.userName,
  });

  @override
  State<SupplierPage> createState() => _SupplierPageState();
}

class _SupplierPageState extends State<SupplierPage> {
  final SupplierService _supplierService = SupplierService();
  final CodingService _codingService = CodingService();

  // ===== الحقول الأساسية =====
  String? _selectedBranchCode;
  String? _selectedStoreCode;
  String _selectedDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  String? _selectedSupplier;
  String? _selectedPaymentMethod;
  String? _selectedTreasury;
  bool _isAddToStore = false;
  bool _isAddToDaily = false;
  int _currentSerial = 0;
  double _supplierBalance = 0.0;

  // ===== قوائم المنسدلة =====
  List<Map<String, String>> _stores = [];
  List<Map<String, String>> _suppliers = [];
  List<Map<String, String>> _paymentMethods = [];
  List<Map<String, String>> _treasuries = [];

  // ===== الأصناف =====
  List<SupplierItem> _items = [];
  List<List<TextEditingController>> _controllers = [];
  List<List<FocusNode>> _focusNodes = [];
  final ScrollController _scrollController = ScrollController();
  static const List<String> _fieldOrder = ['code', 'name', 'quantity', 'price', 'type', 'discountRate', 'discountAmount', 'total'];

  // ===== الإجماليات =====
  double _totalAmount = 0.0;
  double _paidAmount = 0.0;
  double _discountPercent = 0.0;
  double _discountAmount = 0.0;

  // ===== حالة الصفحة =====
  bool _isLoading = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedBranchCode = widget.selectedBranchCode ?? 'all';
    _loadDropdowns();
    _addEmptyRow();
  }

  // ===== جلب القوائم =====
  Future<void> _loadDropdowns() async {
    setState(() => _isLoading = true);
    try {
      final box = Hive.box('coding_box');

      var stores = box.get('${widget.companyCode}_stores') as List? ?? [];
      _stores = stores
          .map((e) => {'code': e['code'].toString(), 'name': e['name'].toString()})
          .toList()
        ..removeWhere((s) => s['code'] == null || s['code']!.isEmpty);

      var suppliers = box.get('${widget.companyCode}_suppliers') as List? ?? [];
      _suppliers = suppliers
          .map((e) => {'code': e['code'].toString(), 'name': e['name'].toString()})
          .toList()
        ..removeWhere((s) => s['code'] == null || s['code']!.isEmpty);

      var paymentMethods = box.get('${widget.companyCode}_payment_methods') as List? ?? [];
      _paymentMethods = paymentMethods
          .map((e) => {'code': e['code'].toString(), 'name': e['name'].toString()})
          .toList()
        ..removeWhere((s) => s['code'] == null || s['code']!.isEmpty);

      var treasuries = box.get('${widget.companyCode}_safes') as List? ?? [];
      _treasuries = treasuries
          .map((e) => {'code': e['code'].toString(), 'name': e['name'].toString()})
          .toList()
        ..removeWhere((s) => s['code'] == null || s['code']!.isEmpty);

      if (_stores.isNotEmpty) _selectedStoreCode ??= _stores.first['code'];
      if (_paymentMethods.isNotEmpty) _selectedPaymentMethod ??= _paymentMethods.first['name'];
      if (_treasuries.isNotEmpty) _selectedTreasury ??= _treasuries.first['name'];

      await _loadLastSerial();
    } catch (e) {
      print('خطأ في تحميل القوائم: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadLastSerial() async {
    try {
      final box = Hive.box('supplier_box');
      int maxSerial = 0;
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is List) {
          for (var item in raw) {
            if (item['company_code'] == widget.companyCode &&
                item['branch_code'] == _selectedBranchCode) {
              int s = int.tryParse(item['serial']?.toString() ?? '0') ?? 0;
              if (s > maxSerial) maxSerial = s;
            }
          }
        }
      }
      setState(() => _currentSerial = maxSerial + 1);
    } catch (e) {
      setState(() => _currentSerial = 1);
    }
  }

  Future<void> _loadSupplierBalance(String supplierName) async {
    if (supplierName.isEmpty) {
      setState(() => _supplierBalance = 0.0);
      return;
    }
    final balance = await _supplierService.getSupplierBalance(
      widget.companyCode,
      _selectedBranchCode ?? 'all',
      supplierName,
    );
    setState(() => _supplierBalance = balance);
  }

  // ===== إدارة الأصناف =====
  void _addEmptyRow() {
    setState(() {
      _items.add(SupplierItem(
        code: '',
        name: '',
        quantity: 0.0,
        price: 0.0,
        type: 'وارد (دخول بضاعة)',
        discountRate: 0.0,
        discountAmount: 0.0,
        total: 0.0,
      ));
      _controllers.add(List.generate(_fieldOrder.length, (_) => TextEditingController(text: '')));
      _focusNodes.add(List.generate(_fieldOrder.length, (_) => FocusNode()));
    });
  }

  void _removeRow(int index) {
    if (_items.length <= 1) return;
    setState(() {
      _items.removeAt(index);
      _controllers.removeAt(index);
      _focusNodes.removeAt(index);
    });
    _recalcTotals();
  }

  void _updateItem(int rowIndex, int fieldIndex, String value) {
    final field = _fieldOrder[fieldIndex];
    final item = _items[rowIndex];
    setState(() {
      switch (field) {
        case 'code':
          item.code = value.trim();
          _autoFillItem(rowIndex);
          break;
        case 'name':
          item.name = value;
          break;
        case 'quantity':
          item.quantity = double.tryParse(value) ?? 0.0;
          break;
        case 'price':
          item.price = double.tryParse(value) ?? 0.0;
          break;
        case 'type':
          item.type = value;
          break;
        case 'discountRate':
          item.discountRate = double.tryParse(value) ?? 0.0;
          break;
        case 'discountAmount':
          item.discountAmount = double.tryParse(value) ?? 0.0;
          break;
      }
      _recalcItem(rowIndex);
      _recalcTotals();
    });
  }

  void _recalcItem(int index) {
    final item = _items[index];
    final totalBeforeDiscount = item.quantity * item.price;
    final discount = item.discountAmount > 0
        ? item.discountAmount
        : (totalBeforeDiscount * item.discountRate / 100);
    item.total = totalBeforeDiscount - discount;
    final totalIndex = _fieldOrder.indexOf('total');
    if (totalIndex != -1 && index < _controllers.length && totalIndex < _controllers[index].length) {
      _controllers[index][totalIndex].text = item.total.toStringAsFixed(2);
    }
  }

  void _recalcTotals() {
    _totalAmount = _items.fold(0.0, (sum, item) => sum + item.total);
    _discountAmount = _totalAmount * (_discountPercent / 100);
    setState(() {});
  }

  void _autoFillItem(int index) async {
    final code = _items[index].code;
    if (code.isEmpty) return;

    final box = Hive.box('coding_box');
    final key = '${widget.companyCode}_items';
    final raw = box.get(key) as List?;
    if (raw != null) {
      for (var item in raw) {
        if (item['code'].toString() == code) {
          setState(() {
            _items[index].name = item['name'] ?? '';
            _items[index].price = double.tryParse(item['selling_price']?.toString() ?? '0') ?? 0.0;
            _controllers[index][1].text = _items[index].name;
            _controllers[index][3].text = _items[index].price.toString();
            _recalcItem(index);
            _recalcTotals();
          });
          return;
        }
      }
    }

    try {
      final list = await _codingService.getCodingList(companyCode: widget.companyCode, category: 'items');
      for (var item in list) {
        if (item.code == code) {
          setState(() {
            _items[index].name = item.name;
            _items[index].price = item.sellingPrice;
            _controllers[index][1].text = item.name;
            _controllers[index][3].text = item.sellingPrice.toString();
            _recalcItem(index);
            _recalcTotals();
          });
          return;
        }
      }
    } catch (e) {
      print('خطأ في جلب الصنف: $e');
    }
  }

  void _onFieldSubmitted(int rowIndex, int fieldIndex) {
    final next = fieldIndex + 1;
    if (next < _fieldOrder.length) {
      _focusNodes[rowIndex][next].requestFocus();
    } else {
      _addEmptyRow();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_focusNodes.length > rowIndex + 1) {
          _focusNodes[rowIndex + 1][0].requestFocus();
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  // ===== اسم الفرع =====
  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    try {
      final box = Hive.box('coding_box');
      final raw = box.get('${widget.companyCode}_branches') as List? ?? [];
      for (var item in raw) {
        if (item['code']?.toString() == code) {
          return item['name']?.toString() ?? code;
        }
      }
      return code;
    } catch (e) {
      return code;
    }
  }

  // ===== الحفظ =====
  Future<void> _handleSave() async {
    if (!PermissionsService().canAddSupplierTransaction) {
      _showSnackBar('ليس لديك صلاحية للحفظ', Colors.orange);
      return;
    }

    if (_selectedSupplier == null || _selectedSupplier!.isEmpty) {
      _showSnackBar('اختر مورداً', Colors.orange);
      return;
    }
    if (_selectedStoreCode == null || _selectedStoreCode!.isEmpty) {
      _showSnackBar('اختر مخزناً', Colors.orange);
      return;
    }
    if (_selectedPaymentMethod == null || _selectedPaymentMethod!.isEmpty) {
      _showSnackBar('اختر طريقة الدفع', Colors.orange);
      return;
    }
    if (_selectedTreasury == null || _selectedTreasury!.isEmpty) {
      _showSnackBar('اختر خزينة', Colors.orange);
      return;
    }

    final validItems = _items.where((i) => i.code.isNotEmpty && i.quantity > 0).toList();
    if (validItems.isEmpty) {
      _showSnackBar('أضف صنفاً واحداً على الأقل', Colors.orange);
      return;
    }

    setState(() => _isSaving = true);
    try {
      final model = SupplierTransactionModel(
        companyCode: widget.companyCode,
        branchCode: _selectedBranchCode ?? 'all',
        storeCode: _selectedStoreCode!,
        serial: _currentSerial,
        date: _selectedDate,
        supplierName: _selectedSupplier!,
        paymentMethod: _selectedPaymentMethod!,
        treasury: _selectedTreasury!,
        isAddToStore: _isAddToStore,
        employee: widget.userName ?? 'غير محدد',
        items: validItems,
        totalAmount: _totalAmount - _discountAmount,
        paidAmount: double.tryParse(_paidAmount.toStringAsFixed(2)) ?? 0.0,
      );

      final result = await _supplierService.saveSupplierTransaction(model);
      if (result['success'] == true) {
        _showSnackBar('تم حفظ حركة المورد بنجاح', Colors.green);
        setState(() {
          _items.clear();
          _controllers.clear();
          _focusNodes.clear();
          _addEmptyRow();
          _loadLastSerial();
          _selectedSupplier = null;
          _supplierBalance = 0.0;
          _totalAmount = 0.0;
          _paidAmount = 0.0;
          _discountPercent = 0.0;
          _discountAmount = 0.0;
        });
      } else {
        _showSnackBar('فشل الحفظ: ${result['error']}', Colors.red);
      }
    } catch (e) {
      _showSnackBar('خطأ: $e', Colors.red);
    } finally {
      setState(() => _isSaving = false);
    }
  }

  // ===== بناء جدول الأصناف (مع مسطرة واحدة) =====
  Widget _buildItemsTable() {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    Widget buildTableContent() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // عناوين الأعمدة
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(10),
            ),
            child: isMobile ? _buildMobileHeaders() : _buildDesktopHeaders(),
          ),
          const SizedBox(height: 4),
          // الصفوف
          ...List.generate(_items.length, (idx) {
            final item = _items[idx];
            final isLast = idx == _items.length - 1;
            if (item.code.isEmpty && !isLast) return const SizedBox.shrink();
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white.withOpacity(0.05), width: 0.5),
                ),
              ),
              child: isMobile ? _buildMobileRow(idx) : _buildDesktopRow(idx),
            );
          }),
          // زر إضافة سطر
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: _addEmptyRow,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text('+ إضافة صنف جديد', style: TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo', fontSize: 13)),
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (isMobile) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: buildTableContent(),
      );
    }
    return buildTableContent();
  }

  // ===== عناوين الموبايل =====
  Widget _buildMobileHeaders() {
    const double colWidth = 50.0;
    const double nameColWidth = 65.0;
    const double typeColWidth = 75.0;
    return Row(
      children: [
        SizedBox(width: 28, child: const Text('#', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: colWidth, child: const Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: nameColWidth, child: const Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: colWidth, child: const Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: colWidth, child: const Text('السعر', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: typeColWidth, child: const Text('النوع', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: colWidth, child: const Text('خصم%', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: colWidth, child: const Text('مبلغ الخصم', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 8))),
        SizedBox(width: colWidth, child: const Text('الإجمالي', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 8))),
        const SizedBox(width: 30),
      ],
    );
  }

  // ===== صف الموبايل =====
  Widget _buildMobileRow(int idx) {
    final item = _items[idx];
    const double colWidth = 50.0;
    const double nameColWidth = 65.0;
    const double typeColWidth = 100.0;
    return Row(
      children: [
        SizedBox(width: 28, child: Text('${idx + 1}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 8))),
        SizedBox(width: colWidth, child: _buildItemField(idx, 0)),
        SizedBox(width: nameColWidth, child: _buildItemField(idx, 1)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 2)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 3)),
        SizedBox(width: typeColWidth, child: _buildItemTypeDropdown(idx)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 5)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 6)),
        SizedBox(
          width: colWidth,
          child: Text(
            item.total.toStringAsFixed(2),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.greenAccent, fontSize: 9, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete, color: Colors.red, size: 16),
          onPressed: () => _removeRow(idx),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }

  // ===== عناوين سطح المكتب =====
  Widget _buildDesktopHeaders() {
    return const Row(
      children: [
        Expanded(flex: 0, child: Text('#', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 2, child: Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('السعر', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('النوع', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('خصم%', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('مبلغ الخصم', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('الإجمالي', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 10))),
        SizedBox(width: 30),
      ],
    );
  }

  // ===== صف سطح المكتب =====
  Widget _buildDesktopRow(int idx) {
    final item = _items[idx];
    return Row(
      children: [
        Expanded(flex: 0, child: Text('${idx + 1}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 10))),
        Expanded(flex: 1, child: _buildItemField(idx, 0)),
        Expanded(flex: 2, child: _buildItemField(idx, 1)),
        Expanded(flex: 1, child: _buildItemField(idx, 2)),
        Expanded(flex: 1, child: _buildItemField(idx, 3)),
        Expanded(flex: 1, child: _buildItemTypeDropdown(idx)),
        Expanded(flex: 1, child: _buildItemField(idx, 5)),
        Expanded(flex: 1, child: _buildItemField(idx, 6)),
        Expanded(
          flex: 1,
          child: Text(
            item.total.toStringAsFixed(2),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete, color: Colors.red, size: 18),
          onPressed: () => _removeRow(idx),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }

  // ===== حقل الإدخال =====
  Widget _buildItemField(int rowIndex, int fieldIndex) {
    final field = _fieldOrder[fieldIndex];
    final keyboard = (field == 'quantity' || field == 'price' || field == 'discountRate' || field == 'discountAmount')
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text;

    if (field == 'total') {
      return TextFormField(
        controller: _controllers[rowIndex][fieldIndex],
        style: const TextStyle(color: Colors.white70, fontSize: 11),
        textAlign: TextAlign.center,
        readOnly: true,
        decoration: InputDecoration(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          isDense: true,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextFormField(
        controller: _controllers[rowIndex][fieldIndex],
        focusNode: _focusNodes[rowIndex][fieldIndex],
        style: const TextStyle(color: Colors.white, fontSize: 11),
        textAlign: TextAlign.center,
        keyboardType: keyboard,
        textInputAction: (fieldIndex == _fieldOrder.length - 1) ? TextInputAction.done : TextInputAction.next,
        onChanged: (v) => _updateItem(rowIndex, fieldIndex, v),
        onFieldSubmitted: (_) => _onFieldSubmitted(rowIndex, fieldIndex),
        decoration: InputDecoration(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          isDense: true,
        ),
      ),
    );
  }

  // ===== Dropdown لنوع الصنف =====
  Widget _buildItemTypeDropdown(int rowIndex) {
    final types = ['وارد (دخول بضاعة)', 'صادر (دفعة)'];
    return DropdownButtonFormField<String>(
      value: _items[rowIndex].type,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 10),
      isDense: true,
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        isDense: true,
      ),
      items: types.map((t) => DropdownMenuItem(
        value: t,
        child: Text(t, style: const TextStyle(fontSize: 9), overflow: TextOverflow.ellipsis),
      )).toList(),
      onChanged: (val) {
        if (val != null) {
          _updateItem(rowIndex, 4, val);
        }
      },
    );
  }

  // ===== دوال البناء المساعدة =====
  Widget _buildDateField() {
    return TextFormField(
      initialValue: _selectedDate,
      readOnly: true,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      onTap: () async {
        DateTime? picked = await showDatePicker(
          context: context,
          initialDate: DateTime.parse(_selectedDate),
          firstDate: DateTime(2020),
          lastDate: DateTime(2101),
        );
        if (picked != null) {
          setState(() => _selectedDate = DateFormat('yyyy-MM-dd').format(picked));
        }
      },
      decoration: InputDecoration(
        labelText: 'التاريخ',
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
        prefixIcon: const Icon(Icons.calendar_today, color: Colors.amber, size: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        isDense: true,
      ),
    );
  }

  Widget _buildStoreDropdown() {
    return DropdownButtonFormField<String?>(
      value: _selectedStoreCode,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: 'المخزن',
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
      items: _stores.map((s) => DropdownMenuItem(value: s['code'], child: Text(s['name'] ?? '', style: const TextStyle(fontSize: 12)))).toList(),
      onChanged: (val) => setState(() => _selectedStoreCode = val),
    );
  }

  Widget _buildAddToStoreToggle() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'إضافة للمخزن',
          style: TextStyle(
            color: _isAddToStore ? Colors.greenAccent : Colors.white54,
            fontSize: 8,
            fontFamily: 'Cairo',
          ),
        ),
        Switch(
          value: _isAddToStore,
          onChanged: (val) => setState(() => _isAddToStore = val),
          activeColor: Colors.greenAccent,
          inactiveThumbColor: Colors.grey,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _buildAddToDailyToggle() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'إضافة للخزينة',
          style: TextStyle(
            color: _isAddToDaily ? Colors.cyanAccent : Colors.white54,
            fontSize: 8,
            fontFamily: 'Cairo',
          ),
        ),
        Switch(
          value: _isAddToDaily,
          onChanged: (val) => setState(() => _isAddToDaily = val),
          activeColor: Colors.cyanAccent,
          inactiveThumbColor: Colors.grey,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _buildSupplierDropdown() {
    return DropdownButtonFormField<String?>(
      value: _selectedSupplier,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'المورد',
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
      items: _suppliers.map((s) => DropdownMenuItem(value: s['name'], child: Text(s['name'] ?? '', style: const TextStyle(fontSize: 12)))).toList(),
      onChanged: (val) {
        setState(() {
          _selectedSupplier = val;
          if (val != null && val.isNotEmpty) _loadSupplierBalance(val);
        });
      },
    );
  }

  Widget _buildPaymentMethodDropdown() {
    return DropdownButtonFormField<String?>(
      value: _selectedPaymentMethod,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: 'طريقة الدفع',
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
      items: _paymentMethods.map((p) => DropdownMenuItem(value: p['name'], child: Text(p['name'] ?? '', style: const TextStyle(fontSize: 12)))).toList(),
      onChanged: (val) => setState(() => _selectedPaymentMethod = val),
    );
  }

  Widget _buildTreasuryDropdown() {
    return DropdownButtonFormField<String?>(
      value: _selectedTreasury,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: 'الخزينة',
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
      items: _treasuries.map((t) => DropdownMenuItem(value: t['name'], child: Text(t['name'] ?? '', style: const TextStyle(fontSize: 12)))).toList(),
      onChanged: (val) => setState(() => _selectedTreasury = val),
    );
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

  // ===== البناء الرئيسي =====
  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canShowSuppliers) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('حركة الموردين', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.transparent,
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, Color(0xFF1A237E), Colors.black]),
          ),
          child: const Center(
            child: Text(
              'ليس لديك صلاحية لعرض حركة الموردين',
              style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 16),
            ),
          ),
        ),
      );
    }

    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) { if (!didPop && mounted) Navigator.pop(context); },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('حركة الموردين', style: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 16)),
              if (_currentSerial > 0)
                Text('إذن رقم: $_currentSerial', style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
              Text(
                _getBranchName(_selectedBranchCode),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white60),
              ),
            ],
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          toolbarHeight: 80,
          // ===== الرصيد في أعلى الصفحة (على اليمين) =====
          actions: [
            if (_selectedSupplier != null && _selectedSupplier!.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _supplierBalance > 0
                        ? [Colors.greenAccent.withOpacity(0.25), Colors.greenAccent.withOpacity(0.08)]
                        : [Colors.redAccent.withOpacity(0.25), Colors.redAccent.withOpacity(0.08)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _supplierBalance > 0
                        ? Colors.greenAccent.withOpacity(0.5)
                        : Colors.redAccent.withOpacity(0.5),
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _supplierBalance > 0 ? Icons.trending_up : Icons.trending_down,
                      size: 18,
                      color: _supplierBalance > 0 ? Colors.greenAccent : Colors.redAccent,
                    ),
                    const SizedBox(width: 6),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'رصيد المورد',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 9,
                            fontFamily: 'Cairo',
                          ),
                        ),
                        Text(
                          _supplierBalance.toStringAsFixed(2),
                          style: TextStyle(
                            color: _supplierBalance > 0 ? Colors.greenAccent : Colors.redAccent,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, Color(0xFF1A237E), Colors.black]),
          ),
          child: SafeArea(
            child: (_isLoading || _isSaving)
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      children: [
                        // ===== صف واحد: المورد + التاريخ + المخزن + الأزرار =====
                        GlassCard(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withOpacity(0.05),
                                  Colors.white.withOpacity(0.02),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              children: [
                                // الصف الأول: المورد (بدون الرصيد لأنه في الأعلى)
                                Row(
                                  children: [
                                    Expanded(
                                      flex: 4,
                                      child: _buildSupplierDropdown(),
                                    ),
                                    const SizedBox(width: 6),
                                    IconButton(
                                      icon: const Icon(Icons.add_circle, color: Colors.amber, size: 22),
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (c) => CodingPage(companyCode: widget.companyCode)),
                                        ).then((_) => _loadDropdowns());
                                      },
                                      tooltip: 'إضافة مورد',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                // الصف الثاني: التاريخ + المخزن + أزرار الإضافة
                                Row(
                                  children: [
                                    Expanded(flex: isMobile ? 2 : 2, child: _buildDateField()),
                                    const SizedBox(width: 6),
                                    Expanded(flex: isMobile ? 2 : 2, child: _buildStoreDropdown()),
                                    const SizedBox(width: 6),
                                    Expanded(flex: 1, child: _buildAddToStoreToggle()),
                                    const SizedBox(width: 4),
                                    Expanded(flex: 1, child: _buildAddToDailyToggle()),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 8),

                        // ===== جدول الأصناف =====
                        GlassCard(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withOpacity(0.05),
                                  Colors.white.withOpacity(0.02),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.all(8),
                            child: _buildItemsTable(),
                          ),
                        ),

                        const SizedBox(height: 8),

                        // ===== الحقول السفلية (طرق الدفع والخزينة والمبالغ) =====
                        GlassCard(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withOpacity(0.05),
                                  Colors.white.withOpacity(0.02),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: _buildPaymentMethodDropdown()),
                                    const SizedBox(width: 6),
                                    Expanded(child: _buildTreasuryDropdown()),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextFormField(
                                        initialValue: _discountPercent.toString(),
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                        textAlign: TextAlign.center,
                                        keyboardType: TextInputType.number,
                                        decoration: InputDecoration(
                                          labelText: 'نسبة الخصم %',
                                          labelStyle: const TextStyle(color: Colors.white70, fontSize: 10),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                          isDense: true,
                                        ),
                                        onChanged: (v) {
                                          setState(() {
                                            _discountPercent = double.tryParse(v) ?? 0.0;
                                            _recalcTotals();
                                          });
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: TextFormField(
                                        initialValue: _discountAmount.toStringAsFixed(2),
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                        textAlign: TextAlign.center,
                                        keyboardType: TextInputType.number,
                                        decoration: InputDecoration(
                                          labelText: 'مبلغ الخصم',
                                          labelStyle: const TextStyle(color: Colors.white70, fontSize: 10),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                          isDense: true,
                                        ),
                                        onChanged: (v) {
                                          setState(() {
                                            _discountAmount = double.tryParse(v) ?? 0.0;
                                            _recalcTotals();
                                          });
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 6),
                                        decoration: BoxDecoration(
                                          color: Colors.greenAccent.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                                        ),
                                        child: Text(
                                          'الإجمالي: ${(_totalAmount - _discountAmount).toStringAsFixed(2)}',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: TextFormField(
                                        initialValue: _paidAmount.toString(),
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                        textAlign: TextAlign.center,
                                        keyboardType: TextInputType.number,
                                        decoration: InputDecoration(
                                          labelText: 'المدفوع',
                                          labelStyle: const TextStyle(color: Colors.white70, fontSize: 10),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                          isDense: true,
                                        ),
                                        onChanged: (v) {
                                          setState(() {
                                            _paidAmount = double.tryParse(v) ?? 0.0;
                                          });
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 8),

                        // ===== أزرار الحفظ والمعاينة =====
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _handleSave,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.greenAccent,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                child: Text(
                                  _isSaving ? 'جاري الحفظ...' : 'حفظ',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (c) => SupplierHistoryPage(
                                        companyCode: widget.companyCode,
                                        selectedBranchCode: _selectedBranchCode,
                                      ),
                                    ),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white10,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                child: const Text('معاينة', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (var row in _controllers) for (var c in row) c.dispose();
    for (var row in _focusNodes) for (var f in row) f.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}