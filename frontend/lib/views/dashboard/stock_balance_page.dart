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
  final String? branchName;

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
  String? _selectedBranchCode;
  String? _selectedStoreCode;
  DateTime _selectedDate = DateTime.now();

  List<Map<String, dynamic>> _itemsData = [];

  bool _isLoading = false;
  bool _hasData = false;

  List<Map<String, String>> _stores = [];

  @override
  void initState() {
    super.initState();

    _selectedBranchCode =
        widget.selectedBranchCode;

    _loadDropdowns();
  }

  // ============================================================
  // تحميل المخازن
  // ============================================================

  Future<void> _loadDropdowns() async {
    try {
      final box =
          Hive.box('coding_box');

      _stores = [];

      final raw =
          box.get(
            '${widget.companyCode}_stores',
            defaultValue: [],
          );

      if (raw is List) {
        for (final item in raw) {
          if (item is Map &&
              item['code'] != null &&
              item['name'] != null) {
            _stores.add({
              'code': item['code'].toString(),
              'name': item['name'].toString(),
            });
          }
        }
      }

      if (_stores.isNotEmpty &&
          _selectedStoreCode == null) {
        _selectedStoreCode =
            _stores.first['code'];
      }

      if (mounted) {
        setState(() {});
      }

      await _calculateBalances();
    } catch (e) {
      print(
        '❌ خطأ في تحميل المخازن: $e',
      );
    }
  }

  // ============================================================
  // اسم الفرع
  // ============================================================

  String _getBranchName() {
    if (widget.branchName != null &&
        widget.branchName!.isNotEmpty) {
      return widget.branchName!;
    }

    if (_selectedBranchCode == null) {
      return 'غير محدد';
    }

    try {
      final box =
          Hive.box('coding_box');

      final raw =
          box.get(
            '${widget.companyCode}_branches',
            defaultValue: [],
          );

      if (raw is List) {
        for (final item in raw) {
          if (item is Map &&
              item['code']?.toString() ==
                  _selectedBranchCode) {
            return item['name']?.toString() ??
                'فرع غير معروف';
          }
        }
      }

      return _selectedBranchCode!;
    } catch (_) {
      return _selectedBranchCode!;
    }
  }

  // ============================================================
  // اسم المخزن
  // ============================================================

  String _getStoreName(String? code) {
    if (code == null ||
        code.isEmpty) {
      return 'غير محدد';
    }

    final found =
        _stores.firstWhere(
      (s) => s['code'] == code,
      orElse: () => {},
    );

    return found['name'] ?? code;
  }

  // ============================================================
  // الحساب الأساسي لرصيد المخزون
  //
  // التسلسل:
  //
  // جرد عام
  //   ↓
  // مشتريات
  //   ↓
  // جرد محدد
  //   ↓
  // مشتريات
  //
  // والجرد العام يبدأ الحساب من الصفر.
  // ============================================================

  Future<void> _calculateBalances() async {
    if (_selectedBranchCode == null ||
        _selectedStoreCode == null) {
      if (!mounted) return;

      setState(() {
        _itemsData = [];
        _hasData = false;
      });

      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final inventoryBox =
          Hive.box('inventory_box');

      final supplierBox =
          Hive.box('supplier_box');

      final codingBox =
          Hive.box('coding_box');

      final selectedDay =
          DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
      );

      // ========================================================
      // 1) تحميل الأصناف من التكويد
      // ========================================================

      final Map<String, Map<String, dynamic>>
          itemsMap = {};

      final rawItems =
          codingBox.get(
        '${widget.companyCode}_items',
      );

      if (rawItems is List) {
        for (final raw in rawItems) {
          if (raw is! Map) continue;

          final item =
              Map<String, dynamic>.from(raw);

          if (item['is_deleted'] == true) {
            continue;
          }

          final code =
              item['code']?.toString() ?? '';

          if (code.isNotEmpty) {
            itemsMap[code] = item;
          }
        }
      }

      // ========================================================
      // 2) جلب كل الجردات
      // ========================================================

      final List<InventoryModel>
          inventories = [];

      for (final key
          in inventoryBox.keys) {
        final raw =
            inventoryBox.get(key);

        if (raw is! List) continue;

        for (final value in raw) {
          if (value is! Map) continue;

          final item =
              Map<String, dynamic>.from(
            value,
          );

          if (item['is_deleted'] ==
              true) {
            continue;
          }

          if (item['company_code']
                  ?.toString() !=
              widget.companyCode) {
            continue;
          }

          if (item['branch_code']
                  ?.toString() !=
              _selectedBranchCode) {
            continue;
          }

          if (item['store_code']
                  ?.toString() !=
              _selectedStoreCode) {
            continue;
          }

          final date =
              DateTime.tryParse(
            item['date']?.toString() ??
                '',
          );

          if (date == null) {
            continue;
          }

          final day =
              DateTime(
            date.year,
            date.month,
            date.day,
          );

          if (day.isAfter(selectedDay)) {
            continue;
          }

          try {
            inventories.add(
              InventoryModel.fromMap(
                item,
              ),
            );
          } catch (_) {}
        }
      }

      // الأقدم أولاً
      inventories.sort(
        (a, b) => a.date.compareTo(
          b.date,
        ),
      );

      // ========================================================
      // 3) جلب كل المشتريات التي تدخل المخزن
      // ========================================================

      final List<Map<String, dynamic>>
          purchases = [];

      for (final key
          in supplierBox.keys) {
        final raw =
            supplierBox.get(key);

        if (raw is! List) continue;

        for (final value in raw) {
          if (value is! Map) continue;

          final purchase =
              Map<String, dynamic>.from(
            value,
          );

          if (purchase['is_deleted'] ==
              true) {
            continue;
          }

          if (purchase['company_code']
                  ?.toString() !=
              widget.companyCode) {
            continue;
          }

          if (purchase['branch_code']
                  ?.toString() !=
              _selectedBranchCode) {
            continue;
          }

          if (purchase['store_code']
                  ?.toString() !=
              _selectedStoreCode) {
            continue;
          }

          // فقط الفواتير التي تدخل المخزن
          if (purchase['is_add_to_store'] !=
              true) {
            continue;
          }

          final date =
              DateTime.tryParse(
            purchase['date']?.toString() ??
                '',
          );

          if (date == null) {
            continue;
          }

          final day =
              DateTime(
            date.year,
            date.month,
            date.day,
          );

          if (day.isAfter(selectedDay)) {
            continue;
          }

          purchases.add(
            purchase,
          );
        }
      }

      // ========================================================
      // 4) إنشاء Timeline لكل الأحداث
      // ========================================================

      final List<_StockEvent>
          events = [];

      // الجردات
      for (final inventory
          in inventories) {
        events.add(
          _StockEvent(
            date: DateTime.parse(
              inventory.date,
            ),
            priority: inventory.inventoryType ==
                    'general'
                ? 2
                : 1,
            type: 'inventory',
            data: inventory,
          ),
        );
      }

      // المشتريات
      for (final purchase
          in purchases) {
        events.add(
          _StockEvent(
            date: DateTime.parse(
              purchase['date']
                  .toString(),
            ),
            // مهم:
            // لو الشراء والجرد في نفس اليوم
            // الجرد يتنفذ بعد الشراء.
            priority: 0,
            type: 'purchase',
            data: purchase,
          ),
        );
      }

      // ========================================================
      // ترتيب الأحداث
      //
      // في نفس اليوم:
      // شراء أولاً
      // جرد محدد بعده
      // جرد عام أخيراً
      // ========================================================

      events.sort(
        (a, b) {
          final dateCompare =
              a.date.compareTo(
            b.date,
          );

          if (dateCompare != 0) {
            return dateCompare;
          }

          return a.priority.compareTo(
            b.priority,
          );
        },
      );

      // ========================================================
      // 5) حساب الرصيد
      // ========================================================

      final Map<String, double>
          balances = {};

      for (final event
          in events) {
        // ------------------------------------------------------
        // جرد
        // ------------------------------------------------------

        if (event.type ==
            'inventory') {
          final InventoryModel inventory =
              event.data
                  as InventoryModel;

          // جرد عام
          if (inventory.inventoryType ==
              'general') {
            balances.clear();

            for (final item
                in inventory.items) {
              balances[item.code] =
                  item.quantity;
            }
          }

          // جرد محدد
          else {
            for (final item
                in inventory.items) {
              balances[item.code] =
                  item.quantity;
            }
          }

          continue;
        }

        // ------------------------------------------------------
        // شراء
        // ------------------------------------------------------

        final Map<String, dynamic>
            purchase =
            event.data;

        final rawPurchaseItems =
            purchase['items'];

        if (rawPurchaseItems
            is! List) {
          continue;
        }

        for (final rawProduct
            in rawPurchaseItems) {
          if (rawProduct is! Map) {
            continue;
          }

          final product =
              Map<String, dynamic>.from(
            rawProduct,
          );

          final code =
              product['code']
                  ?.toString() ??
                  '';

          if (code.isEmpty) {
            continue;
          }

          final quantity =
              product['quantity']
                      is num
                  ? (product['quantity']
                          as num)
                      .toDouble()
                  : double.tryParse(
                        product['quantity']
                                ?.toString() ??
                            '0',
                      ) ??
                      0.0;

          balances[code] =
              (balances[code] ?? 0.0) +
                  quantity;
        }
      }

      // ========================================================
      // 6) حذف الأرصدة الصفرية والسالبة
      // ========================================================

      balances.removeWhere(
        (code, quantity) =>
            quantity == 0,
      );

      // ========================================================
      // 7) تجهيز البيانات للعرض
      // ========================================================

      final List<Map<String, dynamic>>
          itemsData = [];

      balances.forEach(
        (code, quantity) {
          final item =
              itemsMap[code] ?? {};

          final wholesalePrice =
              double.tryParse(
                    item['wholesale_price']
                            ?.toString() ??
                        item['wholesalePrice']
                            ?.toString() ??
                        '0',
                  ) ??
                  0.0;

          final sellingPrice =
              double.tryParse(
                    item['selling_price']
                            ?.toString() ??
                        item['sellingPrice']
                            ?.toString() ??
                        '0',
                  ) ??
                  0.0;

          itemsData.add({
            'code': code,
            'name':
                item['name'] ??
                'غير معروف',
            'quantity': quantity,
            'wholesalePrice':
                wholesalePrice,
            'sellingPrice':
                sellingPrice,
            'totalWholesale':
                quantity *
                    wholesalePrice,
            'totalRetail':
                quantity *
                    sellingPrice,
          });
        },
      );

      itemsData.sort(
        (a, b) =>
            a['code']
                .toString()
                .compareTo(
                  b['code'].toString(),
                ),
      );

      if (!mounted) return;

      setState(() {
        _itemsData = itemsData;
        _hasData = true;
        _isLoading = false;
      });
    } catch (e) {
      print(
        '❌ خطأ في حساب أرصدة المخزون: $e',
      );

      if (!mounted) return;

      setState(() {
        _itemsData = [];
        _hasData = false;
        _isLoading = false;
      });
    }
  }

  // ============================================================
  // الإجماليات
  // ============================================================

  double get totalQuantity =>
      _itemsData.fold(
        0.0,
        (sum, item) =>
            sum +
            (item['quantity']
                    as double),
      );

  double get totalWholesaleValue =>
      _itemsData.fold(
        0.0,
        (sum, item) =>
            sum +
            (item['totalWholesale']
                    as double),
      );

  double get totalRetailValue =>
      _itemsData.fold(
        0.0,
        (sum, item) =>
            sum +
            (item['totalRetail']
                    as double),
      );

  String _formatQuantity(double amount) =>
      NumberFormat('0.########', 'en_US').format(amount);
  String _formatCurrency(
    double amount,
  ) {
    return NumberFormat(
      '#,##0.00',
      'en_US',
    ).format(amount);
  }

  // ============================================================
  // تصدير Excel
  // ============================================================

  Future<void> _exportExcel() async {
    if (_itemsData.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('لا توجد بيانات للتصدير'),
          backgroundColor:
              Colors.orange,
        ),
      );

      return;
    }

    try {
      final List<String>
          headers = [
        'الكود',
        'الصنف',
        'الكمية',
      ];

      final List<String>
          keys = [
        'code',
        'name',
        'quantity',
      ];

      if (PermissionsService()
          .canViewStockWholesalePrice) {
        headers.add(
          'سعر الجملة',
        );

        keys.add(
          'wholesalePrice',
        );

        headers.add(
          'قيمة الجملة',
        );

        keys.add(
          'totalWholesale',
        );
      }

      headers.add(
        'سعر البيع',
      );

      keys.add(
        'sellingPrice',
      );

      headers.add(
        'قيمة البيع',
      );

      keys.add(
        'totalRetail',
      );

      final exportData =
          _itemsData.map(
        (item) {
          final Map<String, dynamic>
              row = {};

          for (final key
              in keys) {
            row[key] =
                item[key] ?? 0;
          }

          return row;
        },
      ).toList();

      await ExportService
          .exportToExcel(
        exportData,
        'رصيد_المخزون_${DateFormat('yyyy-MM-dd', 'en_US').format(DateTime.now())}',
        headers,
        keys,
      );

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('تم تصدير البيانات بنجاح'),
          backgroundColor:
              Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content:
              Text('فشل التصدير: $e'),
          backgroundColor:
              Colors.red,
        ),
      );
    }
  }

  // ============================================================
  // تصدير PDF
  // ============================================================

  Future<void> _exportPDF() async {
    if (_itemsData.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('لا توجد بيانات للتصدير'),
          backgroundColor:
              Colors.orange,
        ),
      );

      return;
    }

    try {
      final List<String>
          headers = [
        'الكود',
        'الصنف',
        'الكمية',
      ];

      final List<String>
          keys = [
        'code',
        'name',
        'quantity',
      ];

      if (PermissionsService()
          .canViewStockWholesalePrice) {
        headers.add(
          'سعر الجملة',
        );

        keys.add(
          'wholesalePrice',
        );

        headers.add(
          'قيمة الجملة',
        );

        keys.add(
          'totalWholesale',
        );
      }

      headers.add(
        'سعر البيع',
      );

      keys.add(
        'sellingPrice',
      );

      headers.add(
        'قيمة البيع',
      );

      keys.add(
        'totalRetail',
      );

      final exportData =
          _itemsData.map(
        (item) {
          final Map<String, dynamic>
              row = {};

          for (final key
              in keys) {
            row[key] =
                item[key] ?? 0;
          }

          return row;
        },
      ).toList();

      final summary = {
        'totalQuantity':
            totalQuantity,
        'totalWholesale':
            totalWholesaleValue,
        'totalRetail':
            totalRetailValue,
      };

      await ExportService
          .exportToPDF(
        data: exportData,
        title:
            'تقرير رصيد المخزون',
        headers: headers,
        keys: keys,
        summary: summary,
        branchName:
            _getBranchName(),
        storeName:
            _getStoreName(
          _selectedStoreCode,
        ),
        date:
            DateFormat(
          'yyyy-MM-dd',
        ).format(
          _selectedDate,
        ),
      );

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('تم تصدير البيانات بنجاح'),
          backgroundColor:
              Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content:
              Text('فشل تصدير PDF: $e'),
          backgroundColor:
              Colors.red,
        ),
      );
    }
  }

  // ============================================================
  // تاريخ آخر جرد
  // ============================================================

  String _getLastInventoryDate() {
    if (_selectedBranchCode == null ||
        _selectedStoreCode == null) {
      return 'لا يوجد';
    }

    try {
      final box =
          Hive.box('inventory_box');

      final selectedDay =
          DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
      );

      DateTime? latestDate;

      for (final key in box.keys) {
        final raw =
            box.get(key);

        if (raw is! List) continue;

        for (final value in raw) {
          if (value is! Map) {
            continue;
          }

          final item =
              Map<String, dynamic>.from(
            value,
          );

          if (item['is_deleted'] ==
              true) {
            continue;
          }

          if (item['company_code']
                  ?.toString() !=
              widget.companyCode) {
            continue;
          }

          if (item['branch_code']
                  ?.toString() !=
              _selectedBranchCode) {
            continue;
          }

          if (item['store_code']
                  ?.toString() !=
              _selectedStoreCode) {
            continue;
          }

          final date =
              DateTime.tryParse(
            item['date']?.toString() ??
                '',
          );

          if (date == null) {
            continue;
          }

          final day =
              DateTime(
            date.year,
            date.month,
            date.day,
          );

          if (day.isAfter(
            selectedDay,
          )) {
            continue;
          }

          if (latestDate == null ||
              day.isAfter(
                latestDate,
              )) {
            latestDate = day;
          }
        }
      }

      if (latestDate == null) {
        return 'لا يوجد';
      }

      return DateFormat(
        'yyyy-MM-dd',
      ).format(
        latestDate,
      );
    } catch (_) {
      return 'خطأ';
    }
  }

  // ============================================================
  // بناء الجدول
  // ============================================================

  Widget _buildTable() {
    final List<String>
        headers = [
      '#',
      'الكود',
      'الصنف',
      'الكمية',
    ];

    final List<double>
        columnWidths = [
      40,
      70,
      120,
      70,
    ];

    if (PermissionsService()
        .canViewStockWholesalePrice) {
      headers.add(
        'سعر الجملة',
      );
      columnWidths.add(
        80,
      );

      headers.add(
        'قيمة الجملة',
      );
      columnWidths.add(
        80,
      );
    }

    headers.add(
      'سعر البيع',
    );
    columnWidths.add(
      80,
    );

    headers.add(
      'قيمة البيع',
    );
    columnWidths.add(
      80,
    );

    final List<Widget>
        headerWidgets = [];

    for (int i = 0;
        i < headers.length;
        i++) {
      headerWidgets.add(
        SizedBox(
          width:
              columnWidths[i],
          child: Text(
            headers[i],
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color:
                  Colors.cyan,
              fontWeight:
                  FontWeight.bold,
              fontSize: 11,
              fontFamily:
                  'Cairo',
            ),
          ),
        ),
      );
    }

    final List<Widget>
        rows = [];

    for (
      int idx = 0;
      idx < _itemsData.length;
      idx++
    ) {
      final item =
          _itemsData[idx];

      final List<Widget>
          rowCells = [];

      int cellIndex = 0;

      // #

      rowCells.add(
        SizedBox(
          width:
              columnWidths[cellIndex++],
          child: Text(
            '${idx + 1}',
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color:
                  Colors.white54,
              fontSize: 11,
            ),
          ),
        ),
      );

      // الكود

      rowCells.add(
        SizedBox(
          width:
              columnWidths[cellIndex++],
          child: Text(
            item['code']
                .toString(),
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color:
                  Colors.white70,
              fontSize: 11,
            ),
          ),
        ),
      );

      // الصنف

      rowCells.add(
        SizedBox(
          width:
              columnWidths[cellIndex++],
          child: Text(
            item['name']
                .toString(),
            textAlign:
                TextAlign.center,
            overflow:
                TextOverflow
                    .ellipsis,
            style:
                const TextStyle(
              color:
                  Colors.white,
              fontSize: 12,
            ),
          ),
        ),
      );

      // الكمية

      rowCells.add(
        SizedBox(
          width:
              columnWidths[cellIndex++],
          child: Text(
            _formatQuantity(item['quantity'] as double),
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color:
                  Colors.cyanAccent,
              fontSize: 12,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ),
      );

      // الجملة

      if (PermissionsService()
          .canViewStockWholesalePrice) {
        rowCells.add(
          SizedBox(
            width:
                columnWidths[cellIndex++],
            child: Text(
              _formatCurrency(
                item[
                    'wholesalePrice']
                    as double,
              ),
              textAlign:
                  TextAlign.center,
              style:
                  const TextStyle(
                color:
                    Colors.greenAccent,
                fontSize: 11,
              ),
            ),
          ),
        );

        rowCells.add(
          SizedBox(
            width:
                columnWidths[cellIndex++],
            child: Text(
              _formatCurrency(
                item[
                    'totalWholesale']
                    as double,
              ),
              textAlign:
                  TextAlign.center,
              style:
                  const TextStyle(
                color:
                    Colors.greenAccent,
                fontSize: 12,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        );
      }

      // البيع

      rowCells.add(
        SizedBox(
          width:
              columnWidths[cellIndex++],
          child: Text(
            _formatCurrency(
              item['sellingPrice']
                  as double,
            ),
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color:
                  Colors.amber,
              fontSize: 11,
            ),
          ),
        ),
      );

      rowCells.add(
        SizedBox(
          width:
              columnWidths[cellIndex++],
          child: Text(
            _formatCurrency(
              item['totalRetail']
                  as double,
            ),
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color:
                  Colors.amber,
              fontSize: 12,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ),
      );

      rows.add(
        Container(
          padding:
              const EdgeInsets
                  .symmetric(
            vertical: 4,
            horizontal: 4,
          ),
          decoration:
              BoxDecoration(
            border:
                Border(
              bottom:
                  BorderSide(
                color: Colors.white
                    .withOpacity(
                  0.05,
                ),
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children:
                rowCells,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection:
          Axis.vertical,
      child:
          SingleChildScrollView(
        scrollDirection:
            Axis.horizontal,
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment
                  .start,
          children: [
            Container(
              padding:
                  const EdgeInsets
                      .symmetric(
                vertical: 8,
                horizontal: 4,
              ),
              decoration:
                  BoxDecoration(
                color:
                    Colors.white10,
                borderRadius:
                    BorderRadius.circular(
                  8,
                ),
              ),
              child: Row(
                children:
                    headerWidgets,
              ),
            ),
            const SizedBox(
              height: 4,
            ),
            Column(
              children:
                  rows,
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
        .canShowStock) {
      return Scaffold(
        appBar:
            AppBar(
          title:
              const Text(
            'رصيد المخزون',
            style:
                TextStyle(
              color:
                  Colors.white,
            ),
          ),
          backgroundColor:
              Colors.transparent,
          elevation: 0,
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
              begin:
                  Alignment.topLeft,
              end:
                  Alignment.bottomRight,
            ),
          ),
          child:
              const Center(
            child:
                Text(
              'ليس لديك صلاحية لعرض رصيد المخزون',
              style:
                  TextStyle(
                color:
                    Colors.white70,
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

    return Scaffold(
      appBar:
          AppBar(
        title:
            Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            const Text(
              'رصيد المخزون',
              style:
                  TextStyle(
                color:
                    Colors.white,
                fontFamily:
                    'Cairo',
                fontSize:
                    16,
              ),
            ),
            Text(
              'الفرع: ${_getBranchName()}',
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
        elevation: 0,
        centerTitle: true,
        toolbarHeight: 75,
        leading:
            IconButton(
          icon:
              const Icon(
            Icons.arrow_back,
            color:
                Colors.white,
          ),
          onPressed:
              () => Navigator.pop(
            context,
          ),
        ),
        actions: [
          if (PermissionsService()
              .canExportStock)
            IconButton(
              icon:
                  const Icon(
                Icons.download,
                color:
                    Colors.blueAccent,
              ),
              onPressed:
                  _exportExcel,
              tooltip:
                  'تصدير Excel',
            ),
          if (PermissionsService()
              .canExportStock)
            IconButton(
              icon:
                  const Icon(
                Icons.picture_as_pdf,
                color:
                    Colors.redAccent,
              ),
              onPressed:
                  _exportPDF,
              tooltip:
                  'تصدير PDF',
            ),
          IconButton(
            icon:
                const Icon(
              Icons.refresh,
              color:
                  Colors.white,
            ),
            onPressed:
                _calculateBalances,
            tooltip:
                'تحديث',
          ),
        ],
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
            begin:
                Alignment.topLeft,
            end:
                Alignment.bottomRight,
          ),
        ),
        child:
            SafeArea(
          child:
              Column(
            children: [
              // ==================================================
              // الفلاتر
              // ==================================================

              GlassCard(
                child:
                    Padding(
                  padding:
                      const EdgeInsets.all(
                    12.0,
                  ),
                  child:
                      Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child:
                                DropdownButtonFormField<String?>(
                              value:
                                  _selectedStoreCode,
                              dropdownColor:
                                  Colors.indigo.shade900,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration:
                                  const InputDecoration(
                                labelText:
                                    'المخزن',
                                labelStyle:
                                    TextStyle(
                                  color:
                                      Colors.white70,
                                ),
                                isDense:
                                    true,
                              ),
                              items:
                                  _stores.map(
                                (s) {
                                  return DropdownMenuItem<
                                      String?>(
                                    value:
                                        s['code'],
                                    child:
                                        Text(
                                      s['name'] ??
                                          '',
                                    ),
                                  );
                                },
                              ).toList(),
                              onChanged:
                                  (val) {
                                setState(
                                  () =>
                                      _selectedStoreCode =
                                          val,
                                );

                                _calculateBalances();
                              },
                            ),
                          ),
                          const SizedBox(
                            width: 8,
                          ),
                          Expanded(
                            child:
                                GestureDetector(
                              onTap:
                                  () async {
                                final picked =
                                    await showDatePicker(
                                  context:
                                      context,
                                  initialDate:
                                      _selectedDate,
                                  firstDate:
                                      DateTime(
                                    2020,
                                  ),
                                  lastDate:
                                      DateTime.now(),
                                );

                                if (picked !=
                                    null) {
                                  setState(
                                    () =>
                                        _selectedDate =
                                            picked,
                                  );

                                  _calculateBalances();
                                }
                              },
                              child:
                                  Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                  horizontal:
                                      12,
                                  vertical:
                                      12,
                                ),
                                decoration:
                                    BoxDecoration(
                                  color:
                                      Colors.white.withOpacity(
                                    0.05,
                                  ),
                                  borderRadius:
                                      BorderRadius.circular(
                                    8,
                                  ),
                                  border:
                                      Border.all(
                                    color:
                                        Colors.white24,
                                  ),
                                ),
                                child:
                                    Row(
                                  children: [
                                    const Icon(
                                      Icons.calendar_today,
                                      color:
                                          Colors.amber,
                                      size:
                                          18,
                                    ),
                                    const SizedBox(
                                      width:
                                          8,
                                    ),
                                    Text(
                                      'التاريخ: ${DateFormat('yyyy-MM-dd', 'en_US').format(_selectedDate)}',
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white,
                                        fontSize:
                                            13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                        height: 8,
                      ),
                      Row(
                        children: [
                          Expanded(
                            child:
                                Container(
                              padding:
                                  const EdgeInsets.symmetric(
                                horizontal:
                                    12,
                                vertical:
                                    12,
                              ),
                              decoration:
                                  BoxDecoration(
                                color:
                                    Colors.cyanAccent.withOpacity(
                                  0.1,
                                ),
                                borderRadius:
                                    BorderRadius.circular(
                                  8,
                                ),
                                border:
                                    Border.all(
                                  color:
                                      Colors.cyanAccent.withOpacity(
                                    0.3,
                                  ),
                                ),
                              ),
                              child:
                                  Row(
                                children: [
                                  const Icon(
                                    Icons.info_outline,
                                    color:
                                        Colors.cyanAccent,
                                    size:
                                        18,
                                  ),
                                  const SizedBox(
                                    width:
                                        8,
                                  ),
                                  Text(
                                    'آخر جرد: ${_getLastInventoryDate()}',
                                    style:
                                        const TextStyle(
                                      color:
                                          Colors.cyanAccent,
                                      fontSize:
                                          12,
                                      fontFamily:
                                          'Cairo',
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

              const SizedBox(
                height: 8,
              ),

              // ==================================================
              // الجدول
              // ==================================================

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
                        : !_hasData
                            ? const Center(
                                child:
                                    Text(
                                  'اختر المخزن لعرض الرصيد',
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.white60,
                                  ),
                                ),
                              )
                            : _itemsData.isEmpty
                                ? const Center(
                                    child:
                                        Text(
                                      'لا توجد أصناف برصيد أكبر من صفر',
                                      style:
                                          TextStyle(
                                        color:
                                            Colors.white60,
                                      ),
                                    ),
                                  )
                                : _buildTable(),
              ),

              // ==================================================
              // الإجماليات
              // ==================================================

              if (_hasData &&
                  _itemsData.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.all(
                    12,
                  ),
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.white.withOpacity(
                      0.05,
                    ),
                    border:
                        Border(
                      top:
                          BorderSide(
                        color:
                            Colors.white.withOpacity(
                          0.1,
                        ),
                        width:
                            1,
                      ),
                    ),
                  ),
                  child:
                      Row(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .spaceAround,
                    children: [
                      Column(
                        children: [
                          const Text(
                            'إجمالي الكميات',
                            style:
                                TextStyle(
                              color:
                                  Colors.white60,
                              fontSize:
                                  12,
                              fontFamily:
                                  'Cairo',
                            ),
                          ),
                          Text(
                            _formatQuantity(totalQuantity),
                            style:
                                const TextStyle(
                              color:
                                  Colors.cyanAccent,
                              fontSize:
                                  16,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        width:
                            1,
                        height:
                            30,
                        color:
                            Colors.white24,
                      ),
                      if (PermissionsService()
                          .canViewStockWholesalePrice)
                        Column(
                          children: [
                            const Text(
                              'قيمة الجملة',
                              style:
                                  TextStyle(
                                color:
                                    Colors.white60,
                                fontSize:
                                    12,
                                fontFamily:
                                    'Cairo',
                              ),
                            ),
                            Text(
                              _formatCurrency(
                                totalWholesaleValue,
                              ),
                              style:
                                  const TextStyle(
                                color:
                                    Colors.greenAccent,
                                fontSize:
                                    16,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      if (PermissionsService()
                          .canViewStockWholesalePrice)
                        Container(
                          width:
                              1,
                          height:
                              30,
                          color:
                              Colors.white24,
                        ),
                      Column(
                        children: [
                          const Text(
                            'قيمة البيع',
                            style:
                                TextStyle(
                              color:
                                  Colors.white60,
                              fontSize:
                                  12,
                              fontFamily:
                                  'Cairo',
                            ),
                          ),
                          Text(
                            _formatCurrency(
                              totalRetailValue,
                            ),
                            style:
                                const TextStyle(
                              color:
                                  Colors.amber,
                              fontSize:
                                  16,
                              fontWeight:
                                  FontWeight.bold,
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

// ============================================================
// حدث داخلي لحساب حركة المخزون
// ============================================================

class _StockEvent {
  final DateTime date;
  final int priority;
  final String type;
  final dynamic data;

  const _StockEvent({
    required this.date,
    required this.priority,
    required this.type,
    required this.data,
  });
}