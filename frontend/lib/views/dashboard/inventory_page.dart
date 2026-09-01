// lib/views/dashboard/inventory_page.dart

import 'dart:io';
import 'package:flutter/material.dart';
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
  List<List<TextEditingController>> _controllers = [];
  List<List<FocusNode>> _focusNodes = [];
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
        Colors.orange,
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
        Colors.orange,
      );
      return;
    }

    if (_selectedBranchCode == null ||
        _selectedBranchCode!.isEmpty ||
        _selectedBranchCode == 'all') {
      _showSnackBar(
        'يجب تحديد الفرع',
        Colors.orange,
      );
      return;
    }

    if (_selectedStoreCode == null ||
        _selectedStoreCode!.isEmpty) {
      _showSnackBar(
        'اختر المخزن',
        Colors.orange,
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
          Colors.green,
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
          Colors.red,
        );
      }
    } catch (e) {
      _showSnackBar(
        'خطأ: $e',
        Colors.red,
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
        Colors.orange,
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
            Colors.indigo.shade900,
        title:
            const Text(
          'تأكيد الاستيراد',
          style:
              TextStyle(
            color:
                Colors.white,
            fontFamily:
                'Cairo',
          ),
        ),
        content:
            const Text(
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
                Colors.white70,
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
                const Text(
              'إلغاء',
              style:
                  TextStyle(
                color:
                    Colors.redAccent,
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
                  Colors.greenAccent,
              foregroundColor:
                  Colors.black,
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
            Colors.green,
          );
        } else {
          _showSnackBar(
            'لم يتم استيراد أي بيانات صالحة',
            Colors.orange,
          );
        }

        break;
      }
    } catch (e) {
      _showSnackBar(
        'فشل الاستيراد: $e',
        Colors.red,
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
              const Text(
            'الجرد',
            style:
                TextStyle(
              color:
                  Colors.white,
              fontFamily:
                  'Cairo',
            ),
          ),
          backgroundColor:
              Colors.transparent,
        ),
        body:
            Container(
          decoration:
              const BoxDecoration(
            gradient:
                LinearGradient(
              colors: [
                Colors.black,
                Color(
                  0xFF1A237E,
                ),
                Colors.black,
              ],
            ),
          ),
          child:
              const Center(
            child:
                Text(
              'ليس لديك صلاحية لعرض الجرد',
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
                    const TextStyle(
                  fontFamily:
                      'Cairo',
                  color:
                      Colors.white,
                  fontSize:
                      16,
                ),
              ),
              if (_currentSerial !=
                  null)
                Text(
                  'إذن رقم: $_currentSerial',
                  style:
                      const TextStyle(
                    fontFamily:
                        'Cairo',
                    fontSize:
                        14,
                    color:
                        Colors.cyanAccent,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              Text(
                'الفرع: ${widget.branchName ?? _getBranchName(_selectedBranchCode)}',
                style:
                    const TextStyle(
                  fontFamily:
                      'Cairo',
                  fontSize:
                      11,
                  color:
                      Colors.white70,
                ),
              ),
            ],
          ),
          backgroundColor:
              Colors.transparent,
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
                    const Icon(
                  Icons.history,
                  color:
                      Colors.cyanAccent,
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
                    const Icon(
                  Icons.upload_file,
                  color:
                      Colors.greenAccent,
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
              const BoxDecoration(
            gradient:
                LinearGradient(
              colors: [
                Colors.black,
                Color(
                  0xFF1A237E,
                ),
                Colors.black,
              ],
            ),
          ),
          child:
              SafeArea(
            child:
                (_isLoading ||
                        _isSaving)
                    ? const Center(
                        child:
                            CircularProgressIndicator(
                          color:
                              Colors.white,
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
                Colors.white.withOpacity(
              0.05,
            ),
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            border:
                Border.all(
              color:
                  Colors.white24,
            ),
          ),
          child:
              Row(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              const Icon(
                Icons.calendar_today,
                color:
                    Colors.amber,
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
                    const TextStyle(
                  color:
                      Colors.white,
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
        value:
            value,
        dropdownColor:
            Colors.indigo.shade900,
        style:
            const TextStyle(
          color:
              Colors.white,
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
              const TextStyle(
            color:
                Colors.white70,
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
                const BorderSide(
              color:
                  Colors.white24,
            ),
          ),
          enabledBorder:
              OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            borderSide:
                const BorderSide(
              color:
                  Colors.white24,
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
                  const TextStyle(
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
        value:
            _inventoryType,
        dropdownColor:
            Colors.indigo.shade900,
        style:
            const TextStyle(
          color:
              Colors.white,
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
              const TextStyle(
            color:
                Colors.white70,
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
                const BorderSide(
              color:
                  Colors.white24,
            ),
          ),
          enabledBorder:
              OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(
              6,
            ),
            borderSide:
                const BorderSide(
              color:
                  Colors.white24,
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
            Colors.white.withOpacity(
          0.05,
        ),
        borderRadius:
            BorderRadius.circular(
          6,
        ),
        border:
            Border.all(
          color:
              Colors.white24,
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
              const Text(
                'الكمية:',
                style:
                    TextStyle(
                  color:
                      Colors.white70,
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
                    const TextStyle(
                  color:
                      Colors.cyanAccent,
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
              const Text(
                'الجملة:',
                style:
                    TextStyle(
                  color:
                      Colors.white70,
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
                    const TextStyle(
                  color:
                      Colors.greenAccent,
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
              const Text(
                'البيع:',
                style:
                    TextStyle(
                  color:
                      Colors.white70,
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
                    const TextStyle(
                  color:
                      Colors.amber,
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
                ? Colors.greenAccent
                : Colors.grey,
        foregroundColor:
            Colors.black,
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
            const TextStyle(
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
                  color: Colors.white10,
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
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Center(
                        child: Text(
                          '+ إضافة صنف جديد',
                          style: TextStyle(
                            color: Colors.cyanAccent,
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
            color: Colors.white10,
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
                    color: Colors.white.withOpacity(0.05),
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
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Center(
                  child: Text(
                    '+ إضافة صنف جديد',
                    style: TextStyle(
                      color: Colors.cyanAccent,
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
      _headerCell('الكود', colWidth, Colors.cyan),
      const SizedBox(width: 4),
      _headerCell('الصنف', nameColWidth, Colors.cyan),
      const SizedBox(width: 4),
      _headerCell('الكمية', colWidth, Colors.cyan),
      const SizedBox(width: 4),
      _headerCell('سعر الجملة', colWidth, Colors.cyan),
      const SizedBox(width: 4),
      _headerCell('قيمة الجملة', colWidth, Colors.greenAccent),
      const SizedBox(width: 4),
      _headerCell('سعر البيع', colWidth, Colors.cyan),
      const SizedBox(width: 4),
      _headerCell('قيمة البيع', colWidth, Colors.amber),
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
      _valueCell(item.wholesaleValue, colWidth, Colors.greenAccent),
      const SizedBox(width: 4),
      SizedBox(
        width: colWidth,
        child: _buildItemField(rowIndex, 4),
      ),
      const SizedBox(width: 4),
      _valueCell(item.retailValue, colWidth, Colors.amber),
      const SizedBox(width: 4),
      SizedBox(
        width: 40,
        child: IconButton(
          icon: const Icon(Icons.delete, color: Colors.red, size: 20),
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
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
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
      const Row(
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
                    Colors.cyan,
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
                    Colors.cyan,
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
                    Colors.cyan,
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
                    Colors.cyan,
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
                    Colors.greenAccent,
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
                    Colors.cyan,
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
                    Colors.amber,
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
                      Colors.white.withOpacity(
                    0.05,
                  ),
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
                    Colors.greenAccent,
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
                    Colors.amber,
                  ),
                ),
                SizedBox(
                  width:
                      30,
                  child:
                      IconButton(
                    icon:
                        const Icon(
                      Icons.delete,
                      color:
                          Colors.red,
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
    final field =
        _fieldOrder[fieldIndex];

    final isNumber =
        field == 'quantity' ||
        field == 'wholesalePrice' ||
        field == 'retailPrice';

    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal:
            2,
      ),
      child:
          TextFormField(
        controller:
            _controllers[rowIndex]
                [fieldIndex],
        focusNode:
            _focusNodes[rowIndex]
                [fieldIndex],
        style:
            const TextStyle(
          color:
              Colors.white,
          fontSize:
              13,
          fontFamily:
              'Cairo',
        ),
        textAlign:
            TextAlign.center,
        keyboardType:
            isNumber
                ? const TextInputType.numberWithOptions(
                    decimal:
                        true,
                  )
                : TextInputType.text,
        textInputAction:
            fieldIndex ==
                    _fieldOrder.length -
                        1
                ? TextInputAction.done
                : TextInputAction.next,
        onChanged:
            (_) =>
                _onFieldChanged(
          rowIndex,
          fieldIndex,
        ),
        onFieldSubmitted:
            (_) =>
                _onFieldSubmitted(
          rowIndex,
          fieldIndex,
        ),
        decoration:
            InputDecoration(
          border:
              const OutlineInputBorder(),
          enabledBorder:
              const OutlineInputBorder(
            borderSide:
                BorderSide(
              color:
                  Colors.white24,
            ),
          ),
          focusedBorder:
              const OutlineInputBorder(
            borderSide:
                BorderSide(
              color:
                  Colors.cyanAccent,
            ),
          ),
          contentPadding:
              const EdgeInsets.symmetric(
            horizontal:
                4,
            vertical:
                6,
          ),
          isDense:
              true,
          fillColor:
              Colors.white
                  .withOpacity(
            0.03,
          ),
          filled:
              true,
        ),
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
              const TextStyle(
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