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
// import '../../models/coding_model.dart';

class SupplierPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? userName;
  final SupplierTransactionModel? editItem; // ✅ إضافة معامل التعديل

  const SupplierPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.userName,
    this.editItem, // ✅ استقبال بيانات التعديل
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
  bool _isAddToStore = false;
  int _currentSerial = 0;
  double _supplierBalance = 0.0;
  String? _editDocId;

  // ===== قوائم المنسدلة =====
  List<Map<String, String>> _stores = [];
  List<Map<String, String>> _suppliers = [];

  // ===== الأصناف =====
  List<SupplierItem> _items = [];
  List<List<TextEditingController>> _controllers = [];
  List<List<FocusNode>> _focusNodes = [];
  final ScrollController _scrollController = ScrollController();
  static const List<String> _fieldOrder = ['code', 'name', 'quantity', 'price', 'discountRate', 'discountAmount', 'total'];

  // ===== الإجماليات =====
  double _totalAmount = 0.0;
  double _discountPercent = 0.0;
  double _discountAmount = 0.0;
  double _expectedBalance = 0.0; // ✅ الرصيد المتوقع (يتغير لحظياً)

  // ===== متحكمات الخصم في الأسفل =====
  final TextEditingController _discountPercentController = TextEditingController();
  final TextEditingController _discountAmountController = TextEditingController();

  // ===== حالة الصفحة =====
  bool _isLoading = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedBranchCode = widget.selectedBranchCode ?? 'all';
    _loadDropdowns();
    _discountPercentController.addListener(_onDiscountPercentChanged);
    _discountAmountController.addListener(_onDiscountAmountChanged);
  }

  // ===== دالة مساعدة لإعادة بناء المتحكمات =====
  void _rebuildControllersAndFocus() {
    for (var row in _controllers) for (var c in row) c.dispose();
    for (var row in _focusNodes) for (var f in row) f.dispose();
    _controllers.clear();
    _focusNodes.clear();

    for (int i = 0; i < _items.length; i++) {
      final item = _items[i];
      List<TextEditingController> rowControllers = [];
      List<FocusNode> rowFocus = [];
      for (int j = 0; j < _fieldOrder.length; j++) {
        final field = _fieldOrder[j];
        String initialValue = '';
        switch (field) {
          case 'code': initialValue = item.code; break;
          case 'name': initialValue = item.name; break;
          case 'quantity': initialValue = item.quantity.toString(); break;
          case 'price': initialValue = item.price.toString(); break;
          case 'discountRate': initialValue = item.discountRate.toString(); break;
          case 'discountAmount': initialValue = item.discountAmount.toString(); break;
          case 'total': initialValue = item.total.toString(); break;
        }
        rowControllers.add(TextEditingController(text: initialValue));
        rowFocus.add(FocusNode());
      }
      _controllers.add(rowControllers);
      _focusNodes.add(rowFocus);
    }
  }

  // ===== ربط الخصم في الأسفل =====
  void _onDiscountPercentChanged() {
    if (_discountPercentController.text.isEmpty) return;
    final val = double.tryParse(_discountPercentController.text);
    if (val != null && val != _discountPercent) {
      setState(() {
        _discountPercent = val;
        _discountAmount = _totalAmount * (_discountPercent / 100);
        _discountAmountController.text = _discountAmount.toStringAsFixed(2);
      });
    }
  }

  void _onDiscountAmountChanged() {
    if (_discountAmountController.text.isEmpty) return;
    final val = double.tryParse(_discountAmountController.text);
    if (val != null && val != _discountAmount) {
      setState(() {
        _discountAmount = val;
        if (_totalAmount > 0) {
          _discountPercent = (_discountAmount / _totalAmount) * 100;
          _discountPercentController.text = _discountPercent.toStringAsFixed(1);
        }
      });
    }
  }

  // ===== تحديث حقول الخصم بعد تغيير الإجمالي =====
  void _updateDiscountFields() {
    if (_discountAmount > 0) {
      _discountAmountController.text = _discountAmount.toStringAsFixed(2);
      if (_totalAmount > 0) {
        _discountPercent = (_discountAmount / _totalAmount) * 100;
        _discountPercentController.text = _discountPercent.toStringAsFixed(1);
      }
    } else if (_discountPercent > 0) {
      _discountPercentController.text = _discountPercent.toStringAsFixed(1);
      _discountAmount = _totalAmount * (_discountPercent / 100);
      _discountAmountController.text = _discountAmount.toStringAsFixed(2);
    } else {
      _discountPercentController.text = '0';
      _discountAmountController.text = '0.00';
    }
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

      // ✅ إذا كان هناك editItem، لا نغيّر الـ store المحدد مسبقاً
      if (_stores.isNotEmpty && _selectedStoreCode == null) {
        _selectedStoreCode = _stores.first['code'];
      }

      await _loadLastSerial();

      // ✅ تحميل بيانات التعديل بعد جلب القوائم
      if (widget.editItem != null) {
        _loadEditData();
      } else {
        _addEmptyRow();
      }
    } catch (e) {
      print('خطأ في تحميل القوائم: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ===== تحميل بيانات التعديل =====
  void _loadEditData() {
    final model = widget.editItem!;
    setState(() {
      _selectedSupplier = model.supplierName;
      _selectedStoreCode = model.storeCode;
      _selectedDate = model.date;
      _currentSerial = model.serial;
      _isAddToStore = model.isAddToStore;
      _editDocId = model.docId; // تخزين docId

      // تحويل الأصناف
      _items = List.from(model.items);
      // إضافة صف فارغ للإضافة
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

      // إعادة بناء المتحكمات
      _rebuildControllersAndFocus();

      // حساب الإجماليات
      _totalAmount = _items.fold(0.0, (sum, item) => sum + item.total);
      _discountAmount = 0.0;
      _discountPercent = 0.0;
      _updateDiscountFields();

      // تحميل رصيد المورد
      if (_selectedSupplier != null && _selectedSupplier!.isNotEmpty) {
        _loadSupplierBalance(_selectedSupplier!);
      }
    });
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
      // ✅ إذا كان هناك editItem، نستخدم سيرياله، وإلا نأخذ التالي
      if (widget.editItem == null) {
        setState(() => _currentSerial = maxSerial + 1);
      }
    } catch (e) {
      if (widget.editItem == null) {
        setState(() => _currentSerial = 1);
      }
    }
  }

  Future<void> _loadSupplierBalance(String supplierName) async {
  if (supplierName.isEmpty) {
    setState(() {
      _supplierBalance = 0.0;
      _expectedBalance = 0.0;
    });
    return;
  }
  final balance = await _supplierService.getSupplierBalance(
    widget.companyCode,
    _selectedBranchCode ?? 'all',
    supplierName,
  );
  setState(() {
    _supplierBalance = balance.abs();
    _expectedBalance = _supplierBalance; // ✅ في البداية يساوي الرصيد السابق
  });
}

  // ===== إدارة الأصناف =====
  void _addEmptyRow() {
    // منع إضافة صف فارغ إضافي إذا كان آخر صف فارغاً
    if (_items.isNotEmpty) {
      final last = _items.last;
      if (last.code.isEmpty && last.quantity == 0.0 && last.price == 0.0) return;
    }

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
      List<TextEditingController> rowControllers = [];
      List<FocusNode> rowFocus = [];
      for (int j = 0; j < _fieldOrder.length; j++) {
        rowControllers.add(TextEditingController(text: ''));
        rowFocus.add(FocusNode());
      }
      _controllers.add(rowControllers);
      _focusNodes.add(rowFocus);
    });
  }

  void _removeRow(int index) {
    if (_items.length <= 1) return;
    setState(() {
      _items.removeAt(index);
      for (var c in _controllers[index]) c.dispose();
      for (var f in _focusNodes[index]) f.dispose();
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
        case 'discountRate':
          item.discountRate = double.tryParse(value) ?? 0.0;
          _updateItemDiscountAmount(rowIndex);
          break;
        case 'discountAmount':
          item.discountAmount = double.tryParse(value) ?? 0.0;
          _updateItemDiscountRate(rowIndex);
          break;
      }
      _recalcItem(rowIndex);
      _recalcTotals();
    });
  }

  void _updateItemDiscountAmount(int index) {
    final item = _items[index];
    final totalBeforeDiscount = item.quantity * item.price;
    if (totalBeforeDiscount > 0) {
      item.discountAmount = totalBeforeDiscount * item.discountRate / 100;
      final amountIndex = _fieldOrder.indexOf('discountAmount');
      if (amountIndex != -1 && index < _controllers.length && amountIndex < _controllers[index].length) {
        _controllers[index][amountIndex].text = item.discountAmount.toStringAsFixed(2);
      }
    }
  }

  void _updateItemDiscountRate(int index) {
    final item = _items[index];
    final totalBeforeDiscount = item.quantity * item.price;
    if (totalBeforeDiscount > 0) {
      item.discountRate = (item.discountAmount / totalBeforeDiscount) * 100;
      final rateIndex = _fieldOrder.indexOf('discountRate');
      if (rateIndex != -1 && index < _controllers.length && rateIndex < _controllers[index].length) {
        _controllers[index][rateIndex].text = item.discountRate.toStringAsFixed(1);
      }
    }
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
  _updateDiscountFields();
  // ✅ حساب الرصيد المتوقع = الرصيد السابق + صافي الفاتورة الحالية
  _expectedBalance = _supplierBalance + (_totalAmount - _discountAmount);
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
            _items[index].price = double.tryParse(item['wholesale_price']?.toString() ?? '0') ?? 0.0;
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
            _items[index].price = item.wholesalePrice;
            _controllers[index][1].text = item.name;
            _controllers[index][3].text = item.wholesalePrice.toString();
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

  // ===== اختيار التاريخ =====
  Future<void> _pickDate() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_selectedDate),
      firstDate: DateTime(2020),
      lastDate: DateTime(2101),
    );
    if (picked != null) {
      setState(() => _selectedDate = DateFormat('yyyy-MM-dd').format(picked));
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

  final validItems = _items.where((i) => i.code.isNotEmpty && i.quantity > 0).toList();
  if (validItems.isEmpty) {
    _showSnackBar('أضف صنفاً واحداً على الأقل', Colors.orange);
    return;
  }

  setState(() => _isSaving = true);
  try {
    final totalAfterDiscount = _totalAmount - _discountAmount;

    final serial = widget.editItem != null ? widget.editItem!.serial : _currentSerial;

    final model = SupplierTransactionModel(
      companyCode: widget.companyCode,
      branchCode: _selectedBranchCode ?? 'all',
      storeCode: _selectedStoreCode!,
      serial: serial,
      date: _selectedDate,
      supplierName: _selectedSupplier!,
      paymentMethod: 'نقدي',
      treasury: 'الخزينة الرئيسية',
      isAddToStore: _isAddToStore,
      employee: widget.userName ?? 'غير محدد',
      items: validItems,
      totalAmount: totalAfterDiscount,
      paidAmount: totalAfterDiscount,
      docId: _editDocId,
    );

    final result = await _supplierService.saveSupplierTransaction(model);
    if (result['success'] == true) {
      _showSnackBar(widget.editItem != null ? 'تم تعديل حركة المورد بنجاح' : 'تم حفظ حركة المورد بنجاح', Colors.green);

      // ✅ تحديث الرصيد الفعلي للمورد الحالي (تثبيت الرصيد)
      if (_selectedSupplier != null && _selectedSupplier!.isNotEmpty) {
        await _loadSupplierBalance(_selectedSupplier!);
      }

      // ✅ تنظيف الحقول مع الاحتفاظ بالمورد المحدد
      setState(() {
        _items.clear();
        _controllers.clear();
        _focusNodes.clear();
        _addEmptyRow();
        _loadLastSerial();
        _totalAmount = 0.0;
        _discountPercent = 0.0;
        _discountAmount = 0.0;
        _discountPercentController.text = '0';
        _discountAmountController.text = '0.00';
        _editDocId = null;
        // لا نمسح _selectedSupplier ولا _supplierBalance ولا _expectedBalance
      });

      if (widget.editItem != null) {
        Navigator.pop(context, true);
      }
    } else {
      _showSnackBar('فشل الحفظ: ${result['error']}', Colors.red);
    }
  } catch (e) {
    _showSnackBar('خطأ: $e', Colors.red);
  } finally {
    setState(() => _isSaving = false);
  }
}

  // ===== بناء جدول الأصناف =====
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
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text(
                    '+ إضافة صنف جديد',
                    style: TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo', fontSize: 13),
                  ),
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
        child: Container(
          constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width * 1.6),
          child: buildTableContent(),
        ),
      );
    }
    return buildTableContent();
  }

  // ===== عناوين الموبايل =====
  Widget _buildMobileHeaders() {
    const double colWidth = 58.0;
    const double nameColWidth = 76.0;
    return Row(
      children: [
        SizedBox(width: 28, child: const Text('#', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
        SizedBox(width: colWidth, child: const Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
        SizedBox(width: nameColWidth, child: const Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
        SizedBox(width: colWidth, child: const Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 9))),
        SizedBox(width: colWidth, child: const Text('سعر الجملة', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 9))),
        SizedBox(width: colWidth, child: const Text('خصم%', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9))),
        SizedBox(width: colWidth, child: const Text('مبلغ الخصم', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 9))),
        SizedBox(width: colWidth, child: const Text('الإجمالي', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 9))),
        const SizedBox(width: 30),
      ],
    );
  }

  // ===== صف الموبايل =====
  Widget _buildMobileRow(int idx) {
    final item = _items[idx];
    const double colWidth = 58.0;
    const double nameColWidth = 76.0;
    return Row(
      children: [
        SizedBox(width: 28, child: Text('${idx + 1}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 9))),
        SizedBox(width: colWidth, child: _buildItemField(idx, 0)),
        SizedBox(width: nameColWidth, child: _buildItemField(idx, 1)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 2)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 3)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 4)),
        SizedBox(width: colWidth, child: _buildItemField(idx, 5)),
        SizedBox(
          width: colWidth,
          child: Text(
            item.total.toStringAsFixed(2),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold),
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

  // ===== عناوين سطح المكتب =====
  Widget _buildDesktopHeaders() {
    return const Row(
      children: [
        Expanded(flex: 0, child: Text('#', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 2, child: Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 10))),
        Expanded(flex: 1, child: Text('سعر الجملة', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 10))),
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
        Expanded(flex: 1, child: _buildItemField(idx, 4)),
        Expanded(flex: 1, child: _buildItemField(idx, 5)),
        Expanded(
          flex: 1,
          child: Text(
            item.total.toStringAsFixed(2),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete, color: Colors.red, size: 20),
          onPressed: () => _removeRow(idx),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }

  // ===== حقل الإدخال (حجم مناسب) =====
  Widget _buildItemField(int rowIndex, int fieldIndex) {
    final field = _fieldOrder[fieldIndex];
    final keyboard = (field == 'quantity' || field == 'price' || field == 'discountRate' || field == 'discountAmount')
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text;

    if (field == 'total') {
      return TextFormField(
        controller: _controllers[rowIndex][fieldIndex],
        style: const TextStyle(color: Colors.white70, fontSize: 12),
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
        style: const TextStyle(color: Colors.white, fontSize: 12),
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

  // ===== دوال البناء المساعدة =====
  Widget _buildBalanceCard() {
  if (_selectedSupplier == null || _selectedSupplier!.isEmpty) {
    return const SizedBox.shrink();
  }
  // ✅ استخدم _expectedBalance بدلاً من _supplierBalance
  return GlassCard(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.greenAccent.withOpacity(0.15),
            Colors.greenAccent.withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'الرصيد',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontFamily: 'Cairo',
            ),
          ),
          Row(
            children: [
              const Icon(Icons.trending_up, color: Colors.greenAccent, size: 22),
              const SizedBox(width: 6),
              Text(
                _expectedBalance.toStringAsFixed(2), // ✅ الرصيد المتغير لحظياً
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
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
            fontSize: 10,
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
          title: const Text('المشتريات', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.transparent,
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, Color(0xFF1A237E), Colors.black]),
          ),
          child: const Center(
            child: Text(
              'ليس لديك صلاحية لعرض المشتريات',
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
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // الجهة اليسرى: رقم الإذن والفرع
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'المشتريات',
                    style: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 15),
                  ),
                  if (_currentSerial > 0)
                    Text(
                      'إذن رقم: $_currentSerial',
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        color: Colors.cyanAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  Text(
                    _getBranchName(_selectedBranchCode),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10,
                      color: Colors.white60,
                    ),
                  ),
                ],
              ),
              // الجهة اليمنى: التاريخ (قابل للنقر)
              GestureDetector(
                onTap: _pickDate,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today, color: Colors.amber, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        _selectedDate,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          toolbarHeight: 80,
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, Color(0xFF1A237E), Colors.black]),
          ),
          child: SafeArea(
            child: (_isLoading || _isSaving)
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Column(
                      children: [
                        // ===== رصيد المورد =====
                        _buildBalanceCard(),
                        const SizedBox(height: 6),

                        // ===== بطاقة المورد والمخزن (مضغوطة) =====
                        GlassCard(
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            child: isMobile
                                ? Column(
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            flex: 4,
                                            child: _buildSupplierDropdown(),
                                          ),
                                          const SizedBox(width: 4),
                                          IconButton(
                                            icon: const Icon(Icons.add_circle, color: Colors.amber, size: 20),
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
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: _buildStoreDropdown(),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            flex: 1,
                                            child: _buildAddToStoreToggle(),
                                          ),
                                        ],
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      Expanded(
                                        flex: 3,
                                        child: _buildSupplierDropdown(),
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        icon: const Icon(Icons.add_circle, color: Colors.amber, size: 20),
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
                                      const SizedBox(width: 10),
                                      Expanded(
                                        flex: 2,
                                        child: _buildStoreDropdown(),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        flex: 1,
                                        child: _buildAddToStoreToggle(),
                                      ),
                                    ],
                                  ),
                          ),
                        ),

                        const SizedBox(height: 6),

                        // ===== جدول الأصناف =====
                        GlassCard(
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            child: _buildItemsTable(),
                          ),
                        ),

                        const SizedBox(height: 6),

                        // ===== الخصم والإجمالي (مع الربط التلقائي) =====
                        GlassCard(
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // العمود الأيسر: نسبة الخصم ومبلغ الخصم
                                Expanded(
                                  flex: 2,
                                  child: Column(
                                    children: [
                                      TextFormField(
                                        controller: _discountPercentController,
                                        style: const TextStyle(color: Colors.white, fontSize: 13),
                                        textAlign: TextAlign.center,
                                        keyboardType: TextInputType.number,
                                        decoration: InputDecoration(
                                          labelText: 'نسبة الخصم %',
                                          labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                          isDense: true,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      TextFormField(
                                        controller: _discountAmountController,
                                        style: const TextStyle(color: Colors.white, fontSize: 13),
                                        textAlign: TextAlign.center,
                                        keyboardType: TextInputType.number,
                                        decoration: InputDecoration(
                                          labelText: 'مبلغ الخصم',
                                          labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                          isDense: true,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                // العمود الأيمن: الإجمالي
                                Expanded(
                                  flex: 3,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                    decoration: BoxDecoration(
                                      color: Colors.greenAccent.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                                    ),
                                    child: Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Text(
                                            'الإجمالي بعد الخصم',
                                            style: TextStyle(
                                              color: Colors.white70,
                                              fontSize: 13,
                                              fontFamily: 'Cairo',
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${(_totalAmount - _discountAmount).toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              color: Colors.greenAccent,
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 6),

                        // ===== الأزرار =====
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
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
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
                                child: const Text('معاينة', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
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
    _discountPercentController.dispose();
    _discountAmountController.dispose();
    super.dispose();
  }
}