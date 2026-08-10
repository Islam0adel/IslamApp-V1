// lib/views/dashboard/stock_balance_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../models/inventory_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';

class StockBalancePage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? branchName; // ✅ معامل جديد لاسم الفرع

  const StockBalancePage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.branchName,
  });

  @override
  State<StockBalancePage> createState() => _StockBalancePageState();
}

class _StockBalancePageState extends State<StockBalancePage> {
  // الفرع ثابت (نستخدم القيمة الممررة)
  String? _selectedBranchCode;
  String? _selectedStoreCode;
  DateTime _selectedDate = DateTime.now();

  // البيانات
  List<Map<String, dynamic>> _itemsData = [];
  bool _isLoading = false;
  bool _hasData = false;

  // قوائم المخازن فقط
  List<Map<String, String>> _stores = [];

  @override
  void initState() {
    super.initState();
    // تعيين الفرع من المعامل أو من SharedPreferences (اختياري)
    _selectedBranchCode = widget.selectedBranchCode;
    _loadDropdowns();
  }

  Future<void> _loadDropdowns() async {
    final box = Hive.box('coding_box');

    // تحميل المخازن فقط (لا نحتاج الفروع)
    _stores = [];
    var stores = box.get('${widget.companyCode}_stores') as List? ?? [];
    for (var item in stores) {
      _stores.add({'code': item['code'].toString(), 'name': item['name'].toString()});
    }
    if (_stores.isNotEmpty && _selectedStoreCode == null) {
      _selectedStoreCode = _stores.first['code'];
    }

    setState(() {});
    _calculateBalances();
  }

  // دالة للحصول على اسم الفرع (من المعامل أو من Hive احتياطياً)
  String _getBranchName() {
    if (widget.branchName != null && widget.branchName!.isNotEmpty) {
      return widget.branchName!;
    }
    // احتياطي: جلب من Hive
    if (_selectedBranchCode == null) return 'غير محدد';
    final box = Hive.box('coding_box');
    final rawData = box.get("${widget.companyCode}_branches", defaultValue: []);
    for (var item in rawData) {
      if (item['code']?.toString() == _selectedBranchCode) {
        return item['name']?.toString() ?? "فرع غير معروف";
      }
    }
    return _selectedBranchCode!;
  }

  String _getStoreName(String? code) {
    if (code == null) return 'غير محدد';
    final found = _stores.firstWhere((s) => s['code'] == code, orElse: () => {});
    return found['name'] ?? code;
  }

  // باقي الدوال كما هي (لم تتغير)
  // ================== المنطق الأساسي لحساب الرصيد ==================
  Future<void> _calculateBalances() async {
  if (_selectedBranchCode == null || _selectedStoreCode == null) {
    setState(() {
      _itemsData = [];
      _hasData = false;
    });
    return;
  }

  setState(() => _isLoading = true);

  try {
    final box = Hive.box('inventory_box');
    List<InventoryModel> allInventories = [];

    for (var key in box.keys) {
      final raw = box.get(key);
      if (raw is List) {
        for (var item in raw) {
          if (item['company_code'] == widget.companyCode &&
              item['branch_code'] == _selectedBranchCode &&
              item['store_code'] == _selectedStoreCode) {
            final invDate = DateTime.tryParse(item['date'] ?? '');
            if (invDate != null &&
                (invDate.isBefore(_selectedDate) ||
                    invDate.isAtSameMomentAs(_selectedDate))) {
              allInventories.add(InventoryModel.fromMap(
                  Map<String, dynamic>.from(item)));
            }
          }
        }
      }
    }

    allInventories.sort((a, b) => a.date.compareTo(b.date));

    final codingBox = Hive.box('coding_box');
    final itemsKey = '${widget.companyCode}_items';
    List<Map<String, dynamic>> allItems = [];
    if (codingBox.containsKey(itemsKey)) {
      final raw = codingBox.get(itemsKey);
      if (raw is List) {
        allItems = raw.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    }

    Map<String, double> balances = {};
    Map<String, Map<String, dynamic>> itemsMap = {};
    for (var item in allItems) {
      final code = item['code'].toString();
      balances[code] = 0.0;
      itemsMap[code] = item;
    }

    // ===== حساب الرصيد من الجرد (inventory_box) =====
    for (var inv in allInventories) {
      if (inv.inventoryType == 'general') {
        for (var key in balances.keys) {
          balances[key] = 0.0;
        }
        for (var item in inv.items) {
          balances[item.code] = item.quantity;
        }
      } else {
        for (var item in inv.items) {
          balances[item.code] = item.quantity;
        }
      }
    }

    // ===== إضافة كميات الموردين (من supplier_box) =====
    final supplierBox = Hive.box('supplier_box');
    for (var key in supplierBox.keys) {
      final raw = supplierBox.get(key);
      if (raw is List) {
        for (var item in raw) {
          if (item['company_code'] == widget.companyCode &&
              item['branch_code'] == _selectedBranchCode &&
              item['store_code'] == _selectedStoreCode &&
              item['is_add_to_store'] == true) {
            final items = item['items'] as List? ?? [];
            for (var product in items) {
              final code = product['code'].toString();
              final quantity = (product['quantity'] as num?)?.toDouble() ?? 0.0;
              // إضافة الكمية إلى الرصيد الحالي
              balances[code] = (balances[code] ?? 0.0) + quantity;
            }
          }
        }
      }
    }

    balances.removeWhere((key, value) => value == 0.0);

    List<Map<String, dynamic>> itemsData = [];
    balances.forEach((code, quantity) {
      final item = itemsMap[code] ?? {};
      final wholesalePrice = double.tryParse(
              item['wholesale_price']?.toString() ??
              item['wholesalePrice']?.toString() ??
              '0') ?? 0.0;
      final sellingPrice = double.tryParse(
              item['selling_price']?.toString() ??
              item['sellingPrice']?.toString() ??
              '0') ?? 0.0;

      itemsData.add({
        'code': code,
        'name': item['name'] ?? 'غير معروف',
        'quantity': quantity,
        'wholesalePrice': wholesalePrice,
        'sellingPrice': sellingPrice,
        'totalWholesale': quantity * wholesalePrice,
        'totalRetail': quantity * sellingPrice,
      });
    });

    itemsData.sort((a, b) => a['code'].compareTo(b['code']));

    setState(() {
      _itemsData = itemsData;
      _hasData = true;
      _isLoading = false;
    });
  } catch (e) {
    print('❌ خطأ في حساب الأرصدة: $e');
    setState(() {
      _isLoading = false;
      _hasData = false;
    });
  }
}

  // ================== الإجماليات ==================
  double get totalQuantity =>
      _itemsData.fold(0.0, (sum, item) => sum + (item['quantity'] as double));
  double get totalWholesaleValue =>
      _itemsData.fold(0.0, (sum, item) => sum + (item['totalWholesale'] as double));
  double get totalRetailValue =>
      _itemsData.fold(0.0, (sum, item) => sum + (item['totalRetail'] as double));

  String _formatCurrency(double amount) {
    return NumberFormat('#,##0.00', 'ar_EG').format(amount);
  }

  // ================== دوال التصدير ==================
  // (نفس الكود السابق، لم يتغير)
  Future<void> _exportExcel() async {
    if (_itemsData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للتصدير'), backgroundColor: Colors.orange),
      );
      return;
    }
    try {
      List<String> headers = ['الكود', 'الصنف', 'الكمية'];
      List<String> keys = ['code', 'name', 'quantity'];

      if (PermissionsService().canViewStockWholesalePrice) {
        headers.add('سعر الجملة');
        keys.add('wholesalePrice');
        headers.add('قيمة الجملة');
        keys.add('totalWholesale');
      }
      headers.add('سعر البيع');
      keys.add('sellingPrice');
      headers.add('قيمة البيع');
      keys.add('totalRetail');

      List<Map<String, dynamic>> exportData = _itemsData.map((item) {
        Map<String, dynamic> row = {};
        for (var key in keys) {
          row[key] = item[key] ?? 0;
        }
        return row;
      }).toList();

      await ExportService.exportToExcel(
        exportData,
        'رصيد_المخزون_${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
        headers,
        keys,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تصدير البيانات بنجاح'), backgroundColor: Colors.green),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل التصدير: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _exportPDF() async {
    if (_itemsData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للتصدير'), backgroundColor: Colors.orange),
      );
      return;
    }
    try {
      List<String> headers = ['الكود', 'الصنف', 'الكمية'];
      List<String> keys = ['code', 'name', 'quantity'];

      if (PermissionsService().canViewStockWholesalePrice) {
        headers.add('سعر الجملة');
        keys.add('wholesalePrice');
        headers.add('قيمة الجملة');
        keys.add('totalWholesale');
      }
      headers.add('سعر البيع');
      keys.add('sellingPrice');
      headers.add('قيمة البيع');
      keys.add('totalRetail');

      List<Map<String, dynamic>> exportData = _itemsData.map((item) {
        Map<String, dynamic> row = {};
        for (var key in keys) {
          row[key] = item[key] ?? 0;
        }
        return row;
      }).toList();

      final summary = {
        'totalQuantity': totalQuantity,
        'totalWholesale': totalWholesaleValue,
        'totalRetail': totalRetailValue,
      };

      await ExportService.exportToPDF(
        data: exportData,
        title: 'تقرير رصيد المخزون',
        headers: headers,
        keys: keys,
        summary: summary,
        branchName: _getBranchName(),
        storeName: _getStoreName(_selectedStoreCode),
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تصدير البيانات بنجاح'), backgroundColor: Colors.green),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل التصدير: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ================== دالة تاريخ آخر جرد ==================
  String _getLastInventoryDate() {
    if (_selectedBranchCode == null || _selectedStoreCode == null) {
      return 'لا يوجد';
    }
    try {
      final box = Hive.box('inventory_box');
      List<DateTime> dates = [];
      for (var key in box.keys) {
        final raw = box.get(key);
        if (raw is List) {
          for (var item in raw) {
            if (item['company_code'] == widget.companyCode &&
                item['branch_code'] == _selectedBranchCode &&
                item['store_code'] == _selectedStoreCode) {
              final date = DateTime.tryParse(item['date'] ?? '');
              if (date != null) dates.add(date);
            }
          }
        }
      }
      if (dates.isEmpty) return 'لا يوجد';
      dates.sort((a, b) => b.compareTo(a));
      return DateFormat('yyyy-MM-dd').format(dates.first);
    } catch (e) {
      return 'خطأ';
    }
  }

  // ================== بناء الجدول مع تمرير أفقي ورأسي ==================
  Widget _buildTable() {
    // (نفس الكود السابق، لم يتغير)
    List<String> headers = ['#', 'الكود', 'الصنف', 'الكمية'];
    List<String> keys = ['index', 'code', 'name', 'quantity'];
    List<double> columnWidths = [40, 70, 120, 70];

    if (PermissionsService().canViewStockWholesalePrice) {
      headers.add('سعر الجملة');
      keys.add('wholesalePrice');
      columnWidths.add(80);
    }
    if (PermissionsService().canViewStockWholesalePrice) {
      headers.add('قيمة الجملة');
      keys.add('totalWholesale');
      columnWidths.add(80);
    }
    headers.add('سعر البيع');
    keys.add('sellingPrice');
    columnWidths.add(80);
    headers.add('قيمة البيع');
    keys.add('totalRetail');
    columnWidths.add(80);

    List<Widget> headerWidgets = [];
    for (int i = 0; i < headers.length; i++) {
      headerWidgets.add(
        SizedBox(
          width: columnWidths[i],
          child: Text(
            headers[i],
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.cyan,
              fontWeight: FontWeight.bold,
              fontSize: 11,
              fontFamily: 'Cairo',
            ),
          ),
        ),
      );
    }

    List<Widget> rows = [];
    for (int idx = 0; idx < _itemsData.length; idx++) {
      final item = _itemsData[idx];
      List<Widget> rowCells = [];
      int cellIndex = 0;
      rowCells.add(
        SizedBox(
          width: columnWidths[cellIndex++],
          child: Text(
            '${idx + 1}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),
      );
      rowCells.add(
        SizedBox(
          width: columnWidths[cellIndex++],
          child: Text(
            item['code'],
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ),
      );
      rowCells.add(
        SizedBox(
          width: columnWidths[cellIndex++],
          child: Text(
            item['name'],
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
      rowCells.add(
        SizedBox(
          width: columnWidths[cellIndex++],
          child: Text(
            (item['quantity'] as double).toStringAsFixed(0),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      );
      if (PermissionsService().canViewStockWholesalePrice) {
        rowCells.add(
          SizedBox(
            width: columnWidths[cellIndex++],
            child: Text(
              _formatCurrency(item['wholesalePrice'] as double),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
            ),
          ),
        );
      }
      if (PermissionsService().canViewStockWholesalePrice) {
        rowCells.add(
          SizedBox(
            width: columnWidths[cellIndex++],
            child: Text(
              _formatCurrency(item['totalWholesale'] as double),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }
      rowCells.add(
        SizedBox(
          width: columnWidths[cellIndex++],
          child: Text(
            _formatCurrency(item['sellingPrice'] as double),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.amber, fontSize: 11),
          ),
        ),
      );
      rowCells.add(
        SizedBox(
          width: columnWidths[cellIndex++],
          child: Text(
            _formatCurrency(item['totalRetail'] as double),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      );

      rows.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.white.withOpacity(0.05), width: 0.5),
            ),
          ),
          child: Row(
            children: rowCells,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: headerWidgets,
              ),
            ),
            const SizedBox(height: 4),
            Column(
              children: rows,
            ),
          ],
        ),
      ),
    );
  }

  // ================== build الرئيسي ==================
  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canShowStock) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('رصيد المخزون', style: TextStyle(color: Colors.white)),
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
              'ليس لديك صلاحية لعرض رصيد المخزون',
              style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 16),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'رصيد المخزون',
              style: TextStyle(
                color: Colors.white,
                fontFamily: 'Cairo',
                fontSize: 16,
              ),
            ),
            // ✅ إضافة سطر اسم الفرع
            Text(
              'الفرع: ${_getBranchName()}',
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (PermissionsService().canExportStock)
            IconButton(
              icon: const Icon(Icons.download, color: Colors.blueAccent),
              onPressed: _exportExcel,
              tooltip: 'تصدير Excel',
            ),
          if (PermissionsService().canExportStock)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
              onPressed: _exportPDF,
              tooltip: 'تصدير PDF',
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _calculateBalances,
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
          child: Column(
            children: [
              // ===== فلاتر البحث (بدون الفرع) =====
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String?>(
                              value: _selectedStoreCode,
                              dropdownColor: Colors.indigo.shade900,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'المخزن',
                                labelStyle: TextStyle(color: Colors.white70),
                                isDense: true,
                              ),
                              items: _stores.map((s) {
                                return DropdownMenuItem<String?>(
                                  value: s['code'],
                                  child: Text(s['name'] ?? ''),
                                );
                              }).toList(),
                              onChanged: (val) {
                                setState(() => _selectedStoreCode = val);
                                _calculateBalances();
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GestureDetector(
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _selectedDate,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now(),
                                );
                                if (picked != null) {
                                  setState(() => _selectedDate = picked);
                                  _calculateBalances();
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.calendar_today,
                                      color: Colors.amber,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'التاريخ: ${DateFormat('yyyy-MM-dd').format(_selectedDate)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.cyanAccent.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.cyanAccent.withOpacity(0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.info_outline,
                                    color: Colors.cyanAccent,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'آخر جرد: ${_getLastInventoryDate()}',
                                    style: const TextStyle(
                                      color: Colors.cyanAccent,
                                      fontSize: 12,
                                      fontFamily: 'Cairo',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ===== الجدول =====
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.white))
                    : !_hasData
                        ? const Center(
                            child: Text(
                              'اختر المخزن لعرض الرصيد',
                              style: TextStyle(color: Colors.white60),
                            ),
                          )
                        : _itemsData.isEmpty
                            ? const Center(
                                child: Text(
                                  'لا توجد أصناف برصيد أكبر من صفر',
                                  style: TextStyle(color: Colors.white60),
                                ),
                              )
                            : _buildTable(),
              ),

              // ===== الإجماليات =====
              if (_hasData && _itemsData.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        children: [
                          const Text(
                            'إجمالي الكميات',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              fontFamily: 'Cairo',
                            ),
                          ),
                          Text(
                            totalQuantity.toStringAsFixed(0),
                            style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Container(width: 1, height: 30, color: Colors.white24),
                      if (PermissionsService().canViewStockWholesalePrice)
                        Column(
                          children: [
                            const Text(
                              'قيمة الجملة',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                                fontFamily: 'Cairo',
                              ),
                            ),
                            Text(
                              _formatCurrency(totalWholesaleValue),
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      if (PermissionsService().canViewStockWholesalePrice)
                        Container(width: 1, height: 30, color: Colors.white24),
                      Column(
                        children: [
                          const Text(
                            'قيمة البيع',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              fontFamily: 'Cairo',
                            ),
                          ),
                          Text(
                            _formatCurrency(totalRetailValue),
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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
}