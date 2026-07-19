// lib/views/dashboard/inventory_page.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/inventory_service.dart';
import '../../services/coding_service.dart';
import '../../models/inventory_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import 'inventory_history_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InventoryPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;   // ✅ المعامل الجديد
  final String? branchName; 
  final InventoryModel? editItem;

  const InventoryPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,          // ✅ إضافته
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

  static const List<String> _fieldOrder = ['code', 'name', 'quantity', 'wholesalePrice', 'retailPrice'];

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
  }
  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    final Box codingBox = Hive.box('coding_box');
    final rawData = codingBox.get("${widget.companyCode}_branches", defaultValue: []);
    for (var item in rawData) {
      if (item['code']?.toString() == code) {
        return item['name']?.toString() ?? "فرع غير معروف";
      }
    }
    return "فرع غير معروف";
  }
  
  Future<void> _loadDropdowns() async {
  setState(() => _isLoading = true);
  try {
    final prefs = await SharedPreferences.getInstance();

    // تحديد الفرع النشط
    _selectedBranchCode = widget.selectedBranchCode ?? prefs.getString('selected_branch_code');
    if (_selectedBranchCode == null || _selectedBranchCode!.isEmpty) {
      _selectedBranchCode = 'all'; // قيمة افتراضية
    }

    // تحميل المخازن فقط (لا نحتاج الفروع)
    final box = Hive.box('coding_box');
    var stores = box.get('${widget.companyCode}_stores') as List? ?? [];
    _stores = stores
        .map((e) => {'code': e['code'].toString(), 'name': e['name'].toString()})
        .toList()
      ..removeWhere((s) => s['code'] == null || s['code']!.isEmpty);

    if (_stores.isNotEmpty) _selectedStoreCode ??= _stores.first['code'];

    if (widget.editItem != null) {
      _loadEditData(); // تستخدم فرع النموذج
    } else {
      await _loadLastSerial();
      _addEmptyRow();
    }
  } catch (e) {
    print('خطأ في تحميل القوائم: $e');
  } finally {
    if (mounted) setState(() => _isLoading = false);
  }
}

  void _loadEditData() {
  final model = widget.editItem!;
  setState(() {
    _selectedBranchCode = model.branchCode;   // فرع النموذج يغلب
    _selectedStoreCode = model.storeCode;
    _selectedDate = model.date;
    _inventoryType = model.inventoryType;
    _currentSerial = model.serial;
    _items = List.from(model.items)..add(InventoryItem(code: '', name: '', quantity: 0, wholesalePrice: 0, retailPrice: 0));
    _rebuildControllersAndFocus();
  });
}

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
          case 'wholesalePrice': initialValue = item.wholesalePrice.toString(); break;
          case 'retailPrice': initialValue = item.retailPrice.toString(); break;
        }
        rowControllers.add(TextEditingController(text: initialValue));
        rowFocus.add(FocusNode());
      }
      _controllers.add(rowControllers);
      _focusNodes.add(rowFocus);
    }
  }

  Future<void> _loadLastSerial() async {
    try {
      final box = Hive.box('inventory_box');
      int maxSerial = 0;
      for (var key in box.keys) {
        final raw = box.get(key) as List?;
        if (raw == null) continue;
        for (var item in raw) {
          if (item['company_code'] == widget.companyCode) {
            int s = int.tryParse(item['serial']?.toString() ?? '0') ?? 0;
            if (s > maxSerial) maxSerial = s;
          }
        }
      }
      setState(() => _currentSerial = maxSerial + 1);
    } catch (e) {
      setState(() => _currentSerial = 1);
    }
  }

  void _addEmptyRow() {
    setState(() {
      _items.add(InventoryItem(code: '', name: '', quantity: 0, wholesalePrice: 0, retailPrice: 0));
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
  }

  void _onFieldChanged(int rowIndex, int fieldIndex) {
    final controllers = _controllers[rowIndex];
    final item = _items[rowIndex];
    final field = _fieldOrder[fieldIndex];
    String value = controllers[fieldIndex].text.trim();

    switch (field) {
      case 'code':
        if (item.code != value) {
          item.code = value;
          _recalcItem(rowIndex);
          if (value.isNotEmpty) _autoFillItem(rowIndex);
        }
        break;
      case 'name':
        item.name = value;
        break;
      case 'quantity':
        item.quantity = double.tryParse(value) ?? 0.0;
        _recalcItem(rowIndex);
        break;
      case 'wholesalePrice':
        item.wholesalePrice = double.tryParse(value) ?? 0.0;
        _recalcItem(rowIndex);
        break;
      case 'retailPrice':
        item.retailPrice = double.tryParse(value) ?? 0.0;
        _recalcItem(rowIndex);
        break;
    }
  }

  void _recalcItem(int index) {
    final item = _items[index];
    item.wholesaleValue = item.wholesalePrice * item.quantity;
    item.retailValue = item.retailPrice * item.quantity;
  }

  void _autoFillItem(int index) {
  final code = _items[index].code;
  if (code.isEmpty) return;

  // 1. البحث في Hive (المفاتيح snake_case)
  final box = Hive.box('coding_box');
  final key = '${widget.companyCode}_items';
  final raw = box.get(key) as List?;
  if (raw != null) {
    for (var item in raw) {
      if (item['code'].toString() == code) {
        final name = item['name'] ?? '';
        // ✅ استخدم المفاتيح الصحيحة من Hive (snake_case)
        final wholesale = double.tryParse(item['wholesale_price']?.toString() ?? '0') ?? 0.0;
        final retail = double.tryParse(item['selling_price']?.toString() ?? '0') ?? 0.0;
        print('✅ جلب من Hive: name=$name, wholesale=$wholesale, retail=$retail');
        setState(() {
          _items[index].name = name;
          _items[index].wholesalePrice = wholesale;
          _items[index].retailPrice = retail;
          _recalcItem(index);
          // تحديث Controllers
          _controllers[index][1].text = name;
          _controllers[index][3].text = wholesale.toString();
          _controllers[index][4].text = retail.toString();
        });
        return;
      }
    }
  }

  // 2. جلب من السيرفر (CodingService يعيد CodingModel بمفاتيح camelCase)
  _codingService.getCodingList(companyCode: widget.companyCode, category: 'items')
      .then((list) {
        for (var item in list) {
          if (item.code == code) {
            final name = item.name;
            final wholesale = item.wholesalePrice;
            final retail = item.sellingPrice;
            print('✅ جلب من السيرفر: name=$name, wholesale=$wholesale, retail=$retail');
            setState(() {
              _items[index].name = name;
              _items[index].wholesalePrice = wholesale;
              _items[index].retailPrice = retail;
              _recalcItem(index);
              _controllers[index][1].text = name;
              _controllers[index][3].text = wholesale.toString();
              _controllers[index][4].text = retail.toString();
            });
            return;
          }
        }
        print('⚠️ الكود $code غير موجود في التكويد');
      })
      .catchError((e) {
        print('❌ خطأ في جلب الصنف من السيرفر: $e');
      });
}

  void _onFieldSubmitted(int rowIndex, int fieldIndex) {
    _onFieldChanged(rowIndex, fieldIndex);
    final next = fieldIndex + 1;
    if (next < _fieldOrder.length) {
      _focusNodes[rowIndex][next].requestFocus();
    } else {
      _addEmptyRow();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (rowIndex + 1 < _focusNodes.length) {
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

  double get totalWholesale => _items.fold(0, (s, i) => s + i.wholesaleValue);
  double get totalRetail => _items.fold(0, (s, i) => s + i.retailValue);

  Future<void> _saveInventory() async {
    if (!PermissionsService().canAddInventory) {
      _showSnackBar('ليس لديك صلاحية للحفظ', Colors.orange);
      return;
    }

    for (int i = 0; i < _items.length; i++) {
      _onFieldChanged(i, 0);
      _onFieldChanged(i, 1);
      _onFieldChanged(i, 2);
      _onFieldChanged(i, 3);
      _onFieldChanged(i, 4);
    }

    final validItems = _items.where((i) => i.code.isNotEmpty && i.quantity > 0).toList();
    if (validItems.isEmpty) {
      _showSnackBar('أضف صنفاً واحداً على الأقل', Colors.orange);
      return;
    }
    if (_selectedBranchCode == null || _selectedBranchCode!.isEmpty) {
      _showSnackBar('اختر فرعاً', Colors.orange);
      return;
    }
    if (_selectedStoreCode == null || _selectedStoreCode!.isEmpty) {
      _showSnackBar('اختر مخزناً', Colors.orange);
      return;
    }

    setState(() => _isSaving = true);
    try {
      final model = InventoryModel(
        companyCode: widget.companyCode,
        branchCode: _selectedBranchCode!,
        storeCode: _selectedStoreCode!,
        date: _selectedDate,
        inventoryType: _inventoryType,
        items: validItems,
        serial: widget.editItem?.serial ?? _currentSerial,
        docId: widget.editItem?.docId,
      );

      final result = await _inventoryService.saveInventory(model);
      if (result['success'] == true) {
        _showSnackBar(widget.editItem != null ? 'تم تحديث الجرد' : 'تم حفظ الجرد', Colors.green);
        setState(() {
          _items.clear();
          for (var row in _controllers) for (var c in row) c.dispose();
          for (var row in _focusNodes) for (var f in row) f.dispose();
          _controllers.clear();
          _focusNodes.clear();
          _addEmptyRow();
          _loadLastSerial();
        });
        if (widget.editItem != null) Navigator.pop(context, true);
      } else {
        _showSnackBar('فشل الحفظ: ${result['error']}', Colors.red);
      }
    } catch (e) {
      _showSnackBar('خطأ: $e', Colors.red);
    } finally {
      setState(() => _isSaving = false);
    }
  }

  // ================== دالة مساعدة لقراءة الأرقام من Excel ==================
double _parseExcelNumber(dynamic cell) {
  if (cell == null) return 0.0;
  final value = cell.value;
  if (value == null) return 0.0;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is String) {
    String trimmed = value.trim();
    // ✅ إذا كانت القيمة تبدأ بـ '=' فهي عملية حسابية
    if (trimmed.startsWith('=')) {
      String expr = trimmed.substring(1).trim();
      try {
        return _evaluateExpression(expr);
      } catch (_) {
        return 0.0;
      }
    }
    // إزالة الأحرف غير الرقمية (عدا النقطة والعلامة السالبة)
    String cleaned = trimmed.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }
  try {
    return double.parse(value.toString());
  } catch (_) {
    return 0.0;
  }
}

// ================== مُقيِّم تعبيرات رياضية بسيطة ==================
double _evaluateExpression(String expr) {
  // إزالة المسافات
  expr = expr.replaceAll(' ', '');

  // 1. معالجة الأقواس بالتكرار
  while (expr.contains('(')) {
    int start = expr.lastIndexOf('(');
    int end = expr.indexOf(')', start);
    if (end == -1) break;
    String sub = expr.substring(start + 1, end);
    double subVal = _evaluateSimple(sub);
    expr = expr.substring(0, start) + subVal.toString() + expr.substring(end + 1);
  }
  return _evaluateSimple(expr);
}

// دالة تقييم بدون أقواس (لـ + و - و * و /)
double _evaluateSimple(String expr) {
  // أولاً: تقسيم حسب + و - مع الحفاظ على الإشارات
  List<String> terms = [];
  String current = '';
  for (int i = 0; i < expr.length; i++) {
    String char = expr[i];
    if ((char == '+' || char == '-') && i > 0) {
      terms.add(current);
      current = char;
    } else {
      current += char;
    }
  }
  if (current.isNotEmpty) terms.add(current);

  // تقييم كل حد (عملية * و /)
  List<double> values = [];
  for (String term in terms) {
    if (term.startsWith('+') || term.startsWith('-')) {
      String op = term[0];
      String rest = term.substring(1);
      double val = _evaluateProduct(rest);
      values.add(op == '+' ? val : -val);
    } else {
      values.add(_evaluateProduct(term));
    }
  }
  // جمع النتائج
  return values.fold(0.0, (sum, v) => sum + v);
}

// دالة تقييم الضرب والقسمة
double _evaluateProduct(String expr) {
  List<String> factors = [];
  String current = '';
  for (int i = 0; i < expr.length; i++) {
    String char = expr[i];
    if (char == '*' || char == '/') {
      factors.add(current);
      factors.add(char);
      current = '';
    } else {
      current += char;
    }
  }
  if (current.isNotEmpty) factors.add(current);

  if (factors.isEmpty) return 0.0;
  double result = double.tryParse(factors[0]) ?? 0.0;
  for (int i = 1; i < factors.length; i += 2) {
    if (i + 1 >= factors.length) break;
    String op = factors[i];
    double next = double.tryParse(factors[i + 1]) ?? 0.0;
    if (op == '*') result *= next;
    else if (op == '/') result = next != 0 ? result / next : 0.0;
  }
  return result;
}

Future<void> _importFromExcel() async {
  if (!PermissionsService().canImportInventory) {
    _showSnackBar('ليس لديك صلاحية للاستيراد', Colors.orange);
    return;
  }

  bool? proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.indigo.shade900,
      title: const Text('تأكيد الاستيراد', style: TextStyle(color: Colors.white)),
      content: const Text(
        'تأكد من احتواء ملف Excel على الأعمدة التالية (بأي ترتيب):\n\n'
        '• الكود\n• الصنف\n• الكمية\n• سعر الجملة\n• سعر البيع\n\n'
        'سيتم تجاهل الأعمدة الإضافية والخلايا الفارغة.',
        style: TextStyle(color: Colors.white70),
        textAlign: TextAlign.right,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء', style: TextStyle(color: Colors.redAccent))),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black),
          child: const Text('موافق'),
        ),
      ],
    ),
  );
  if (proceed != true) return;

  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
    withData: true,
  );
  if (result == null) return;

  setState(() => _isLoading = true);
  try {
    var bytes = result.files.single.bytes;
    if (bytes == null && result.files.single.path != null) {
      bytes = File(result.files.single.path!).readAsBytesSync();
    }
    if (bytes == null) throw 'تعذر قراءة الملف';
    var excel = excel_lib.Excel.decodeBytes(bytes);

    int codeIdx = -1, nameIdx = -1, qtyIdx = -1, wholesaleIdx = -1, retailIdx = -1;
    for (var table in excel.tables.keys) {
      var rows = excel.tables[table]!.rows;
      if (rows.isEmpty) continue;
      var header = rows[0];
      for (int col = 0; col < header.length; col++) {
        String val = header[col]?.value?.toString().trim() ?? '';
        if (val == 'الكود') codeIdx = col;
        else if (val == 'الصنف') nameIdx = col;
        else if (val == 'الكمية') qtyIdx = col;
        else if (val == 'سعر الجملة') wholesaleIdx = col;
        else if (val == 'سعر البيع') retailIdx = col;
      }
      if (codeIdx == -1 || nameIdx == -1 || qtyIdx == -1 || wholesaleIdx == -1 || retailIdx == -1) {
        throw 'الملف لا يحتوي على الأعمدة المطلوبة';
      }

      List<InventoryItem> newItems = [];
      for (int i = 1; i < rows.length; i++) {
        var row = rows[i];
        if (row.length <= codeIdx || row[codeIdx]?.value == null) continue;
        String code = row[codeIdx]!.value.toString().trim();
        if (code.isEmpty) continue;
        String name = (nameIdx < row.length && row[nameIdx]?.value != null)
            ? row[nameIdx]!.value.toString().trim()
            : '';

        // ✅ استخدام الدالة المساعدة لقراءة الأرقام بأمان
        double qty = _parseExcelNumber(row[qtyIdx]);
        double wholesale = _parseExcelNumber(row[wholesaleIdx]);
        double retail = _parseExcelNumber(row[retailIdx]);

        if (qty <= 0) continue;
        newItems.add(InventoryItem(
          code: code,
          name: name,
          quantity: qty,
          wholesalePrice: wholesale,
          retailPrice: retail,
        ));
      }

      if (newItems.isNotEmpty) {
        setState(() {
          _items.addAll(newItems);
          _items.add(InventoryItem(code: '', name: '', quantity: 0, wholesalePrice: 0, retailPrice: 0));
          _rebuildControllersAndFocus();
        });
        _showSnackBar('تم استيراد ${newItems.length} صنفاً', Colors.green);
      } else {
        _showSnackBar('لم يتم استيراد أي بيانات صالحة', Colors.orange);
      }
      break;
    }
  } catch (e) {
    _showSnackBar('فشل الاستيراد: $e', Colors.red);
  } finally {
    setState(() => _isLoading = false);
  }
}

  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canShowInventory) {
      return Scaffold(
        appBar: AppBar(title: const Text('الجرد', style: TextStyle(color: Colors.white)), backgroundColor: Colors.transparent),
        body: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.black, Color(0xFF1A237E), Colors.black])),
          child: const Center(child: Text('ليس لديك صلاحية لعرض الجرد', style: TextStyle(color: Colors.white70))),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) { if (!didPop && mounted) Navigator.pop(context); },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
  title: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        widget.editItem != null ? 'تعديل جرد' : 'جرد المخزون',
        style: const TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 16),
      ),
      if (_currentSerial != null)
        Text(
          'إذن رقم: $_currentSerial',
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 14,
            color: Colors.cyanAccent,
            fontWeight: FontWeight.bold,
          ),
        ),
      // ✅ إضافة سطر اسم الفرع أسفل رقم الإذن
      Text(
        "الفرع: ${widget.branchName ?? _getBranchName(_selectedBranchCode)}",
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 11,
          color: Colors.white70,
        ),
      ),
    ],
  ),
  backgroundColor: Colors.transparent,
  elevation: 0,
  centerTitle: true,
  toolbarHeight: 75,
  actions: [
    if (PermissionsService().canViewInventory)
      IconButton(
        icon: const Icon(Icons.history, color: Colors.cyanAccent, size: 24),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
      builder: (c) => InventoryHistoryPage(
        companyCode: widget.companyCode,
        selectedBranchCode: _selectedBranchCode,
        branchName: widget.branchName,   // ✅ تمرير اسم الفرع
      ),
    ),
  ).then((_) => _loadLastSerial()),
  tooltip: 'معاينة الجردات',
),
    if (PermissionsService().canImportInventory)
      IconButton(
        icon: const Icon(Icons.upload_file, color: Colors.greenAccent, size: 24),
        onPressed: _importFromExcel,
        tooltip: 'استيراد من Excel',
      ),
  ],
),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.black, Color(0xFF1A237E), Colors.black])),
          child: SafeArea(
            child: (_isLoading || _isSaving)
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : Center(
                    child: Container(
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width > 600 ? 1200 : double.infinity),
                      child: Column(
                        children: [
                          Padding(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  child: GlassCard(
    child: Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        children: [
          Expanded(flex: 2, child: _buildSmallDateField()),
          const SizedBox(width: 4),
          // ✅ تم إزالة حقل اختيار الفرع
          Expanded(flex: 2, child: _buildSmallDropdown('المخزن', _selectedStoreCode, _stores, (v) => setState(() => _selectedStoreCode = v))),
          const SizedBox(width: 4),
          Expanded(flex: 1, child: _buildSmallTypeSelector()),
        ],
      ),
    ),
  ),
),
                          Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _buildItemsList())),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            child: Row(
                              children: [
                                Expanded(child: _buildSmallTotals()),
                                const SizedBox(width: 8),
                                _buildSmallSaveButton(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildSmallDateField() => GestureDetector(
  onTap: () async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_selectedDate),
      firstDate: DateTime(2020),
      lastDate: DateTime(2101),
    );
    if (picked != null) setState(() => _selectedDate = DateFormat('yyyy-MM-dd').format(picked));
  },
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.white24)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.calendar_today, color: Colors.amber, size: 14),
      const SizedBox(width: 4),
      Text(_selectedDate, style: const TextStyle(color: Colors.white, fontSize: 12)),
    ]),
  ),
);

  Widget _buildSmallDropdown(String label, String? value, List<Map<String, String>> items, Function(String?) onChanged) =>
    DropdownButtonFormField<String?>(
      value: value,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.white24)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.white24)),
        isDense: true,
      ),
      items: items.map((item) => DropdownMenuItem(value: item['code'], child: Text(item['name'] ?? '', style: const TextStyle(fontSize: 12)))).toList(),
      onChanged: onChanged,
    );

  Widget _buildSmallTypeSelector() =>
    DropdownButtonFormField<String>(
      value: _inventoryType,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      isExpanded: true,
      decoration: InputDecoration(
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.white24)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.white24)),
        labelText: 'النوع',
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 10),
        isDense: true,
      ),
      items: const [
        DropdownMenuItem(value: 'general', child: Text('جرد عام', style: TextStyle(fontSize: 12))),
        DropdownMenuItem(value: 'specific', child: Text('جرد محدد', style: TextStyle(fontSize: 12))),
      ],
      onChanged: (val) => setState(() => _inventoryType = val!),
    );

  Widget _buildSmallTotals() {
  final valid = _items.where((i) => i.code.isNotEmpty).toList();
  if (valid.isEmpty) return const SizedBox.shrink();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.white24)),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        Row(children: [
          const Text('الجملة:', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(width: 4),
          Text(totalWholesale.toStringAsFixed(2), style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.bold)),
        ]),
        const VerticalDivider(color: Colors.white24),
        Row(children: [
          const Text('البيع:', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(width: 4),
          Text(totalRetail.toStringAsFixed(2), style: const TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold)),
        ]),
      ],
    ),
  );
}

  Widget _buildSmallSaveButton() {
  final canSave = PermissionsService().canAddInventory;
  final valid = _items.where((i) => i.code.isNotEmpty && i.quantity > 0).toList();
  return ElevatedButton(
    onPressed: (canSave && valid.isNotEmpty) ? _saveInventory : null,
    style: ElevatedButton.styleFrom(
      backgroundColor: canSave && valid.isNotEmpty ? Colors.greenAccent : Colors.grey,
      foregroundColor: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    child: Text(_isSaving ? '...' : (widget.editItem != null ? 'تحديث' : 'حفظ'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
  );
}

  Widget _buildItemsList() {
  final hasValid = _items.any((i) => i.code.isNotEmpty);
  final bool isMobile = MediaQuery.of(context).size.width < 600;

  return GlassCard(
    child: isMobile
        ? _buildMobileTable()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // عناوين الأعمدة (سطح المكتب)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                child: _buildDesktopHeaders(),
              ),
              const SizedBox(height: 4),
              // القائمة (سطح المكتب)
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
                        border: Border.all(color: Colors.white24, style: BorderStyle.solid),
                        borderRadius: BorderRadius.circular(6),
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
          ),
  );
}

// ===== جدول الموبايل بمسطرة واحدة (الهيدر + الصفوف معاً) =====
Widget _buildMobileTable() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // المسطرة الأفقية للجدول بأكمله
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // الهيدر (مع عرض ثابت للأعمدة)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                  child: _buildMobileHeaders(),
                ),
                const SizedBox(height: 4),
                // الصفوف (بدون ListView.builder لمنع اختفاء الحقول)
                ...List.generate(_items.length, (rowIndex) {
                  final item = _items[rowIndex];
                  final isLast = rowIndex == _items.length - 1;
                  if (item.code.isEmpty && !isLast) return const SizedBox.shrink();
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05), width: 0.5)),
                    ),
                    child: _buildMobileRow(rowIndex),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
      // زر إضافة صنف جديد (خارج المسطرة)
      if (_items.any((i) => i.code.isNotEmpty))
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: InkWell(
            onTap: _addEmptyRow,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white24, style: BorderStyle.solid),
                borderRadius: BorderRadius.circular(6),
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

// ===== عناوين الأعمدة للموبايل (بدون مسطرة داخلية) =====
Widget _buildMobileHeaders() {
  const double colWidth = 80.0;
  const double nameColWidth = 120.0;
  return Row(
    children: [
      const SizedBox(width: 8),
      SizedBox(width: colWidth, child: const Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      const SizedBox(width: 4),
      SizedBox(width: nameColWidth, child: const Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: const Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: const Text('سعر الجملة', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: const Text('قيمة الجملة', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: const Text('سعر البيع', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: const Text('قيمة البيع', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      const SizedBox(width: 4),
      const SizedBox(width: 30),
      const SizedBox(width: 8),
    ],
  );
}

// ===== صف واحد للبيانات في الموبايل =====
Widget _buildMobileRow(int rowIndex) {
  const double colWidth = 80.0;
  const double nameColWidth = 120.0;
  final item = _items[rowIndex];

  return Row(
    children: [
      const SizedBox(width: 8),
      SizedBox(width: colWidth, child: _buildItemField(rowIndex, 0)),
      const SizedBox(width: 4),
      SizedBox(width: nameColWidth, child: _buildItemField(rowIndex, 1)),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: _buildItemField(rowIndex, 2)),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: _buildItemField(rowIndex, 3)),
      const SizedBox(width: 4),
      SizedBox(
        width: colWidth,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: Colors.greenAccent.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
          ),
          alignment: Alignment.center,
          child: Text(
            item.wholesaleValue.toStringAsFixed(2),
            style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      ),
      const SizedBox(width: 4),
      SizedBox(width: colWidth, child: _buildItemField(rowIndex, 4)),
      const SizedBox(width: 4),
      SizedBox(
        width: colWidth,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: Colors.amber.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.amber.withOpacity(0.3)),
          ),
          alignment: Alignment.center,
          child: Text(
            item.retailValue.toStringAsFixed(2),
            style: const TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      ),
      const SizedBox(width: 4),
      IconButton(
        icon: const Icon(Icons.delete, color: Colors.red, size: 20),
        onPressed: () => _removeRow(rowIndex),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
      const SizedBox(width: 8),
    ],
  );
}

// ===== عناوين الأعمدة لسطح المكتب (ثابتة) =====
Widget _buildDesktopHeaders() {
  return const Row(
    children: [
      Expanded(flex: 1, child: Text('الكود', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      Expanded(flex: 2, child: Text('الصنف', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      Expanded(flex: 1, child: Text('الكمية', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      Expanded(flex: 1, child: Text('سعر الجملة', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      Expanded(flex: 1, child: Text('قيمة الجملة', textAlign: TextAlign.center, style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      Expanded(flex: 1, child: Text('سعر البيع', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      Expanded(flex: 1, child: Text('قيمة البيع', textAlign: TextAlign.center, style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'Cairo'))),
      SizedBox(width: 30),
    ],
  );
}

// ===== قائمة الأصناف لسطح المكتب (ثابتة بدون تمرير أفقي) =====
Widget _buildDesktopItemsList() {
  return ListView.builder(
    controller: _scrollController,
    padding: EdgeInsets.zero,
    itemCount: _items.length,
    itemBuilder: (ctx, rowIndex) {
      final item = _items[rowIndex];
      final isLast = rowIndex == _items.length - 1;
      if (item.code.isEmpty && !isLast) return const SizedBox.shrink();

      return Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05), width: 0.5))),
        child: Row(
          children: [
            Expanded(flex: 1, child: _buildItemField(rowIndex, 0)),
            Expanded(flex: 2, child: _buildItemField(rowIndex, 1)),
            Expanded(flex: 1, child: _buildItemField(rowIndex, 2)),
            Expanded(flex: 1, child: _buildItemField(rowIndex, 3)),
            Expanded(
              flex: 1,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                ),
                alignment: Alignment.center,
                child: Text(
                  item.wholesaleValue.toStringAsFixed(2),
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            Expanded(flex: 1, child: _buildItemField(rowIndex, 4)),
            Expanded(
              flex: 1,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.amber.withOpacity(0.3)),
                ),
                alignment: Alignment.center,
                child: Text(
                  item.retailValue.toStringAsFixed(2),
                  style: const TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            SizedBox(
              width: 30,
              child: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                onPressed: () => _removeRow(rowIndex),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ),
          ],
        ),
      );
    },
  );
}

  Widget _buildItemField(int rowIndex, int fieldIndex) {
  final field = _fieldOrder[fieldIndex];
  final keyboard = (field == 'quantity' || field == 'wholesalePrice' || field == 'retailPrice')
      ? const TextInputType.numberWithOptions(decimal: true)
      : TextInputType.text;

  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: TextFormField(
      controller: _controllers[rowIndex][fieldIndex],
      focusNode: _focusNodes[rowIndex][fieldIndex],
      style: const TextStyle(color: Colors.white, fontSize: 13),
      textAlign: TextAlign.center, // ✅ توسيط النص
      keyboardType: keyboard,
      textInputAction: (fieldIndex == _fieldOrder.length - 1) ? TextInputAction.done : TextInputAction.next,
      onChanged: (_) => _onFieldChanged(rowIndex, fieldIndex),
      onFieldSubmitted: (_) => _onFieldSubmitted(rowIndex, fieldIndex),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
        focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6), // ✅ تصغير المسافة
        isDense: true, // ✅ تقليل الارتفاع
        fillColor: Colors.white.withOpacity(0.03),
        filled: true,
      ),
    ),
  );
}

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14)),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
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