// lib/views/dashboard/supplier_page.dart

import 'package:flutter/material.dart';
import '../../core/theme.dart';
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
  final SupplierTransactionModel? editItem;
  final bool startAsReturn;

  const SupplierPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.userName,
    this.editItem,
    this.startAsReturn = false,
  });

  @override
  State<SupplierPage> createState() => _SupplierPageState();
}

class _SupplierPageState extends State<SupplierPage> {
  final SupplierService _supplierService = SupplierService();
  final CodingService _codingService = CodingService();

  // ===================== البيانات الأساسية =====================

  String? _selectedBranchCode;
  String? _selectedStoreCode;
  String _selectedDate =
      DateFormat('yyyy-MM-dd').format(DateTime.now());

  String? _selectedSupplier;

  // إضافة البضاعة للمخزن
  bool _isAddToStore = true;
  bool _isReturn = false;
  bool _isUpdating = false;

  // تحديث / إضافة الصنف في التكويد
  bool _isAddToCoding = false;

  int _currentSerial = 0;

  double _supplierBalance = 0.0;
  double _expectedBalance = 0.0;

  String? _editDocId;

  // ===================== القوائم =====================

  List<Map<String, String>> _stores = [];
  List<Map<String, String>> _suppliers = [];
  List<Map<String, String>> _itemsLookup = []; // ✅ قائمة الأصناف المقترحة

  // ===================== الأصناف =====================

  List<SupplierItem> _items = [];

  List<List<TextEditingController>> _controllers = [];
  List<List<FocusNode>> _focusNodes = [];
  List<LayerLink> _nameFieldLinks = []; // ✅ روابط عرض قائمة الاقتراحات

  final ScrollController _scrollController =
      ScrollController();

  static const List<String> _fieldOrder = [
    'code',
    'name',
    'quantity',
    'price',
    'total',
  ];

  // ===================== الإجماليات =====================

  double _totalAmount = 0.0;

  double _discountPercent = 0.0;
  double _discountAmount = 0.0;

  // ===================== خصم الفاتورة =====================

  final TextEditingController _discountPercentController =
      TextEditingController();

  final TextEditingController _discountAmountController =
      TextEditingController();

  int _discountSource = 0;

  // ===================== الحالة =====================

  bool _isLoading = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();

    _selectedBranchCode =
        widget.selectedBranchCode ?? 'all';

    

    _isReturn = widget.startAsReturn;
    if (_isReturn) _isAddToStore = true;
    _loadDropdowns();
  }

  // ============================================================
  // إعادة بناء Controllers
  // ============================================================

  void _rebuildControllersAndFocus() {
    for (final row in _controllers) {
      for (final controller in row) {
        controller.dispose();
      }
    }

    for (final row in _focusNodes) {
      for (final focus in row) {
        focus.dispose();
      }
    }

    _controllers.clear();
    _focusNodes.clear();
    _nameFieldLinks.clear(); // ✅

    for (final item in _items) {
      final List<TextEditingController> rowControllers = [];
      final List<FocusNode> rowFocusNodes = [];

      for (final field in _fieldOrder) {
        String value = '';

        switch (field) {
          case 'code':
            value = item.code;
            break;

          case 'name':
            value = item.name;
            break;

          case 'quantity':
            value = item.quantity.toString();
            break;

          case 'price':
            value = item.price.toString();
            break;

          case 'total':
            value = item.total.toStringAsFixed(2);
            break;
        }

        rowControllers.add(
          TextEditingController(text: value),
        );

        rowFocusNodes.add(FocusNode());
      }

      _controllers.add(rowControllers);
      _focusNodes.add(rowFocusNodes);
      _nameFieldLinks.add(LayerLink()); // ✅ رابط لكل صف
    }
  }

  // ============================================================
  // خصم الفاتورة
  // ============================================================

  void _onDiscountPercentChanged() {
  if (_isUpdating) return;
  final value = double.tryParse(_discountPercentController.text);
  if (value == null || value < 0) {
    _isUpdating = true;
    _discountPercentController.text = '0';
    _isUpdating = false;
    return;
  }

  if (value > 100) {
    _isUpdating = true;
    _discountPercentController.text = '100';
    _isUpdating = false;
    _discountPercent = 100;
  } else {
    _discountPercent = value;
  }

  _discountSource = 0; // نسبة
  _applyDiscount();
}

void _onDiscountAmountChanged() {
  if (_isUpdating) return;
  final value = double.tryParse(_discountAmountController.text);
  if (value == null || value < 0) {
    _isUpdating = true;
    _discountAmountController.text = '0.00';
    _isUpdating = false;
    return;
  }

  if (value > _totalAmount) {
    _isUpdating = true;
    _discountAmountController.text = _totalAmount.toStringAsFixed(2);
    _isUpdating = false;
    _discountAmount = _totalAmount;
  } else {
    _discountAmount = value;
  }

  _discountSource = 1; // مبلغ
  _applyDiscount();
}


void _applyDiscount() {
  if (_totalAmount == 0) {
    _isUpdating = true;
    _discountPercent = 0;
    _discountAmount = 0;
    _discountPercentController.text = '0';
    _discountAmountController.text = '0.00';
    _isUpdating = false;
    _updateExpectedBalance();
    return;
  }

  if (_discountSource == 0) {
    // المصدر: نسبة الخصم
    _discountAmount = _totalAmount * (_discountPercent / 100);
    if (_discountAmount > _totalAmount) {
      _discountAmount = _totalAmount;
      _discountPercent = 100;
      _discountPercentController.text = '100';
    }
    _isUpdating = true;
    _discountAmountController.text = _discountAmount.toStringAsFixed(2);
    _isUpdating = false;
  } else {
    // المصدر: مبلغ الخصم
    _discountPercent = (_discountAmount / _totalAmount) * 100;
    if (_discountPercent > 100) {
      _discountPercent = 100;
      _discountAmount = _totalAmount;
      _discountAmountController.text = _totalAmount.toStringAsFixed(2);
    }
    _isUpdating = true;
    _discountPercentController.text = _discountPercent.toStringAsFixed(1);
    _isUpdating = false;
  }

  _updateExpectedBalance();
}


  // ============================================================
  // تحميل القوائم
  // ============================================================

  Future<void> _loadDropdowns() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final box = Hive.box('coding_box');

      // ---------------- المخازن ----------------

      final rawStores =
          box.get('${widget.companyCode}_stores')
              as List? ??
          [];

      _stores = rawStores
          .whereType<Map>()
          .map(
            (e) => {
              'code': e['code']?.toString() ?? '',
              'name': e['name']?.toString() ?? '',
            },
          )
          .where(
            (e) =>
                e['code']!.isNotEmpty &&
                e['name']!.isNotEmpty,
          )
          .toList();

      // ---------------- الموردين ----------------

      final rawSuppliers =
          box.get('${widget.companyCode}_suppliers')
              as List? ??
          [];

      _suppliers = rawSuppliers
          .whereType<Map>()
          .map(
            (e) => {
              'code': e['code']?.toString() ?? '',
              'name': e['name']?.toString() ?? '',
            },
          )
          .where(
            (e) =>
                e['code']!.isNotEmpty &&
                e['name']!.isNotEmpty,
          )
          .toList();

      if (_stores.isNotEmpty &&
          _selectedStoreCode == null) {
        _selectedStoreCode =
            _stores.first['code'];
      }
      await _loadItemsLookup();
      await _loadLastSerial();

      if (widget.editItem != null) {
        _loadEditData();
      } else if (_items.isEmpty) {
        _addEmptyRow();
      }
    } catch (e) {
      print('خطأ في تحميل القوائم: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // تحميل قائمة الأصناف للاقتراحات (من التكويد)
  // ============================================================
  Future<void> _loadItemsLookup() async {
    try {
      final box = Hive.box('coding_box');
      final raw = box.get(
        '${widget.companyCode}_items',
        defaultValue: [],
      );

      final List<Map<String, String>> list = [];

      if (raw is List) {
        for (final e in raw) {
          if (e is! Map) continue;
          final code = e['code']?.toString() ?? '';
          final name = e['name']?.toString() ?? '';
          if (code.isEmpty || name.isEmpty) continue;

          list.add({
            'code': code,
            'name': name,
            'wholesale_price':
                (e['wholesale_price'] ?? e['wholesalePrice'] ?? '0').toString(),
          });
        }
      }

      if (mounted) {
        setState(() {
          _itemsLookup = list;
        });
      }
    } catch (e) {
      print('❌ خطأ في تحميل الأصناف للاقتراحات: $e');
    }
  }
  // ============================================================
// تحميل التعديل
// ============================================================

void _loadEditData() {
  final model = widget.editItem!;
  setState(() {
    _selectedSupplier = model.supplierName;
    _selectedStoreCode = model.storeCode;
    _selectedDate = model.date;
    _currentSerial = model.serial;
    _isAddToStore = model.isAddToStore;
    _isReturn = model.paymentMethod == 'مرتجع' || model.totalAmount < 0;
    _isAddToCoding = model.isAddToCoding;
    _editDocId = model.docId;

    _items = List<SupplierItem>.from(
      model.items.map(
        (item) => SupplierItem(
          code: item.code,
          name: item.name,
          quantity: _isReturn ? item.quantity.abs() : item.quantity,
          price: item.price,
          type: item.type,
          discountRate: 0,
          discountAmount: 0,
          total: item.quantity * item.price,
        ),
      ),
    );

    _items.add(
      SupplierItem(
        code: '',
        name: '',
        quantity: 0,
        price: 0,
        type: 'وارد (دخول بضاعة)',
        discountRate: 0,
        discountAmount: 0,
        total: 0,
      ),
    );

    _rebuildControllersAndFocus();

    _totalAmount = _items.fold(0.0, (sum, item) => sum + item.total.abs());

    // إعادة تعيين الخصم
    _isUpdating = true;
    _discountAmount = 0;
    _discountPercent = 0;
    _discountSource = 0;
    _discountPercentController.text = '0';
    _discountAmountController.text = '0.00';
    _isUpdating = false;

    if (_selectedSupplier != null && _selectedSupplier!.isNotEmpty) {
      _loadSupplierBalance(_selectedSupplier!);
    }

    _applyDiscount(); // الآن سيكون آمنًا
  });
}

  // ============================================================
  // آخر سيريال
  // ============================================================

  Future<void> _loadLastSerial() async {
    try {
      final box =
          Hive.box('supplier_box');

      int maxSerial = 0;

      for (final key in box.keys) {
        final raw = box.get(key);

        if (raw is! List) continue;

        for (final item in raw) {
          if (item is! Map) continue;

          if (item['company_code']
                      ?.toString() !=
                  widget.companyCode ||
              item['branch_code']
                      ?.toString() !=
                  _selectedBranchCode) {
            continue;
          }

          final serial =
              int.tryParse(
                    item['serial']
                            ?.toString() ??
                        '0',
                  ) ??
                  0;

          if (serial > maxSerial) {
            maxSerial = serial;
          }
        }
      }

      if (widget.editItem == null &&
          mounted) {
        setState(() {
          _currentSerial =
              maxSerial + 1;
        });
      }
    } catch (e) {
      if (widget.editItem == null &&
          mounted) {
        setState(() {
          _currentSerial = 1;
        });
      }
    }
  }

  // ============================================================
  // رصيد المورد
  // ============================================================

  Future<void> _loadSupplierBalance(
    String supplierName,
  ) async {
    if (supplierName.isEmpty) {
      if (mounted) {
        setState(() {
          _supplierBalance = 0;
          _expectedBalance = 0;
        });
      }
      return;
    }

    try {
      final balance =
          await _supplierService.getSupplierBalance(
        widget.companyCode,
        _selectedBranchCode ?? 'all',
        supplierName,
      );

      if (!mounted) return;

      setState(() {
        _supplierBalance =
            balance;

        _updateExpectedBalance();
      });
    } catch (e) {
      print(
        'خطأ في جلب رصيد المورد: $e',
      );
    }
  }

  void _updateExpectedBalance() {
  final oldAmount = widget.editItem?.totalAmount ?? 0.0;
  final currentAmount = _totalAmount - _discountAmount;
  _expectedBalance = _supplierBalance - oldAmount + (_isReturn ? -currentAmount : currentAmount);
  if (mounted) setState(() {});
}

  // ============================================================
  // الأصناف
  // ============================================================

  void _addEmptyRow() {
    if (_items.isNotEmpty) {
      final last = _items.last;

      if (last.code.isEmpty &&
          last.quantity == 0 &&
          last.price == 0) {
        return;
      }
    }

    final item = SupplierItem(
      code: '',
      name: '',
      quantity: 0,
      price: 0,
      type: 'وارد (دخول بضاعة)',
      discountRate: 0,
      discountAmount: 0,
      total: 0,
    );

    setState(() {
      _items.add(item);

      _controllers.add([
        TextEditingController(),
        TextEditingController(),
        TextEditingController(),
        TextEditingController(),
        TextEditingController(),
      ]);

      _focusNodes.add([
        FocusNode(),
        FocusNode(),
        FocusNode(),
        FocusNode(),
        FocusNode(),
      ]);
      _nameFieldLinks.add(LayerLink()); 
    });
  }

  void _removeRow(int index) {
    if (_items.length <= 1) return;

    setState(() {
      _items.removeAt(index);

      for (final controller
          in _controllers[index]) {
        controller.dispose();
      }

      for (final focus
          in _focusNodes[index]) {
        focus.dispose();
      }

      _controllers.removeAt(index);
      _focusNodes.removeAt(index);
      _nameFieldLinks.removeAt(index);
    });

    _recalcTotals();
  }

  // ============================================================
  // تحديث الصنف
  // ============================================================

  void _updateItem(
    int rowIndex,
    int fieldIndex,
    String value,
  ) {
    final field =
        _fieldOrder[fieldIndex];

    final item =
        _items[rowIndex];

    switch (field) {
      case 'code':
        item.code = value.trim();

        _autoFillItem(rowIndex);
        break;

      case 'name':
        item.name = value;
        break;

      case 'quantity':
        item.quantity =
            double.tryParse(value) ?? 0;
        break;

      case 'price':
        item.price =
            double.tryParse(value) ?? 0;
        break;

      case 'total':
        break;
    }

    _recalcItem(rowIndex);
    _recalcTotals();
  }

  void _recalcItem(int index) {
    final item =
        _items[index];

    item.discountRate = 0;
    item.discountAmount = 0;

    item.total =
        item.quantity * item.price;

    final totalIndex =
        _fieldOrder.indexOf('total');

    if (index < _controllers.length &&
        totalIndex >= 0) {
      _controllers[index][totalIndex]
          .text =
          item.total.toStringAsFixed(2);
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _recalcTotals() {
  _totalAmount = _items.fold(0.0, (sum, item) => sum + item.total);
  // تطبيق الخصم بناءً على المصدر الحالي
  _applyDiscount();
  if (mounted) setState(() {});
}

  // ============================================================
  // تعبئة الصنف تلقائياً من التكويد
  // الاسم + السعر
  // ============================================================

  Future<void> _autoFillItem(
    int index,
  ) async {
    final code =
        _items[index].code.trim();

    if (code.isEmpty) return;

    final box =
        Hive.box('coding_box');

    final key =
        '${widget.companyCode}_items';

    final raw =
        box.get(key);

    // ==========================================================
    // Hive أولاً
    // ==========================================================

    if (raw is List) {
      for (final value in raw) {
        if (value is! Map) continue;

        if (value['code']?.toString() !=
            code) {
          continue;
        }

        final name =
            value['name']
                    ?.toString() ??
                '';

        final price =
            double.tryParse(
                  value['wholesale_price']
                          ?.toString() ??
                      value['wholesalePrice']
                          ?.toString() ??
                      '0',
                ) ??
                0;

        if (!mounted) return;

        setState(() {
          _items[index].name =
              name;

          _items[index].price =
              price;

          _controllers[index][1]
              .text = name;

          _controllers[index][3]
              .text =
              price.toString();

          _recalcItem(index);
          _recalcTotals();
        });

        return;
      }
    }

    // ==========================================================
    // لو مش موجود محليًا نجرب السيرفر
    // ==========================================================

    try {
      final list =
          await _codingService.getCodingList(
        companyCode:
            widget.companyCode,
        category: 'items',
      );

      for (final item in list) {
        if (item.code != code) {
          continue;
        }

        if (!mounted) return;

        setState(() {
          _items[index].name =
              item.name;

          _items[index].price =
              item.wholesalePrice;

          _controllers[index][1]
              .text =
              item.name;

          _controllers[index][3]
              .text =
              item.wholesalePrice
                  .toString();

          _recalcItem(index);
          _recalcTotals();
        });

        return;
      }
    } catch (e) {
      print(
        'خطأ في جلب الصنف: $e',
      );
    }
  }

  // ============================================================
  // تعبئة الصف عند اختيار صنف من قائمة الاقتراحات
  // ============================================================
  void _fillRowFromSelectedItem(
    int rowIndex,
    Map<String, String> item,
  ) {
    if (rowIndex >= _items.length) return;

    final code = item['code'] ?? '';
    final name = item['name'] ?? '';
    final price =
        double.tryParse(item['wholesale_price'] ?? '0') ?? 0.0;

    setState(() {
      _items[rowIndex].code = code;
      _items[rowIndex].name = name;
      _items[rowIndex].price = price;

      _controllers[rowIndex][0].text = code;
      _controllers[rowIndex][1].text = name;
      _controllers[rowIndex][3].text = price.toString();

      _recalcItem(rowIndex);
      _recalcTotals();
    });
  }

  // ============================================================
  // Enter
  // ============================================================

  void _onFieldSubmitted(int rowIndex, int fieldIndex) {
  // تحديث القيمة الحالية
  _updateItem(rowIndex, fieldIndex, _controllers[rowIndex][fieldIndex].text);

  // الحقول: 0=code, 1=name, 2=quantity, 3=price, 4=total (غير قابل للتحرير)
  // عندما يكون الحقل الحالي هو price (index 3) أو total (index 4)، نضيف صفاً جديداً
  // ولكن total غير قابل للتحرير، لذا المستخدم لن يصل إليه. نضيف شرطاً للـ price.
  if (fieldIndex == 3) {
    // نضيف صفاً جديداً
    _addEmptyRow();

    // نقل التركيز إلى الحقل الأول (الكود) في الصف الجديد
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_focusNodes.length > rowIndex + 1) {
        _focusNodes[rowIndex + 1][0].requestFocus();

        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    });
    return;
  }

  // إذا كان هناك حقل تالي في نفس الصف، ننتقل إليه
  final next = fieldIndex + 1;
  if (next < _fieldOrder.length) {
    _focusNodes[rowIndex][next].requestFocus();
  }
}

  // ============================================================
  // اسم الفرع
  // ============================================================

  String _getBranchName(
    String? code,
  ) {
    if (code == null ||
        code == 'all' ||
        code.isEmpty) {
      return 'كل الفروع';
    }

    try {
      final box =
          Hive.box('coding_box');

      final raw =
          box.get(
                '${widget.companyCode}_branches',
              )
              as List? ??
          [];

      for (final item in raw) {
        if (item is Map &&
            item['code']?.toString() ==
                code) {
          return item['name']
                  ?.toString() ??
              code;
        }
      }
    } catch (_) {}

    return code;
  }

  // ============================================================
  // التاريخ
  // ============================================================

  Future<void> _pickDate() async {
    final picked =
        await showDatePicker(
      context: context,
      initialDate:
          DateTime.parse(_selectedDate),
      firstDate:
          DateTime(2020),
      lastDate:
          DateTime(2101),
    );

    if (picked != null &&
        mounted) {
      setState(() {
        _selectedDate =
            DateFormat('yyyy-MM-dd')
                .format(picked);
      });
    }
  }

  

  // ============================================================
  // الحفظ
  // ============================================================

  Future<void> _handleSave() async {
    if (!PermissionsService()
        .canAddSupplierTransaction) {
      _showSnackBar(
        'ليس لديك صلاحية للحفظ',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (_selectedSupplier ==
            null ||
        _selectedSupplier!.isEmpty) {
      _showSnackBar(
        'اختر مورداً',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (_selectedStoreCode ==
            null ||
        _selectedStoreCode!.isEmpty) {
      _showSnackBar(
        'اختر مخزناً',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final validItems =
        _items.where(
      (item) =>
          item.code.isNotEmpty &&
          item.quantity > 0,
    ).toList();

    if (validItems.isEmpty) {
      _showSnackBar(
        'أضف صنفاً واحداً على الأقل',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final normalNetTotal =
        _totalAmount -
        _discountAmount;

    if (normalNetTotal < 0) {
      _showSnackBar(
        'الخصم لا يمكن أن يكون أكبر من إجمالي الفاتورة',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final netTotal =
        _isReturn ? -normalNetTotal : normalNetTotal;

    setState(() {
      _isSaving = true;
    });

    try {
      for (final item in validItems) {
        item.discountRate = 0;
        item.discountAmount = 0;
        if (_isReturn) {
          item.quantity = -item.quantity.abs();
        }
        item.total =
            item.quantity * item.price;
      }

      final serial =
          widget.editItem != null
              ? widget.editItem!.serial
              : _currentSerial;

      final model =
          SupplierTransactionModel(
        companyCode:
            widget.companyCode,

        branchCode:
            _selectedBranchCode ??
                'all',

        storeCode:
            _selectedStoreCode!,

        serial: serial,

        date:
            _selectedDate,

        supplierName:
            _selectedSupplier!,

        paymentMethod:
            _isReturn ? 'مرتجع' : 'آجل',

        treasury:
            '',

        isAddToStore:
            _isAddToStore,

        isAddToCoding:
            _isAddToCoding,

        employee:
    (widget.userName != null &&
            widget.userName!.trim().isNotEmpty)
        ? widget.userName!.trim()
        : 'غير محدد',

        items:
            validItems,

        totalAmount:
            netTotal,

        // لا يوجد دفع في فاتورة المشتريات
        paidAmount:
            0.0,

        docId:
            _editDocId,
      );

      final result =
          await _supplierService
              .saveSupplierTransaction(
        model,
      );

      if (result['success'] != true) {
        _showSnackBar(
          'فشل الحفظ: ${result['error'] ?? 'خطأ غير معروف'}',
          AppTheme.dangerStrongFor(context),
        );
        return;
      }

      _showSnackBar(
        widget.editItem != null
            ? 'تم تعديل حركة المورد بنجاح'
            : 'تم حفظ فاتورة المشتريات بنجاح',
        AppTheme.successStrongFor(context),
      );

      // ========================================================
      // تحديث رصيد المورد
      // ========================================================

      await _loadSupplierBalance(
        _selectedSupplier!,
      );

      // ========================================================
      // لو تعديل
      // ========================================================

      if (widget.editItem != null) {
        if (mounted) {
          Navigator.pop(
            context,
            true,
          );
        }

        return;
      }

      // ========================================================
      // فاتورة جديدة
      // ========================================================

      // داخل _handleSave بعد الحفظ الناجح
setState(() {
  _items.clear();
  _controllers.clear();
  _focusNodes.clear();

  _totalAmount = 0;
  _isUpdating = true;
  _discountPercent = 0;
  _discountAmount = 0;
  _discountPercentController.text = '0';
  _discountAmountController.text = '0.00';
  _isUpdating = false;

  _editDocId = null;
});

      _addEmptyRow();

      await _loadLastSerial();
    } catch (e) {
      _showSnackBar(
        'خطأ: $e',
        AppTheme.dangerStrongFor(context),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  // ============================================================
  // جدول الأصناف
  // ============================================================

  Widget _buildItemsTable() {
    final isMobile =
        MediaQuery.of(context).size.width <
            600;

    Widget content() {
      return Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(
              vertical: 4,
              horizontal: 4,
            ),
            decoration:
                BoxDecoration(
              color: GlassStyle.fill10For(context),
              borderRadius:
                  BorderRadius.circular(10),
            ),
            child: isMobile
                ? _buildMobileHeaders()
                : _buildDesktopHeaders(),
          ),

          const SizedBox(height: 4),

          ...List.generate(
            _items.length,
            (index) {
              final item =
                  _items[index];

              final isLast =
                  index ==
                      _items.length - 1;

              if (item.code.isEmpty &&
                  !isLast) {
                return const SizedBox
                    .shrink();
              }

              return Container(
                padding:
                    const EdgeInsets
                        .symmetric(
                  vertical: 2,
                ),
                decoration:
                    BoxDecoration(
                  border:
                      Border(
                    bottom:
                        BorderSide(
                      color: GlassStyle.line05For(context),
                      width: 0.5,
                    ),
                  ),
                ),
                child: isMobile
                    ? _buildMobileRow(
                        index,
                      )
                    : _buildDesktopRow(
                        index,
                      ),
              );
            },
          ),

          Padding(
            padding:
                const EdgeInsets.only(
              top: 4,
            ),
            child: InkWell(
              onTap:
                  _addEmptyRow,
              child:
                  Container(
                padding:
                    const EdgeInsets
                        .symmetric(
                  vertical: 8,
                ),
                decoration:
                    BoxDecoration(
                  border:
                      Border.all(
                    color: GlassStyle.line24For(context),
                  ),
                  borderRadius:
                      BorderRadius
                          .circular(
                    10,
                  ),
                ),
                child:
                    Center(
                  child: Text(
                    '+ إضافة صنف جديد',
                    style:
                        TextStyle(
                      color: AppTheme.accentFor(context),
                      fontFamily:
                          'Cairo',
                      fontSize: 13,
                    ),
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
        scrollDirection:
            Axis.horizontal,
        child: Container(
          constraints:
              BoxConstraints(
            minWidth:
                MediaQuery.of(context)
                        .size
                        .width *
                    1.45,
          ),
          child: content(),
        ),
      );
    }

    return content();
  }

  // ============================================================
  // موبايل Headers
  // ============================================================

  Widget _buildMobileHeaders() {
    const colWidth = 62.0;
    const nameWidth = 80.0;

    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            '#',
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color: AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ),
        SizedBox(
          width: colWidth,
          child: Text(
            'الكود',
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color: AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ),
        SizedBox(
          width: nameWidth,
          child: Text(
            'الصنف',
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color: AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ),
        SizedBox(
          width: colWidth,
          child: Text(
            'الكمية',
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color: AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ),
        SizedBox(
          width: colWidth,
          child: Text(
            'سعر الجملة',
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color:
                  AppTheme.successFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ),
        SizedBox(
          width: colWidth,
          child: Text(
            'الإجمالي',
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color:
                  AppTheme.successFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ),
        const SizedBox(
          width: 30,
        ),
      ],
    );
  }

  // ============================================================
  // Mobile Row
  // ============================================================

  Widget _buildMobileRow(
    int index,
  ) {
    final item =
        _items[index];

    const colWidth =
        62.0;

    const nameWidth =
        80.0;

    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            '${index + 1}',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.textHintFor(context),
              fontSize: 9,
            ),
          ),
        ),

        SizedBox(
          width: colWidth,
          child:
              _buildItemField(
            index,
            0,
          ),
        ),

        SizedBox(
          width: nameWidth,
          child:
              _buildItemField(
            index,
            1,
          ),
        ),

        SizedBox(
          width: colWidth,
          child:
              _buildItemField(
            index,
            2,
          ),
        ),

        SizedBox(
          width: colWidth,
          child:
              _buildItemField(
            index,
            3,
          ),
        ),

        SizedBox(
          width: colWidth,
          child: Text(
            item.total
                .toStringAsFixed(
              2,
            ),
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.successFor(context),
              fontSize: 10,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ),

        IconButton(
          icon:
              Icon(
            Icons.delete,
            color:
                AppTheme.dangerStrongFor(context),
            size: 18,
          ),
          onPressed:
              () => _removeRow(
            index,
          ),
          padding:
              EdgeInsets.zero,
          constraints:
              const BoxConstraints(),
        ),
      ],
    );
  }

  // ============================================================
  // Desktop Headers
  // ============================================================

  Widget _buildDesktopHeaders() {
    return Row(
      children: [
        Expanded(
          flex: 0,
          child:
              Text(
            '#',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child:
              Text(
            'الكود',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child:
              Text(
            'الصنف',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child:
              Text(
            'الكمية',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.accentAltFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child:
              Text(
            'سعر الجملة',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.successFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child:
              Text(
            'الإجمالي',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.successFor(context),
              fontWeight:
                  FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        SizedBox(
          width: 30,
        ),
      ],
    );
  }

  // ============================================================
  // Desktop Row
  // ============================================================

  Widget _buildDesktopRow(
    int index,
  ) {
    final item =
        _items[index];

    return Row(
      children: [
        Expanded(
          flex: 0,
          child:
              Text(
            '${index + 1}',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.textHintFor(context),
              fontSize: 10,
            ),
          ),
        ),

        Expanded(
          flex: 1,
          child:
              _buildItemField(
            index,
            0,
          ),
        ),

        Expanded(
          flex: 2,
          child:
              _buildItemField(
            index,
            1,
          ),
        ),

        Expanded(
          flex: 1,
          child:
              _buildItemField(
            index,
            2,
          ),
        ),

        Expanded(
          flex: 1,
          child:
              _buildItemField(
            index,
            3,
          ),
        ),

        Expanded(
          flex: 1,
          child:
              Text(
            item.total
                .toStringAsFixed(
              2,
            ),
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  AppTheme.successFor(context),
              fontSize: 11,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ),

        IconButton(
          icon:
              Icon(
            Icons.delete,
            color:
                AppTheme.dangerStrongFor(context),
            size: 20,
          ),
          onPressed:
              () => _removeRow(
            index,
          ),
          padding:
              EdgeInsets.zero,
          constraints:
              const BoxConstraints(),
        ),
      ],
    );
  }

  // ============================================================
  // حقل الصنف
  // ============================================================

    Widget _buildItemField(
    int rowIndex,
    int fieldIndex,
  ) {
    final field = _fieldOrder[fieldIndex];

    // ✅ حقل "الصنف" فقط: نستخدم RawAutocomplete
    if (field == 'name') {
      return _buildNameFieldWithSuggestions(rowIndex, fieldIndex);
    }

    final keyboard = (field == 'quantity' || field == 'price')
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextFormField(
        controller: _controllers[rowIndex][fieldIndex],
        focusNode: _focusNodes[rowIndex][fieldIndex],
        style: TextStyle(
          color: field == 'total'
              ? AppTheme.textSoftFor(context)
              : AppTheme.textMainFor(context),
          fontSize: 12,
        ),
        textAlign: TextAlign.center,
        keyboardType: keyboard,
        readOnly: field == 'total',
        textInputAction: TextInputAction.next,
        onChanged: field == 'total'
            ? null
            : (value) => _updateItem(rowIndex, fieldIndex, value),
        onFieldSubmitted: (_) => _onFieldSubmitted(rowIndex, fieldIndex),
        decoration: InputDecoration(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: GlassStyle.line24For(context)),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.accentFor(context)),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 6,
          ),
          isDense: true,
        ),
      ),
    );
  }

  // ============================================================
  // حقل الصنف مع اقتراحات تلقائية
  // ============================================================
  Widget _buildNameFieldWithSuggestions(
    int rowIndex,
    int fieldIndex,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: RawAutocomplete<Map<String, String>>(
        textEditingController: _controllers[rowIndex][fieldIndex],
        focusNode: _focusNodes[rowIndex][fieldIndex],
        displayStringForOption: (option) => option['name'] ?? '',
        optionsBuilder: (TextEditingValue textValue) {
          final query = textValue.text.trim();
          if (query.isEmpty) {
            return const Iterable<Map<String, String>>.empty();
          }
          return _itemsLookup.where(
            (item) => (item['name'] ?? '').contains(query),
          );
        },
        onSelected: (option) {
          _fillRowFromSelectedItem(rowIndex, option);
        },
        fieldViewBuilder:
            (context, controller, focusNode, onFieldSubmitted) {
          return CompositedTransformTarget(
            link: _nameFieldLinks[rowIndex],
            child: TextFormField(
              controller: controller,
              focusNode: focusNode,
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              onChanged: (value) =>
                  _updateItem(rowIndex, fieldIndex, value),
              onFieldSubmitted: (_) =>
                  _onFieldSubmitted(rowIndex, fieldIndex),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide:
                      BorderSide(color: GlassStyle.line24For(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide:
                      BorderSide(color: AppTheme.accentFor(context)),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 6,
                ),
                isDense: true,
              ),
            ),
          );
        },
        optionsViewBuilder: (context, onSelected, options) {
          // ✅ عرض ثابت صريح — تحكم به من رقم واحد
          const double boxWidth = 150.0;

          return CompositedTransformFollower(
            link: _nameFieldLinks[rowIndex],
            showWhenUnlinked: false,
            // ✅ في RTL: نربط بالحافة اليمنى للحقل
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 6),
            child: Align(
              alignment: Alignment.topRight,
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: Material(
                elevation: 8,
                color: AppTheme.dropdownBackground(context),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: boxWidth,
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options.elementAt(index);
                      return InkWell(
                        onTap: () => onSelected(option),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                option['name'] ?? '',
                                style: TextStyle(
                                  color: AppTheme.textMainFor(context),
                                  fontSize: 12,
                                  fontFamily: 'Cairo',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 1),
                              Text(
                                'كود: ${option['code']}',
                                style: TextStyle(
                                  color: AppTheme.textMutedFor(context),
                                  fontSize: 9,
                                  fontFamily: 'Cairo',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ============================================================
  // بطاقة الرصيد
  // ============================================================

  Widget _buildBalanceCard() {
    if (_selectedSupplier ==
            null ||
        _selectedSupplier!.isEmpty) {
      return const SizedBox
          .shrink();
    }

    return GlassCard(
      child: Container(
        padding:
            const EdgeInsets
                .symmetric(
          vertical: 8,
          horizontal: 12,
        ),
        decoration:
            BoxDecoration(
          gradient:
              LinearGradient(
            colors: [
              GlassStyle.successFill15For(context),
              GlassStyle.successFill05For(context),
            ],
          ),
          borderRadius:
              BorderRadius.circular(
            10,
          ),
          border:
              Border.all(
            color: GlassStyle.successBorder30For(context),
          ),
        ),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment
                  .spaceBetween,
          children: [
            Text(
              'الرصيد',
              style:
                  TextStyle(
                color:
                    AppTheme.textSoftFor(context),
                fontSize: 14,
                fontFamily:
                    'Cairo',
              ),
            ),
            Row(
              children: [
                Icon(
                  Icons.trending_up,
                  color:
                      AppTheme.successFor(context),
                  size: 22,
                ),
                const SizedBox(
                  width: 6,
                ),
                Text(
                  _expectedBalance
                      .toStringAsFixed(
                    2,
                  ),
                  style:
                      TextStyle(
                    color:
                        AppTheme.successFor(context),
                    fontSize: 20,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // المخزن
  // ============================================================

  Widget _buildStoreDropdown() {
    return DropdownButtonFormField<String?>(
      initialValue:
          _selectedStoreCode,
      dropdownColor: AppTheme.dropdownBackground(context),
      style:
          TextStyle(
        color: AppTheme.textMainFor(context),
        fontSize: 13,
      ),
      decoration:
          InputDecoration(
        labelText:
            'المخزن',
        labelStyle:
            TextStyle(
          color:
              AppTheme.textSoftFor(context),
          fontSize: 11,
        ),
        border:
            OutlineInputBorder(
          borderRadius:
              BorderRadius.circular(
            10,
          ),
        ),
        enabledBorder:
            OutlineInputBorder(
          borderSide:
              BorderSide(
            color:
                GlassStyle.line24For(context),
          ),
        ),
        isDense:
            true,
        contentPadding:
            const EdgeInsets
                .symmetric(
          horizontal: 6,
          vertical: 6,
        ),
      ),
      items:
          _stores.map(
        (store) {
          return DropdownMenuItem<String?>(
            value:
                store['code'],
            child:
                Text(
              store['name'] ??
                  '',
              style:
                  TextStyle(
                fontSize:
                    12,
              ),
            ),
          );
        },
      ).toList(),
      onChanged:
          (value) {
        setState(() {
          _selectedStoreCode =
              value;
        });
      },
    );
  }

  // ============================================================
  // إضافة للمخزن
  // ============================================================

  Widget _buildReturnToggle() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('مرتجع', style: TextStyle(color: _isReturn ? AppTheme.dangerFor(context) : AppTheme.textHintFor(context), fontSize: 10, fontFamily: 'Cairo')),
        Switch(
          value: _isReturn,
          onChanged: (value) {
            setState(() {
              _isReturn = value;
              if (value) {
                _isAddToStore = true;
                _isAddToCoding = false;
              }
              _updateExpectedBalance();
            });
          },
          activeThumbColor: AppTheme.dangerFor(context),
          inactiveThumbColor: AppTheme.neutralFor(context),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _buildAddToStoreToggle() {
    return Column(
      mainAxisSize:
          MainAxisSize.min,
      children: [
        Text(
          'إضافة للمخزن',
          style:
              TextStyle(
            color:
                _isAddToStore
                    ? AppTheme.successFor(context)
                    : AppTheme.textHintFor(context),
            fontSize: 10,
            fontFamily:
                'Cairo',
          ),
        ),
        Switch(
          value:
              _isAddToStore,
          onChanged:
              (value) {
            setState(() {
              _isAddToStore =
                  value;
            });
          },
          activeThumbColor:
              AppTheme.successFor(context),
          inactiveThumbColor:
              AppTheme.neutralFor(context),
          materialTapTargetSize:
              MaterialTapTargetSize
                  .shrinkWrap,
        ),
      ],
    );
  }

  // ============================================================
  // تحديث التكويد
  // ============================================================

  Widget _buildAddToCodingToggle() {
    return Column(
      mainAxisSize:
          MainAxisSize.min,
      children: [
        Text(
          'تحديث التكويد',
          style:
              TextStyle(
            color:
                _isAddToCoding
                    ? AppTheme.accentFor(context)
                    : AppTheme.textHintFor(context),
            fontSize: 10,
            fontFamily:
                'Cairo',
          ),
        ),
        Switch(
          value:
              _isAddToCoding,
          onChanged:
              (value) {
            setState(() {
              _isAddToCoding =
                  value;
            });
          },
          activeThumbColor:
              AppTheme.accentFor(context),
          inactiveThumbColor:
              AppTheme.neutralFor(context),
          materialTapTargetSize:
              MaterialTapTargetSize
                  .shrinkWrap,
        ),
      ],
    );
  }

  // ============================================================
  // المورد
  // ============================================================

  Widget _buildSupplierDropdown() {
    return DropdownButtonFormField<String?>(
      initialValue:
          _selectedSupplier,
      dropdownColor: AppTheme.dropdownBackground(context),
      style:
          TextStyle(
        color: AppTheme.textMainFor(context),
        fontSize: 13,
      ),
      isExpanded:
          true,
      decoration:
          InputDecoration(
        labelText:
            'المورد',
        labelStyle:
            TextStyle(
          color:
              AppTheme.textSoftFor(context),
          fontSize: 11,
        ),
        border:
            OutlineInputBorder(
          borderRadius:
              BorderRadius.circular(
            10,
          ),
        ),
        enabledBorder:
            OutlineInputBorder(
          borderSide:
              BorderSide(
            color:
                GlassStyle.line24For(context),
          ),
        ),
        isDense:
            true,
        contentPadding:
            const EdgeInsets
                .symmetric(
          horizontal: 6,
          vertical: 6,
        ),
      ),
      items:
          _suppliers.map(
        (supplier) {
          return DropdownMenuItem<String?>(
            value:
                supplier['name'],
            child:
                Text(
              supplier['name'] ??
                  '',
              style:
                  TextStyle(
                fontSize:
                    12,
              ),
            ),
          );
        },
      ).toList(),
      onChanged:
          (value) {
        setState(() {
          _selectedSupplier =
              value;
        });

        if (value != null &&
            value.isNotEmpty) {
          _loadSupplierBalance(
            value,
          );
        }
      },
    );
  }

  // ============================================================
  // SnackBar
  // ============================================================

  void _showSnackBar(
    String message,
    Color color,
  ) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content:
            Text(
          message,
          textAlign:
              TextAlign.center,
          style:
              TextStyle(
            fontFamily:
                'Cairo',
          ),
        ),
        backgroundColor:
            color,
        duration:
            const Duration(
          seconds: 3,
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
        .canShowSuppliers) {
      return Scaffold(
        appBar:
            AppBar(
          title:
              Text(
            'المشتريات',
            style:
                TextStyle(
              color:
                  AppTheme.textMainFor(context),
            ),
          ),
          backgroundColor:
              AppTheme.appBarBg,
        ),
        body:
            Container(
          decoration:
              BoxDecoration(gradient: LinearGradient(colors: AppTheme.pageGradient(context))),
          child:
              Center(
            child:
                Text(
              'ليس لديك صلاحية لعرض المشتريات',
              style:
                  TextStyle(
                color:
                    AppTheme.textSoftFor(context),
                fontFamily:
                    'Cairo',
                fontSize:
                    16,
              ),
            ),
          ),
        ),
      );
    }

    final isMobile =
        MediaQuery.of(context)
                .size
                .width <
            600;

    return PopScope(
      canPop:
          false,
      onPopInvoked:
          (didPop) {
        if (!didPop &&
            mounted) {
          Navigator.pop(
            context,
          );
        }
      },
      child:
          Scaffold(
        extendBodyBehindAppBar:
            true,

        appBar:
            AppBar(
          title:
              Row(
            mainAxisAlignment:
                MainAxisAlignment
                    .spaceBetween,
            children: [
              Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                mainAxisSize:
                    MainAxisSize.min,
                children: [
                  Text(
                    'المشتريات',
                    style:
                        TextStyle(
                      fontFamily:
                          'Cairo',
                      color:
                          AppTheme.textMainFor(context),
                      fontSize:
                          15,
                    ),
                  ),
                  if (_currentSerial >
                      0)
                    Text(
                      'إذن رقم: $_currentSerial',
                      style:
                          TextStyle(
                        fontFamily:
                            'Cairo',
                        fontSize:
                            13,
                        color:
                            AppTheme.accentFor(context),
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  Text(
                    _getBranchName(
                      _selectedBranchCode,
                    ),
                    style:
                        TextStyle(
                      fontFamily:
                          'Cairo',
                      fontSize:
                          10,
                      color:
                          AppTheme.textMutedFor(context),
                    ),
                  ),
                ],
              ),

              GestureDetector(
                onTap:
                    _pickDate,
                child:
                    Container(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal:
                        10,
                    vertical:
                        6,
                  ),
                  decoration:
                      BoxDecoration(
                    color: GlassStyle.fill08For(context),
                    borderRadius:
                        BorderRadius
                            .circular(
                      8,
                    ),
                    border:
                        Border.all(
                      color:
                          GlassStyle.line24For(context),
                    ),
                  ),
                  child:
                      Row(
                    children: [
                      Icon(
                        Icons
                            .calendar_today,
                        color:
                            AppTheme.warningFor(context),
                        size:
                            16,
                      ),
                      const SizedBox(
                        width:
                            6,
                      ),
                      Text(
                        _selectedDate,
                        style:
                            TextStyle(
                          color:
                              AppTheme.textMainFor(context),
                          fontSize:
                              13,
                          fontFamily:
                              'Cairo',
                          fontWeight:
                              FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          backgroundColor:
              AppTheme.appBarBg,
          elevation:
              0,
          centerTitle:
              false,
          toolbarHeight:
              80,
        ),

        body:
            Container(
          decoration:
              BoxDecoration(gradient: LinearGradient(colors: AppTheme.pageGradient(context))),
          child:
              SafeArea(
            child:
                (_isLoading ||
                        _isSaving)
                    ? Center(
                        child:
                            CircularProgressIndicator(
                          color:
                              AppTheme.textMainFor(context),
                        ),
                      )
                    : SingleChildScrollView(
                        controller:
                            _scrollController,
                        padding:
                            const EdgeInsets
                                .symmetric(
                          horizontal:
                              6,
                          vertical:
                              4,
                        ),
                        child:
                            Column(
                          children: [
                            // ========================
                            // الرصيد
                            // ========================

                            _buildBalanceCard(),

                            const SizedBox(
                              height:
                                  6,
                            ),

                            // ========================
                            // المورد / المخزن
                            // ========================

                            GlassCard(
                              child:
                                  Container(
                                padding:
                                    const EdgeInsets.all(
                                  6,
                                ),
                                child:
                                    isMobile
                                        ? Column(
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    flex:
                                                        4,
                                                    child:
                                                        _buildSupplierDropdown(),
                                                  ),
                                                  const SizedBox(
                                                    width:
                                                        4,
                                                  ),
                                                  IconButton(
                                                    icon:
                                                        Icon(
                                                      Icons
                                                          .add_circle,
                                                      color:
                                                          AppTheme.warningFor(context),
                                                      size:
                                                          20,
                                                    ),
                                                    onPressed:
                                                        () {
                                                      Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder:
                                                              (c) =>
                                                                  CodingPage(
                                                            companyCode:
                                                                widget.companyCode,
                                                          ),
                                                        ),
                                                      ).then(
                                                        (_) =>
                                                            _loadDropdowns(),
                                                      );
                                                    },
                                                    tooltip:
                                                        'إضافة مورد',
                                                    padding:
                                                        EdgeInsets.zero,
                                                    constraints:
                                                        const BoxConstraints(),
                                                  ),
                                                ],
                                              ),

                                              const SizedBox(
                                                height:
                                                    4,
                                              ),

                                              Row(
                                                children: [
                                                  Expanded(
                                                    flex:
                                                        2,
                                                    child:
                                                        _buildStoreDropdown(),
                                                  ),
                                                  const SizedBox(
                                                    width:
                                                        6,
                                                  ),
                                                  Expanded(
                                                    flex:
                                                        1,
                                                    child:
                                                        _buildReturnToggle(),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    flex:
                                                        1,
                                                    child:
                                                        _buildAddToStoreToggle(),
                                                  ),
                                                  const SizedBox(
                                                    width:
                                                        6,
                                                  ),
                                                  Expanded(
                                                    flex:
                                                        1,
                                                    child:
                                                        _buildAddToCodingToggle(),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          )
                                        : Row(
                                            children: [
                                              Expanded(
                                                flex:
                                                    3,
                                                child:
                                                    _buildSupplierDropdown(),
                                              ),
                                              const SizedBox(
                                                width:
                                                    6,
                                              ),
                                              IconButton(
                                                icon:
                                                    Icon(
                                                  Icons
                                                      .add_circle,
                                                  color:
                                                      AppTheme.warningFor(context),
                                                  size:
                                                      20,
                                                ),
                                                onPressed:
                                                    () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder:
                                                          (c) =>
                                                              CodingPage(
                                                        companyCode:
                                                            widget.companyCode,
                                                      ),
                                                    ),
                                                  ).then(
                                                    (_) =>
                                                        _loadDropdowns(),
                                                  );
                                                },
                                                tooltip:
                                                    'إضافة مورد',
                                                padding:
                                                    EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                              ),
                                              const SizedBox(
                                                width:
                                                    10,
                                              ),
                                              Expanded(
                                                flex:
                                                    2,
                                                child:
                                                    _buildStoreDropdown(),
                                              ),
                                              const SizedBox(
                                                width:
                                                    10,
                                              ),
                                              Expanded(
                                                flex:
                                                    1,
                                                child:
                                                    _buildReturnToggle(),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                flex:
                                                    1,
                                                child:
                                                    _buildAddToStoreToggle(),
                                              ),
                                              const SizedBox(
                                                width:
                                                    8,
                                              ),
                                              Expanded(
                                                flex:
                                                    1,
                                                child:
                                                    _buildAddToCodingToggle(),
                                              ),
                                            ],
                                          ),
                              ),
                            ),

                            const SizedBox(
                              height:
                                  6,
                            ),

                            // ========================
                            // الأصناف
                            // ========================

                            GlassCard(
                              child:
                                  Container(
                                padding:
                                    const EdgeInsets.all(
                                  6,
                                ),
                                child:
                                    _buildItemsTable(),
                              ),
                            ),

                            const SizedBox(
                              height:
                                  6,
                            ),

                            // ========================
                            // الخصم والإجمالي
                            // ========================

                            GlassCard(
                              child:
                                  Container(
                                padding:
                                    const EdgeInsets.all(
                                  6,
                                ),
                                child:
                                    Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex:
                                          2,
                                      child:
                                          Column(
                                        children: [
                                          TextFormField(
                                            controller: _discountPercentController,
  onChanged: (_) => _onDiscountPercentChanged(),
                                            style:
                                                TextStyle(
                                              color:
                                                  AppTheme.textMainFor(context),
                                              fontSize:
                                                  13,
                                            ),
                                            textAlign:
                                                TextAlign.center,
                                            keyboardType:
                                                TextInputType.number,
                                            decoration:
                                                InputDecoration(
                                              labelText:
                                                  'نسبة الخصم %',
                                              labelStyle:
                                                  TextStyle(
                                                color:
                                                    AppTheme.textSoftFor(context),
                                                fontSize:
                                                    11,
                                              ),
                                              border:
                                                  OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                  8,
                                                ),
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal:
                                                    4,
                                                vertical:
                                                    8,
                                              ),
                                              isDense:
                                                  true,
                                            ),
                                          ),

                                          const SizedBox(
                                            height:
                                                6,
                                          ),

                                          TextFormField(
                                            controller: _discountAmountController,
  onChanged: (_) => _onDiscountAmountChanged(),
                                            style:
                                                TextStyle(
                                              color:
                                                  AppTheme.textMainFor(context),
                                              fontSize:
                                                  13,
                                            ),
                                            textAlign:
                                                TextAlign.center,
                                            keyboardType:
                                                TextInputType.number,
                                            decoration:
                                                InputDecoration(
                                              labelText:
                                                  'مبلغ الخصم',
                                              labelStyle:
                                                  TextStyle(
                                                color:
                                                    AppTheme.textSoftFor(context),
                                                fontSize:
                                                    11,
                                              ),
                                              border:
                                                  OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                  8,
                                                ),
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal:
                                                    4,
                                                vertical:
                                                    8,
                                              ),
                                              isDense:
                                                  true,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    const SizedBox(
                                      width:
                                          10,
                                    ),

                                    Expanded(
                                      flex:
                                          3,
                                      child:
                                          Container(
                                        padding:
                                            const EdgeInsets.symmetric(
                                          vertical:
                                              8,
                                          horizontal:
                                              10,
                                        ),
                                        decoration:
                                            BoxDecoration(
                                          color: GlassStyle.successFill10For(context),
                                          borderRadius:
                                              BorderRadius.circular(
                                            8,
                                          ),
                                          border:
                                              Border.all(
                                            color: GlassStyle.successBorder30For(context),
                                          ),
                                        ),
                                        child:
                                            Center(
                                          child:
                                              Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                'الإجمالي بعد الخصم',
                                                style:
                                                    TextStyle(
                                                  color:
                                                      AppTheme.textSoftFor(context),
                                                  fontSize:
                                                      13,
                                                  fontFamily:
                                                      'Cairo',
                                                ),
                                              ),
                                              const SizedBox(
                                                height:
                                                    2,
                                              ),
                                              Text(
                                                netTotalText(),
                                                style:
                                                    TextStyle(
                                                  color:
                                                      AppTheme.successFor(context),
                                                  fontSize:
                                                      16,
                                                  fontWeight:
                                                      FontWeight.bold,
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

                            const SizedBox(
                              height:
                                  6,
                            ),

                            // ========================
                            // الأزرار
                            // ========================

                            Row(
                              children: [
                                Expanded(
                                  child:
                                      ElevatedButton(
                                    onPressed:
                                        _handleSave,
                                    style:
                                        ElevatedButton.styleFrom(
                                      backgroundColor:
                                          AppTheme.successFor(context),
                                      foregroundColor:
                                          AppTheme.onAccentFor(context),
                                      padding:
                                          const EdgeInsets.symmetric(
                                        vertical:
                                            10,
                                      ),
                                      shape:
                                          RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(
                                          10,
                                        ),
                                      ),
                                    ),
                                    child:
                                        Text(
                                      _isSaving
                                          ? 'جاري الحفظ...'
                                          : 'حفظ',
                                      style:
                                          TextStyle(
                                        fontSize:
                                            14,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(
                                  width:
                                      8,
                                ),

                                Expanded(
                                  child:
                                      ElevatedButton(
                                    onPressed:
                                        () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder:
                                              (c) =>
                                                  SupplierHistoryPage(
                                            companyCode:
                                                widget.companyCode,
                                            selectedBranchCode:
                                                _selectedBranchCode,
                                          ),
                                        ),
                                      );
                                    },
                                    style:
                                        ElevatedButton.styleFrom(
                                      backgroundColor:
                                          GlassStyle.fill10For(context),
                                      foregroundColor:
                                          Theme.of(context).colorScheme.onPrimary,
                                      padding:
                                          const EdgeInsets.symmetric(
                                        vertical:
                                            10,
                                      ),
                                      shape:
                                          RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(
                                          10,
                                        ),
                                      ),
                                    ),
                                    child:
                                        const Text(
                                      'معاينة',
                                      style:
                                          TextStyle(
                                        fontSize:
                                            14,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(
                              height:
                                  4,
                            ),
                          ],
                        ),
                      ),
          ),
        ),
      ),
    );
  }

  String netTotalText() {
    return (_totalAmount -
            _discountAmount)
        .toStringAsFixed(
      2,
    );
  }

  // ============================================================
  // Dispose
  // ============================================================

  @override
  void dispose() {
    for (final row
        in _controllers) {
      for (final controller
          in row) {
        controller.dispose();
      }
    }

    for (final row
        in _focusNodes) {
      for (final focus
          in row) {
        focus.dispose();
      }
    }

    _scrollController.dispose();

    _discountPercentController
        .dispose();

    _discountAmountController
        .dispose();

    super.dispose();
  }
}