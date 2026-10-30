// lib/views/dashboard/inventory_page.dart

import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/inventory_service.dart';
import '../../services/coding_service.dart';
import '../../models/inventory_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import 'inventory_history_page.dart';

class InventoryPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? branchName;
  final InventoryModel? editItem;

  const InventoryPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.branchName,
    this.editItem,
  });

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final InventoryService _inventoryService = InventoryService();
  final CodingService _codingService = CodingService();

  String? _selectedBranchCode;
  String? _selectedStoreCode;
  String _selectedDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  String _inventoryType = 'general';

  List<InventoryItem> _items = [];
  bool _isLoading = false;
  bool _isSaving = false;
  int? _currentSerial;

  List<Map<String, String>> _stores = [];
  List<Map<String, String>> _itemsLookup = []; // ✅ قائمة الأصناف المقترحة
  List<List<TextEditingController>> _controllers = [];
  List<List<FocusNode>> _focusNodes = [];
  List<LayerLink> _nameFieldLinks = []; // ✅ روابط الحقول لعرض القائمة أسفلها
  final ScrollController _scrollController = ScrollController();

  static const List<String> _fieldOrder = [
    'code',
    'name',
    'quantity',
    'wholesalePrice',
    'retailPrice',
  ];

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
  }

  // ============================================================
  // تنسيق الأرقام - أرقام إنجليزية + الاحتفاظ بالكسور
  // ============================================================

  String _formatNumber(double value) {
    if (value == 0) return '0';
    if (value % 1 == 0) return value.toStringAsFixed(0);
    return value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _formatDecimal(double value) {
    return value.toStringAsFixed(2);
  }

  // ============================================================
  // اسم الفرع
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

    return code;
  }

  // ============================================================
  // تحميل القوائم
  // ============================================================

  Future<void> _loadDropdowns() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();

      _selectedBranchCode =
          widget.selectedBranchCode ??
          prefs.getString('selected_branch_code') ??
          'all';

      final box = Hive.box('coding_box');

      final rawStores = box.get(
            '${widget.companyCode}_stores',
            defaultValue: [],
          ) as List? ??
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
      // ✅ تحميل الأصناف للاقتراحات
      await _loadItemsLookup();
      if (widget.editItem != null) {
        _loadEditData();
      } else {
        if (_stores.isNotEmpty &&
            _selectedStoreCode == null) {
          _selectedStoreCode = _stores.first['code'];
        }

        await _loadLastSerial();
        _addEmptyRow();
      }
    } catch (e) {
      debugPrint('❌ خطأ في تحميل القوائم: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
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
          'selling_price':
              (e['selling_price'] ?? e['sellingPrice'] ?? '0').toString(),
        });
      }
    }

    if (mounted) {
      setState(() {
        _itemsLookup = list;
      });
    }
  } catch (e) {
    debugPrint('❌ خطأ في تحميل الأصناف للاقتراحات: $e');
  }
}

  // ============================================================
  // تحميل التعديل
  // ============================================================

  void _loadEditData() {
    final model = widget.editItem!;

    _selectedBranchCode = model.branchCode;
    _selectedStoreCode = model.storeCode;
    _selectedDate = model.date;
    _inventoryType = model.inventoryType;
    _currentSerial = model.serial;

    _items = model.items
        .map(
          (item) => InventoryItem(
            code: item.code,
            name: item.name,
            quantity: item.quantity,
            wholesalePrice: item.wholesalePrice,
            retailPrice: item.retailPrice,
            wholesaleValue: item.wholesaleValue,
            retailValue: item.retailValue,
          ),
        )
        .toList();

    _items.add(
      InventoryItem(
        code: '',
        name: '',
        quantity: 0,
        wholesalePrice: 0,
        retailPrice: 0,
      ),
    );

    _rebuildControllersAndFocus();
  }

  // ============================================================
  // Controllers + Focus
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
    _nameFieldLinks.clear(); // ✅ نظّف الروابط
    for (final item in _items) {
      final controllers = <TextEditingController>[];
      final focusNodes = <FocusNode>[];

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
            value = _formatNumber(item.quantity);
            break;
          case 'wholesalePrice':
            value = item.wholesalePrice.toString();
            break;
          case 'retailPrice':
            value = item.retailPrice.toString();
            break;
        }

        controllers.add(
          TextEditingController(text: value),
        );

        focusNodes.add(FocusNode());
      }

      _controllers.add(controllers);
      _focusNodes.add(focusNodes);
      _nameFieldLinks.add(LayerLink()); // ✅ أضف رابطاً لكل صف
    }
  }

  // ============================================================
  // السيريال
  // ============================================================

  Future<void> _loadLastSerial() async {
    try {
      final box = Hive.box('inventory_box');
      final branchCode = _selectedBranchCode ?? 'all';

      int maxSerial = 0;

      for (final key in box.keys) {
        final raw = box.get(key);

        if (raw is! List) continue;

        for (final item in raw) {
          if (item is! Map) continue;

          if (item['is_deleted'] == true) continue;

          if (item['company_code']?.toString() !=
              widget.companyCode) {
            continue;
          }

          if (item['branch_code']?.toString() !=
              branchCode) {
            continue;
          }

          final serial =
              int.tryParse(
                    item['serial']?.toString() ?? '0',
                  ) ??
                  0;

          if (serial > maxSerial) {
            maxSerial = serial;
          }
        }
      }

      if (!mounted) return;

      setState(() {
        _currentSerial = maxSerial + 1;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentSerial = 1;
        });
      }
    }
  }

  // ============================================================
  // إضافة صف
  // ============================================================

  void _addEmptyRow() {
    if (_items.isNotEmpty) {
      final last = _items.last;

      if (last.code.isEmpty &&
          last.name.isEmpty &&
          last.quantity == 0 &&
          last.wholesalePrice == 0 &&
          last.retailPrice == 0) {
        return;
      }
    }

    setState(() {
      _items.add(
        InventoryItem(
          code: '',
          name: '',
          quantity: 0,
          wholesalePrice: 0,
          retailPrice: 0,
        ),
      );

      _controllers.add(
        List.generate(
          5,
          (_) => TextEditingController(),
        ),
      );

      _focusNodes.add(
        List.generate(
          5,
          (_) => FocusNode(),
        ),
      );
      _nameFieldLinks.add(LayerLink()); // ✅ رابط للصف الجديد
    });
  }

  // ============================================================
  // حذف صف
  // ============================================================

  void _removeRow(int index) {
    if (_items.length <= 1) return;

    setState(() {
      _items.removeAt(index);

      for (final controller in _controllers[index]) {
        controller.dispose();
      }

      for (final focus in _focusNodes[index]) {
        focus.dispose();
      }

      _controllers.removeAt(index);
      _focusNodes.removeAt(index);
      _nameFieldLinks.removeAt(index); // ✅ احذف الرابط
    });
  }

  // ============================================================
  // تغيير الحقول
  // ============================================================

  void _onFieldChanged(
    int rowIndex,
    int fieldIndex,
  ) {
    if (rowIndex >= _items.length ||
        rowIndex >= _controllers.length) {
      return;
    }

    final item = _items[rowIndex];
    final value =
        _controllers[rowIndex][fieldIndex]
            .text
            .trim();

    switch (_fieldOrder[fieldIndex]) {
      case 'code':
        if (item.code != value) {
          item.code = value;

          if (value.isNotEmpty) {
            _autoFillItem(rowIndex);
          }
        }
        break;

      case 'name':
        item.name = value;
        break;

      case 'quantity':
        item.quantity =
            double.tryParse(value) ?? 0.0;
        break;

      case 'wholesalePrice':
        item.wholesalePrice =
            double.tryParse(value) ?? 0.0;
        break;

      case 'retailPrice':
        item.retailPrice =
            double.tryParse(value) ?? 0.0;
        break;
    }

    _recalcItem(rowIndex);

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // حساب القيمة
  // ============================================================

  void _recalcItem(int index) {
    if (index < 0 ||
        index >= _items.length) {
      return;
    }

    final item = _items[index];

    item.wholesaleValue =
        item.wholesalePrice *
        item.quantity;

    item.retailValue =
        item.retailPrice *
        item.quantity;
  }

  // ============================================================
  // التعبئة التلقائية
  // ============================================================

  Future<void> _autoFillItem(int index) async {
    if (index >= _items.length) return;

    final code =
        _items[index].code.trim();

    if (code.isEmpty) return;

    final box = Hive.box('coding_box');

    final raw = box.get(
      '${widget.companyCode}_items',
      defaultValue: [],
    );

    if (raw is List) {
      for (final rawItem in raw) {
        if (rawItem is! Map) continue;

        if (rawItem['code']?.toString() != code) {
          continue;
        }

        final name =
            rawItem['name']?.toString() ?? '';

        final wholesale =
            double.tryParse(
                  rawItem['wholesale_price']
                          ?.toString() ??
                      '0',
                ) ??
                0.0;

        final retail =
            double.tryParse(
                  rawItem['selling_price']
                          ?.toString() ??
                      '0',
                ) ??
                0.0;

        if (!mounted ||
            index >= _items.length) {
          return;
        }

        setState(() {
          _items[index].name = name;
          _items[index].wholesalePrice =
              wholesale;
          _items[index].retailPrice =
              retail;

          _recalcItem(index);

          _controllers[index][1].text =
              name;
          _controllers[index][3].text =
              wholesale.toString();
          _controllers[index][4].text =
              retail.toString();
        });

        return;
      }
    }

    try {
      final list =
          await _codingService.getCodingList(
        companyCode:
            widget.companyCode,
        category:
            'items',
      );

      for (final item in list) {
        if (item.code != code) continue;

        if (!mounted ||
            index >= _items.length) {
          return;
        }

        setState(() {
          _items[index].name =
              item.name;

          _items[index].wholesalePrice =
              item.wholesalePrice;

          _items[index].retailPrice =
              item.sellingPrice;

          _recalcItem(index);

          _controllers[index][1].text =
              item.name;

          _controllers[index][3].text =
              item.wholesalePrice.toString();

          _controllers[index][4].text =
              item.sellingPrice.toString();
        });

        return;
      }
    } catch (e) {
      debugPrint(
        '❌ خطأ في جلب الصنف: $e',
      );
    }
  }

// ============================================================
// تعبئة الصف عند اختيار صنف من القائمة المنسدلة
// ============================================================
void _fillRowFromSelectedItem(
  int rowIndex,
  Map<String, String> item,
) {
  if (rowIndex >= _items.length) return;

  final code = item['code'] ?? '';
  final name = item['name'] ?? '';
  final wholesale =
      double.tryParse(item['wholesale_price'] ?? '0') ?? 0.0;
  final retail =
      double.tryParse(item['selling_price'] ?? '0') ?? 0.0;

  setState(() {
    _items[rowIndex].code = code;
    _items[rowIndex].name = name;
    _items[rowIndex].wholesalePrice = wholesale;
    _items[rowIndex].retailPrice = retail;

    _controllers[rowIndex][0].text = code;
    _controllers[rowIndex][1].text = name;
    _controllers[rowIndex][3].text = wholesale.toString();
    _controllers[rowIndex][4].text = retail.toString();

    _recalcItem(rowIndex);
  });
}

  // ============================================================
  // Enter
  // ============================================================

  void _onFieldSubmitted(
    int rowIndex,
    int fieldIndex,
  ) {
    _onFieldChanged(
      rowIndex,
      fieldIndex,
    );

    final next =
        fieldIndex + 1;

    if (next < _fieldOrder.length) {
      _focusNodes[rowIndex][next]
          .requestFocus();
      return;
    }

    _addEmptyRow();

    WidgetsBinding.instance
        .addPostFrameCallback((_) {
      if (!mounted ||
          rowIndex + 1 >=
              _focusNodes.length) {
        return;
      }

      _focusNodes[rowIndex + 1][0]
          .requestFocus();

      if (_scrollController
          .hasClients) {
        _scrollController.animateTo(
          _scrollController
              .position
              .maxScrollExtent,
          duration:
              const Duration(
            milliseconds: 300,
          ),
          curve:
              Curves.easeOut,
        );
      }
    });
  }

  // ============================================================
  // الإجماليات
  // ============================================================

  double get totalWholesale =>
      _items.fold<double>(
        0.0,
        (sum, item) =>
            sum + item.wholesaleValue,
      );

  double get totalRetail =>
      _items.fold<double>(
        0.0,
        (sum, item) =>
            sum + item.retailValue,
      );

  double get totalQuantity =>
      _items.fold<double>(
        0.0,
        (sum, item) =>
            sum + item.quantity,
      );

  // ============================================================
  // حفظ
  // ============================================================

  Future<void> _saveInventory() async {
    final isEdit =
        widget.editItem != null;

    final allowed = isEdit
        ? PermissionsService()
            .canEditInventory
        : PermissionsService()
            .canAddInventory;

    if (!allowed) {
      _showSnackBar(
        isEdit
            ? 'ليس لديك صلاحية تعديل الجرد'
            : 'ليس لديك صلاحية إضافة الجرد',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    for (int i = 0;
        i < _items.length;
        i++) {
      for (int j = 0;
          j < _fieldOrder.length;
          j++) {
        _onFieldChanged(
          i,
          j,
        );
      }
    }

    final validItems =
        _items.where(
      (item) =>
          item.code.trim().isNotEmpty &&
          item.quantity > 0,
    ).toList();

    if (validItems.isEmpty) {
      _showSnackBar(
        'أضف صنفاً واحداً على الأقل',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (_selectedBranchCode == null ||
        _selectedBranchCode!.isEmpty ||
        _selectedBranchCode == 'all') {
      _showSnackBar(
        'يجب تحديد الفرع',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    if (_selectedStoreCode == null ||
        _selectedStoreCode!.isEmpty) {
      _showSnackBar(
        'اختر المخزن',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      for (final item in validItems) {
        item.wholesaleValue =
            item.wholesalePrice *
            item.quantity;

        item.retailValue =
            item.retailPrice *
            item.quantity;
      }

      final model =
          InventoryModel(
        companyCode:
            widget.companyCode,
        branchCode:
            _selectedBranchCode!,
        storeCode:
            _selectedStoreCode!,
        date:
            _selectedDate,
        inventoryType:
            _inventoryType,
        items:
            validItems,
        totalWholesale:
            totalWholesale,
        totalRetail:
            totalRetail,
        serial:
            widget.editItem?.serial ??
                _currentSerial,
        docId:
            widget.editItem?.docId,
      );

      final result =
          await _inventoryService
              .saveInventory(
        model,
      );

      if (result['success'] == true) {
        _showSnackBar(
          isEdit
              ? 'تم تحديث الجرد بنجاح'
              : 'تم حفظ الجرد بنجاح',
          AppTheme.successStrongFor(context),
        );

        if (isEdit) {
          if (mounted) {
            Navigator.pop(
              context,
              true,
            );
          }
          return;
        }

        for (final row in _controllers) {
          for (final c in row) {
            c.dispose();
          }
        }

        for (final row in _focusNodes) {
          for (final f in row) {
            f.dispose();
          }
        }

        _controllers.clear();
        _focusNodes.clear();
        _items.clear();

        _addEmptyRow();

        await _loadLastSerial();
      } else {
        _showSnackBar(
          'فشل الحفظ: '
          '${result['error'] ?? 'خطأ غير معروف'}',
          AppTheme.dangerStrongFor(context),
        );
      }
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
  // قراءة الأرقام من Excel
  // ============================================================

  double _parseExcelNumber(
    dynamic cell,
  ) {
    if (cell == null ||
        cell.value == null) {
      return 0.0;
    }

    final value =
        cell.value;

    if (value is num) {
      return value.toDouble();
    }

    if (value is String) {
      final text =
          value.trim();

      if (text.isEmpty) {
        return 0.0;
      }

      if (text.startsWith('=')) {
        try {
          return _evaluateExpression(
            text.substring(1),
          );
        } catch (_) {
          return 0.0;
        }
      }

      final cleaned =
          text.replaceAll(
        RegExp(r'[^0-9.\-]'),
        '',
      );

      return double.tryParse(
            cleaned,
          ) ??
          0.0;
    }

    return double.tryParse(
          value.toString(),
        ) ??
        0.0;
  }

  // ============================================================
  // تقييم التعبيرات
  // ============================================================

  double _evaluateExpression(
    String expr,
  ) {
    expr =
        expr.replaceAll(' ', '');

    while (expr.contains('(')) {
      final start =
          expr.lastIndexOf('(');

      final end =
          expr.indexOf(
        ')',
        start,
      );

      if (end == -1) break;

      final sub =
          expr.substring(
        start + 1,
        end,
      );

      final value =
          _evaluateSimple(sub);

      expr =
          expr.substring(
            0,
            start,
          ) +
          value.toString() +
          expr.substring(
            end + 1,
          );
    }

    return _evaluateSimple(expr);
  }

  double _evaluateSimple(
    String expr,
  ) {
    final terms = <String>[];

    String current = '';

    for (int i = 0;
        i < expr.length;
        i++) {
      final char =
          expr[i];

      if ((char == '+' ||
              char == '-') &&
          i > 0) {
        terms.add(current);
        current = char;
      } else {
        current += char;
      }
    }

    if (current.isNotEmpty) {
      terms.add(current);
    }

    return terms.fold<double>(
      0.0,
      (sum, term) {
        if (term.startsWith('+') ||
            term.startsWith('-')) {
          final value =
              _evaluateProduct(
            term.substring(1),
          );

          return sum +
              (term[0] == '+'
                  ? value
                  : -value);
        }

        return sum +
            _evaluateProduct(
          term,
        );
      },
    );
  }

  double _evaluateProduct(
    String expr,
  ) {
    final factors = <String>[];

    String current = '';

    for (int i = 0;
        i < expr.length;
        i++) {
      final char =
          expr[i];

      if (char == '*' ||
          char == '/') {
        factors.add(current);
        factors.add(char);
        current = '';
      } else {
        current += char;
      }
    }

    if (current.isNotEmpty) {
      factors.add(current);
    }

    if (factors.isEmpty) {
      return 0.0;
    }

    double result =
        double.tryParse(
              factors[0],
            ) ??
            0.0;

    for (int i = 1;
        i < factors.length;
        i += 2) {
      if (i + 1 >= factors.length) {
        break;
      }

      final op =
          factors[i];

      final next =
          double.tryParse(
                factors[i + 1],
              ) ??
              0.0;

      if (op == '*') {
        result *= next;
      } else if (op == '/') {
        result =
            next == 0
                ? 0.0
                : result / next;
      }
    }

    return result;
  }

  // ============================================================
  // استيراد Excel
  // ============================================================

  Future<void> _importFromExcel() async {
    if (!PermissionsService()
        .canImportInventory) {
      _showSnackBar(
        'ليس لديك صلاحية للاستيراد',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final proceed =
        await showDialog<bool>(
      context:
          context,
      builder:
          (ctx) =>
              AlertDialog(
        backgroundColor:
            AppTheme.dialogBackground(context),
        title:
            Text(
          'تأكيد الاستيراد',
          style:
              TextStyle(
            color:
                AppTheme.textMainFor(context),
            fontFamily:
                'Cairo',
          ),
        ),
        content:
            Text(
          'تأكد من احتواء ملف Excel على الأعمدة التالية بأي ترتيب:\n\n'
          '• الكود\n'
          '• الصنف\n'
          '• الكمية\n'
          '• سعر الجملة\n'
          '• سعر البيع\n\n'
          'يسمح بالكسور مثل 11.33.',
          style:
              TextStyle(
            color:
                AppTheme.textSoftFor(context),
            fontFamily:
                'Cairo',
          ),
          textAlign:
              TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed:
                () =>
                    Navigator.pop(
              ctx,
              false,
            ),
            child:
                Text(
              'إلغاء',
              style:
                  TextStyle(
                color:
                    AppTheme.dangerFor(context),
              ),
            ),
          ),
          ElevatedButton(
            onPressed:
                () =>
                    Navigator.pop(
              ctx,
              true,
            ),
            style:
                ElevatedButton.styleFrom(
              backgroundColor:
                  AppTheme.successFor(context),
              foregroundColor:
                  AppTheme.onAccentFor(context),
            ),
            child:
                const Text(
              'موافق',
            ),
          ),
        ],
      ),
    );

    if (proceed != true) {
      return;
    }

    final result =
        await FilePicker.platform.pickFiles(
      type:
          FileType.custom,
      allowedExtensions:
          ['xlsx'],
      withData:
          true,
    );

    if (result == null) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      var bytes =
          result.files.single.bytes;

      if (bytes == null &&
          result.files.single.path !=
              null) {
        bytes =
            await File(
          result.files.single.path!,
        ).readAsBytes();
      }

      if (bytes == null) {
        throw 'تعذر قراءة الملف';
      }

      final excel =
          excel_lib.Excel.decodeBytes(
        bytes,
      );

      for (final table
          in excel.tables.keys) {
        final rows =
            excel.tables[table]!.rows;

        if (rows.isEmpty) {
          continue;
        }

        int codeIdx = -1;
        int nameIdx = -1;
        int qtyIdx = -1;
        int wholesaleIdx = -1;
        int retailIdx = -1;

        final header =
            rows[0];

        for (int col = 0;
            col < header.length;
            col++) {
          final value =
              header[col]
                      ?.value
                      ?.toString()
                      .trim() ??
                  '';

          if (value == 'الكود') {
            codeIdx = col;
          } else if (value == 'الصنف') {
            nameIdx = col;
          } else if (value == 'الكمية') {
            qtyIdx = col;
          } else if (value == 'سعر الجملة') {
            wholesaleIdx = col;
          } else if (value == 'سعر البيع') {
            retailIdx = col;
          }
        }

        if (codeIdx == -1 ||
            nameIdx == -1 ||
            qtyIdx == -1 ||
            wholesaleIdx == -1 ||
            retailIdx == -1) {
          throw 'الملف لا يحتوي على الأعمدة المطلوبة';
        }

        final newItems =
            <InventoryItem>[];

        for (int i = 1;
            i < rows.length;
            i++) {
          final row =
              rows[i];

          if (codeIdx >= row.length ||
              row[codeIdx] == null ||
              row[codeIdx]!.value ==
                  null) {
            continue;
          }

          final code =
              row[codeIdx]!
                  .value
                  .toString()
                  .trim();

          if (code.isEmpty) {
            continue;
          }

          final name =
              nameIdx < row.length &&
                      row[nameIdx] !=
                          null &&
                      row[nameIdx]!.value !=
                          null
                  ? row[nameIdx]!
                      .value
                      .toString()
                      .trim()
                  : '';

          final qty =
              qtyIdx < row.length
                  ? _parseExcelNumber(
                      row[qtyIdx],
                    )
                  : 0.0;

          final wholesale =
              wholesaleIdx < row.length
                  ? _parseExcelNumber(
                      row[wholesaleIdx],
                    )
                  : 0.0;

          final retail =
              retailIdx < row.length
                  ? _parseExcelNumber(
                      row[retailIdx],
                    )
                  : 0.0;

          if (qty <= 0) {
            continue;
          }

          newItems.add(
            InventoryItem(
              code:
                  code,
              name:
                  name,
              quantity:
                  qty,
              wholesalePrice:
                  wholesale,
              retailPrice:
                  retail,
            ),
          );
        }

        if (newItems.isNotEmpty) {
          setState(() {
            if (_items.isNotEmpty &&
                _items.last.code.isEmpty) {
              _items.removeLast();
            }

            _items.addAll(
              newItems,
            );

            _items.add(
              InventoryItem(
                code: '',
                name: '',
                quantity: 0,
                wholesalePrice: 0,
                retailPrice: 0,
              ),
            );

            _rebuildControllersAndFocus();
          });

          _showSnackBar(
            'تم استيراد ${newItems.length} صنفاً',
            AppTheme.successStrongFor(context),
          );
        } else {
          _showSnackBar(
            'لم يتم استيراد أي بيانات صالحة',
            AppTheme.warningOrangeFor(context),
          );
        }

        break;
      }
    } catch (e) {
      _showSnackBar(
        'فشل الاستيراد: $e',
        AppTheme.dangerStrongFor(context),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    if (!PermissionsService()
        .canShowInventory) {
      return Scaffold(
        appBar:
            AppBar(
          title:
              Text(
            'الجرد',
            style:
                TextStyle(
              color:
                  AppTheme.textMainFor(context),
              fontFamily:
                  'Cairo',
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
              'ليس لديك صلاحية لعرض الجرد',
              style:
                  TextStyle(
                color:
                    AppTheme.textSoftFor(context),
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
        ),
      );
    }

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
              Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              Text(
                widget.editItem != null
                    ? 'تعديل جرد'
                    : 'جرد المخزون',
                style:
                    TextStyle(
                  fontFamily:
                      'Cairo',
                  color:
                      AppTheme.textMainFor(context),
                  fontSize:
                      16,
                ),
              ),
              if (_currentSerial !=
                  null)
                Text(
                  'إذن رقم: $_currentSerial',
                  style:
                      TextStyle(
                    fontFamily:
                        'Cairo',
                    fontSize:
                        14,
                    color:
                        AppTheme.accentFor(context),
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              Text(
                'الفرع: ${widget.branchName ?? _getBranchName(_selectedBranchCode)}',
                style:
                    TextStyle(
                  fontFamily:
                      'Cairo',
                  fontSize:
                      11,
                  color:
                      AppTheme.textSoftFor(context),
                ),
              ),
            ],
          ),
          backgroundColor:
              AppTheme.appBarBg,
          elevation:
              0,
          centerTitle:
              true,
          toolbarHeight:
              75,
          actions: [
            if (PermissionsService()
                .canViewInventory)
              IconButton(
                icon:
                    Icon(
                  Icons.history,
                  color:
                      AppTheme.accentFor(context),
                ),
                onPressed:
                    () =>
                        Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (_) =>
                            InventoryHistoryPage(
                      companyCode:
                          widget.companyCode,
                      selectedBranchCode:
                          _selectedBranchCode,
                      branchName:
                          widget.branchName,
                    ),
                  ),
                ).then(
                  (_) =>
                      _loadLastSerial(),
                ),
              ),
            if (PermissionsService()
                .canImportInventory)
              IconButton(
                icon:
                    Icon(
                  Icons.upload_file,
                  color:
                      AppTheme.successFor(context),
                ),
                onPressed:
                    _importFromExcel,
              ),
          ],
        ),
        body:
            Container(
          width:
              double.infinity,
          height:
              double.infinity,
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
                    : Center(
                        child:
                            Container(
                          constraints:
                              BoxConstraints(
                            maxWidth:
                                MediaQuery.of(
                                          context,
                                        ).size.width >
                                    600
                                    ? 1200
                                    : double.infinity,
                          ),
                          child:
                              Column(
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(
                                  horizontal:
                                      12,
                                  vertical:
                                      4,
                                ),
                                child:
                                    GlassCard(
                                  child:
                                      Padding(
                                    padding:
                                        const EdgeInsets.all(
                                      4,
                                    ),
                                    child:
                                        Row(
                                      children: [
                                        Expanded(
                                          flex:
                                              2,
                                          child:
                                              _buildSmallDateField(),
                                        ),
                                        const SizedBox(
                                          width:
                                              4,
                                        ),
                                        Expanded(
                                          flex:
                                              2,
                                          child:
                                              _buildSmallDropdown(
                                            'المخزن',
                                            _selectedStoreCode,
                                            _stores,
                                            (v) =>
                                                setState(
                                              () =>
                                                  _selectedStoreCode =
                                                      v,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(
                                          width:
                                              4,
                                        ),
                                        Expanded(
                                          flex:
                                              1,
                                          child:
                                              _buildSmallTypeSelector(),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child:
                                    Padding(
                                  padding:
                                      const EdgeInsets.symmetric(
                                    horizontal:
                                        8,
                                  ),
                                  child:
                                      _buildItemsList(),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(
                                  horizontal:
                                      8,
                                  vertical:
                                      6,
                                ),
                                child:
                                    Row(
                                  children: [
                                    Expanded(
                                      child:
                                          _buildSmallTotals(),
                                    ),
                                    const SizedBox(
                                      width:
                                          8,
                                    ),
                                    _buildSmallSaveButton(),
                                  ],
                                ),
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
      ),
    );
  }

  // ============================================================
  // التاريخ
  // ============================================================

  Widget _buildSmallDateField() =>
      GestureDetector(
        onTap: () async {
          final picked =
              await showDatePicker(
            context:
                context,
            initialDate:
                DateTime.parse(
              _selectedDate,
            ),
            firstDate:
                DateTime(2020),
            lastDate:
                DateTime(2101),
          );

          if (picked != null &&
              mounted) {
            setState(() {
              _selectedDate =
                  DateFormat(
                'yyyy-MM-dd',
              ).format(
                picked,
              );
            });
          }
        },
        child:
            Container(
          padding:
              const EdgeInsets.symmetric(
            horizontal:
                6,
            vertical:
                4,
          ),
          decoration:
              BoxDecoration(
            color:
                GlassStyle.fill05For(context),
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            border:
                Border.all(
              color:
                  GlassStyle.line24For(context),
            ),
          ),
          child:
              Row(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_today,
                color:
                    AppTheme.warningFor(context),
                size:
                    14,
              ),
              const SizedBox(
                width:
                    4,
              ),
              Text(
                _selectedDate,
                style:
                    TextStyle(
                  color:
                      AppTheme.textMainFor(context),
                  fontSize:
                      12,
                ),
              ),
            ],
          ),
        ),
      );

  // ============================================================
  // Dropdown
  // ============================================================

  Widget _buildSmallDropdown(
    String label,
    String? value,
    List<Map<String, String>> items,
    Function(String?) onChanged,
  ) =>
      DropdownButtonFormField<String?>(
        initialValue:
            value,
        dropdownColor:
            AppTheme.dropdownBackground(context),
        style:
            TextStyle(
          color:
              AppTheme.textMainFor(context),
          fontSize:
              12,
        ),
        isExpanded:
            true,
        decoration:
            InputDecoration(
          labelText:
              label,
          labelStyle:
              TextStyle(
            color:
                AppTheme.textSoftFor(context),
            fontSize:
                10,
          ),
          contentPadding:
              const EdgeInsets.symmetric(
            horizontal:
                6,
            vertical:
                4,
          ),
          border:
              OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            borderSide:
                BorderSide(
              color:
                  GlassStyle.line24For(context),
            ),
          ),
          enabledBorder:
              OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            borderSide:
                BorderSide(
              color:
                  GlassStyle.line24For(context),
            ),
          ),
          isDense:
              true,
        ),
        items:
            items.map(
          (item) =>
              DropdownMenuItem<String?>(
            value:
                item['code'],
            child:
                Text(
              item['name'] ?? '',
              style:
                  TextStyle(
                fontSize:
                    12,
              ),
            ),
          ),
        ).toList(),
        onChanged:
            onChanged,
      );

  // ============================================================
  // النوع
  // ============================================================

  Widget _buildSmallTypeSelector() =>
      DropdownButtonFormField<String>(
        initialValue:
            _inventoryType,
        dropdownColor:
            AppTheme.dropdownBackground(context),
        style:
            TextStyle(
          color:
              AppTheme.textMainFor(context),
          fontSize:
              12,
        ),
        isExpanded:
            true,
        decoration:
            InputDecoration(
          labelText:
              'النوع',
          labelStyle:
              TextStyle(
            color:
                AppTheme.textSoftFor(context),
            fontSize:
                10,
          ),
          contentPadding:
              const EdgeInsets.symmetric(
            horizontal:
                6,
            vertical:
                4,
          ),
          border:
              OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            borderSide:
                BorderSide(
              color:
                  GlassStyle.line24For(context),
            ),
          ),
          enabledBorder:
              OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            borderSide:
                BorderSide(
              color:
                  GlassStyle.line24For(context),
            ),
          ),
          isDense:
              true,
        ),
        items:
            const [
          DropdownMenuItem(
            value:
                'general',
            child:
                Text(
              'جرد عام',
              style:
                  TextStyle(
                fontSize:
                    12,
              ),
            ),
          ),
          DropdownMenuItem(
            value:
                'specific',
            child:
                Text(
              'جرد محدد',
              style:
                  TextStyle(
                fontSize:
                    12,
              ),
            ),
          ),
        ],
        onChanged:
            (value) {
          if (value == null) return;

          setState(() {
            _inventoryType =
                value;
          });
        },
      );

  // ============================================================
  // الإجماليات
  // ============================================================

  Widget _buildSmallTotals() {
    final valid =
        _items.any(
      (item) =>
          item.code.isNotEmpty,
    );

    if (!valid) {
      return const SizedBox.shrink();
    }

    return Container(
      padding:
          const EdgeInsets.symmetric(
        horizontal:
            10,
        vertical:
            4,
      ),
      decoration:
          BoxDecoration(
        color:
            GlassStyle.fill05For(context),
        borderRadius:
            BorderRadius.circular(
          6,
        ),
        border:
            Border.all(
          color:
              GlassStyle.line24For(context),
        ),
      ),
      child:
          Row(
        mainAxisAlignment:
            MainAxisAlignment
                .spaceAround,
        children: [
          Row(
            children: [
              Text(
                'الكمية:',
                style:
                    TextStyle(
                  color:
                      AppTheme.textSoftFor(context),
                  fontSize:
                      12,
                ),
              ),
              const SizedBox(
                width:
                    4,
              ),
              Text(
                _formatNumber(
                  totalQuantity,
                ),
                style:
                    TextStyle(
                  color:
                      AppTheme.accentFor(context),
                  fontSize:
                      13,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                'الجملة:',
                style:
                    TextStyle(
                  color:
                      AppTheme.textSoftFor(context),
                  fontSize:
                      12,
                ),
              ),
              const SizedBox(
                width:
                    4,
              ),
              Text(
                _formatDecimal(
                  totalWholesale,
                ),
                style:
                    TextStyle(
                  color:
                      AppTheme.successFor(context),
                  fontSize:
                      13,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                'البيع:',
                style:
                    TextStyle(
                  color:
                      AppTheme.textSoftFor(context),
                  fontSize:
                      12,
                ),
              ),
              const SizedBox(
                width:
                    4,
              ),
              Text(
                _formatDecimal(
                  totalRetail,
                ),
                style:
                    TextStyle(
                  color:
                      AppTheme.warningFor(context),
                  fontSize:
                      13,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // زر الحفظ
  // ============================================================

  Widget _buildSmallSaveButton() {
    final isEdit =
        widget.editItem != null;

    final canSave = isEdit
        ? PermissionsService()
            .canEditInventory
        : PermissionsService()
            .canAddInventory;

    final valid =
        _items.any(
      (item) =>
          item.code.isNotEmpty &&
          item.quantity > 0,
    );

    return ElevatedButton(
      onPressed:
          canSave && valid
              ? _saveInventory
              : null,
      style:
          ElevatedButton.styleFrom(
        backgroundColor:
            canSave && valid
                ? AppTheme.successFor(context)
                : AppTheme.neutralFor(context),
        foregroundColor:
            AppTheme.onAccentFor(context),
        padding:
            const EdgeInsets.symmetric(
          horizontal:
              14,
          vertical:
              6,
        ),
        shape:
            RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(
            6,
          ),
        ),
      ),
      child:
          Text(
        _isSaving
            ? '...'
            : isEdit
                ? 'تحديث'
                : 'حفظ',
        style:
            TextStyle(
          fontSize:
              14,
          fontWeight:
              FontWeight.bold,
          fontFamily:
              'Cairo',
        ),
      ),
    );
  }

  // ============================================================
  // قائمة الأصناف
  // ============================================================

  Widget _buildItemsList() {
  final hasValid = _items.any((item) => item.code.isNotEmpty);
  final isMobile = MediaQuery.of(context).size.width < 600;

  return GlassCard(
    child: isMobile
        ? _buildMobileTable()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                decoration: BoxDecoration(
                  color: GlassStyle.fill10For(context),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _buildDesktopHeaders(),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: _buildDesktopItemsList(),
              ),
              if (hasValid)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: InkWell(
                    onTap: _addEmptyRow,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: GlassStyle.line24For(context)),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text(
                          '+ إضافة صنف جديد',
                          style: TextStyle(
                            color: AppTheme.accentFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
  );
}

  // ============================================================
  // جدول الموبايل
  // ============================================================

  Widget _buildMobileTable() {
  // حساب عرض الأعمدة الثابتة
  const double colWidth = 80.0;
  const double nameColWidth = 120.0;
  const double actionWidth = 40.0; // مساحة زر الحذف
  const double spacing = 4.0;
  const double padding = 16.0; // padding جانبي

  // عدد الأعمدة: الكود، الصنف، الكمية، سعر الجملة، قيمة الجملة، سعر البيع، قيمة البيع
  // 7 أعمدة + زر الحذف
  final double totalWidth = colWidth * 6 + nameColWidth + actionWidth + (7 * spacing) + padding;

  // بناء المحتوى الأفقي
  Widget horizontalContent = SizedBox(
    width: totalWidth,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: BoxDecoration(
            color: GlassStyle.fill10For(context),
            borderRadius: BorderRadius.circular(6),
          ),
          child: _buildMobileHeaders(),
        ),
        const SizedBox(height: 4),
        // Rows
        ...List.generate(
          _items.length,
          (rowIndex) {
            final item = _items[rowIndex];
            final isLast = rowIndex == _items.length - 1;
            if (item.code.isEmpty && !isLast) {
              return const SizedBox.shrink();
            }
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: GlassStyle.line05For(context),
                    width: 0.5,
                  ),
                ),
              ),
              child: _buildMobileRow(rowIndex),
            );
          },
        ),
        // Add button
        if (_items.any((item) => item.code.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: _addEmptyRow,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: GlassStyle.line24For(context)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text(
                    '+ إضافة صنف جديد',
                    style: TextStyle(
                      color: AppTheme.accentFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  // لف المحتوى الأفقي في SingleChildScrollView عمودي
  return SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const AlwaysScrollableScrollPhysics(),
      child: horizontalContent,
    ),
  );
}

  // ============================================================
  // Headers
  // ============================================================

  Widget _buildMobileHeaders() {
  const double colWidth = 80.0;
  const double nameColWidth = 120.0;

  return Row(
    mainAxisSize: MainAxisSize.max,
    children: [
      _headerCell('الكود', colWidth, AppTheme.accentAltFor(context)),
      const SizedBox(width: 4),
      _headerCell('الصنف', nameColWidth, AppTheme.accentAltFor(context)),
      const SizedBox(width: 4),
      _headerCell('الكمية', colWidth, AppTheme.accentAltFor(context)),
      const SizedBox(width: 4),
      _headerCell('سعر الجملة', colWidth, AppTheme.accentAltFor(context)),
      const SizedBox(width: 4),
      _headerCell('قيمة الجملة', colWidth, AppTheme.successFor(context)),
      const SizedBox(width: 4),
      _headerCell('سعر البيع', colWidth, AppTheme.accentAltFor(context)),
      const SizedBox(width: 4),
      _headerCell('قيمة البيع', colWidth, AppTheme.warningFor(context)),
      const SizedBox(width: 4),
      const SizedBox(width: 40), // مساحة زر الحذف
    ],
  );
}

  Widget _headerCell(String text, double width, Color color) {
  return SizedBox(
    width: width,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.bold,
        fontSize: 11,
        fontFamily: 'Cairo',
      ),
    ),
  );
}

  // ============================================================
  // صف الموبايل
  // ============================================================

  Widget _buildMobileRow(int rowIndex) {
  const double colWidth = 80.0;
  const double nameColWidth = 120.0;
  final item = _items[rowIndex];

  return Row(
    mainAxisSize: MainAxisSize.max,
    children: [
      SizedBox(
        width: colWidth,
        child: _buildItemField(rowIndex, 0),
      ),
      const SizedBox(width: 4),
      SizedBox(
        width: nameColWidth,
        child: _buildItemField(rowIndex, 1),
      ),
      const SizedBox(width: 4),
      SizedBox(
        width: colWidth,
        child: _buildItemField(rowIndex, 2),
      ),
      const SizedBox(width: 4),
      SizedBox(
        width: colWidth,
        child: _buildItemField(rowIndex, 3),
      ),
      const SizedBox(width: 4),
      _valueCell(item.wholesaleValue, colWidth, AppTheme.successFor(context)),
      const SizedBox(width: 4),
      SizedBox(
        width: colWidth,
        child: _buildItemField(rowIndex, 4),
      ),
      const SizedBox(width: 4),
      _valueCell(item.retailValue, colWidth, AppTheme.warningFor(context)),
      const SizedBox(width: 4),
      SizedBox(
        width: 40,
        child: IconButton(
          icon: Icon(Icons.delete, color: AppTheme.dangerStrongFor(context), size: 20),
          onPressed: () => _removeRow(rowIndex),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ),
    ],
  );
}

  // ============================================================
  // خلية القيمة
  // ============================================================

  Widget _valueCell(double value, double width, Color color) {
  return SizedBox(
    width: width,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      alignment: Alignment.center,
      child: Text(
        _formatDecimal(value),
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
  );
}

  // ============================================================
  // Headers Desktop
  // ============================================================

  Widget _buildDesktopHeaders() =>
      Row(
        children: [
          Expanded(
            flex:
                1,
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
                fontSize:
                    11,
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
          Expanded(
            flex:
                2,
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
                fontSize:
                    11,
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
          Expanded(
            flex:
                1,
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
                fontSize:
                    11,
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
          Expanded(
            flex:
                1,
            child:
                Text(
              'سعر الجملة',
              textAlign:
                  TextAlign.center,
              style:
                  TextStyle(
                color:
                    AppTheme.accentAltFor(context),
                fontWeight:
                    FontWeight.bold,
                fontSize:
                    11,
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
          Expanded(
            flex:
                1,
            child:
                Text(
              'قيمة الجملة',
              textAlign:
                  TextAlign.center,
              style:
                  TextStyle(
                color:
                    AppTheme.successFor(context),
                fontWeight:
                    FontWeight.bold,
                fontSize:
                    11,
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
          Expanded(
            flex:
                1,
            child:
                Text(
              'سعر البيع',
              textAlign:
                  TextAlign.center,
              style:
                  TextStyle(
                color:
                    AppTheme.accentAltFor(context),
                fontWeight:
                    FontWeight.bold,
                fontSize:
                    11,
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
          Expanded(
            flex:
                1,
            child:
                Text(
              'قيمة البيع',
              textAlign:
                  TextAlign.center,
              style:
                  TextStyle(
                color:
                    AppTheme.warningFor(context),
                fontWeight:
                    FontWeight.bold,
                fontSize:
                    11,
                fontFamily:
                    'Cairo',
              ),
            ),
          ),
          SizedBox(
            width:
                30,
          ),
        ],
      );

  // ============================================================
  // Desktop Items
  // ============================================================

  Widget _buildDesktopItemsList() =>
      ListView.builder(
        controller:
            _scrollController,
        padding:
            EdgeInsets.zero,
        itemCount:
            _items.length,
        itemBuilder:
            (ctx, rowIndex) {
          final item =
              _items[rowIndex];

          final isLast =
              rowIndex ==
                  _items.length -
                      1;

          if (item.code.isEmpty &&
              !isLast) {
            return const SizedBox.shrink();
          }

          return Container(
            padding:
                const EdgeInsets.symmetric(
              vertical:
                  4,
            ),
            decoration:
                BoxDecoration(
              border:
                  Border(
                bottom:
                    BorderSide(
                  color:
                      GlassStyle.line05For(context),
                  width:
                      0.5,
                ),
              ),
            ),
            child:
                Row(
              children: [
                Expanded(
                  flex:
                      1,
                  child:
                      _buildItemField(
                    rowIndex,
                    0,
                  ),
                ),
                Expanded(
                  flex:
                      2,
                  child:
                      _buildItemField(
                    rowIndex,
                    1,
                  ),
                ),
                Expanded(
                  flex:
                      1,
                  child:
                      _buildItemField(
                    rowIndex,
                    2,
                  ),
                ),
                Expanded(
                  flex:
                      1,
                  child:
                      _buildItemField(
                    rowIndex,
                    3,
                  ),
                ),
                Expanded(
                  flex:
                      1,
                  child:
                      _valueCell(
                    item.wholesaleValue,
                    double.infinity,
                    AppTheme.successFor(context),
                  ),
                ),
                Expanded(
                  flex:
                      1,
                  child:
                      _buildItemField(
                    rowIndex,
                    4,
                  ),
                ),
                Expanded(
                  flex:
                      1,
                  child:
                      _valueCell(
                    item.retailValue,
                    double.infinity,
                    AppTheme.warningFor(context),
                  ),
                ),
                SizedBox(
                  width:
                      30,
                  child:
                      IconButton(
                    icon:
                        Icon(
                      Icons.delete,
                      color:
                          AppTheme.dangerStrongFor(context),
                      size:
                          18,
                    ),
                    onPressed:
                        () =>
                            _removeRow(
                      rowIndex,
                    ),
                    padding:
                        EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(),
                  ),
                ),
              ],
            ),
          );
        },
      );

  // ============================================================
  // الحقول
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

  final isNumber =
      field == 'quantity' ||
      field == 'wholesalePrice' ||
      field == 'retailPrice';

  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: TextFormField(
      controller: _controllers[rowIndex][fieldIndex],
      focusNode: _focusNodes[rowIndex][fieldIndex],
      style: TextStyle(
        color: AppTheme.textMainFor(context),
        fontSize: 13,
        fontFamily: 'Cairo',
      ),
      textAlign: TextAlign.center,
      keyboardType: isNumber
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      textInputAction: fieldIndex == _fieldOrder.length - 1
          ? TextInputAction.done
          : TextInputAction.next,
      onChanged: (_) => _onFieldChanged(rowIndex, fieldIndex),
      onFieldSubmitted: (_) => _onFieldSubmitted(rowIndex, fieldIndex),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: GlassStyle.line24For(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.accentFor(context)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        isDense: true,
        fillColor: GlassStyle.fill03For(context),
        filled: true,
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
        // ✅ بحث لا يعتمد على حالة الأحرف، ويعرض كل الأصناف المطابقة
        return _itemsLookup.where(
          (item) => (item['name'] ?? '').contains(query),
        );
      },
      onSelected: (option) {
        _fillRowFromSelectedItem(rowIndex, option);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
  return CompositedTransformTarget( // ✅ اربط الحقل بالرابط
    link: _nameFieldLinks[rowIndex],
    child: TextFormField(
      controller: controller,
      focusNode: focusNode,
      style: TextStyle(
        color: AppTheme.textMainFor(context),
        fontSize: 13,
        fontFamily: 'Cairo',
      ),
      textAlign: TextAlign.center,
      keyboardType: TextInputType.text,
      textInputAction: TextInputAction.next,
      onChanged: (_) => _onFieldChanged(rowIndex, fieldIndex),
      onFieldSubmitted: (_) {
        _onFieldSubmitted(rowIndex, fieldIndex);
      },
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: GlassStyle.line24For(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.accentFor(context)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        isDense: true,
        fillColor: GlassStyle.fill03For(context),
        filled: true,
      ),
    ),
  );
},
    optionsViewBuilder: (context, onSelected, options) {
  // ✅ رقم واحد فقط تتحكم به في العرض
  const double boxWidth = 150.0;

  return CompositedTransformFollower(
    link: _nameFieldLinks[rowIndex],
    showWhenUnlinked: false,
    // ✅ في RTL نربط بالحافة اليمنى للحقل
    targetAnchor: Alignment.bottomRight,
    followerAnchor: Alignment.topRight,
    offset: const Offset(0, 6),
    child: Align(
      alignment: Alignment.topRight,
      // ✅ widthFactor: 1.0 يمنع Align من تمديد الأبناء
      widthFactor: 1.0,
      heightFactor: 1.0,
      child: Material(
        elevation: 8,
        color: AppTheme.dropdownBackground(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          // ✅ عرض ثابت صريح
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
  // SnackBar
  // ============================================================

  void _showSnackBar(
    String msg,
    Color color,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content:
            Text(
          msg,
          textAlign:
              TextAlign.center,
          style:
              TextStyle(
            fontFamily:
                'Cairo',
            fontSize:
                14,
          ),
        ),
        backgroundColor:
            color,
        duration:
            const Duration(
          seconds:
              3,
        ),
      ),
    );
  }

  // ============================================================
  // Dispose
  // ============================================================

  @override
  void dispose() {
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

    _scrollController.dispose();

    super.dispose();
  }
}