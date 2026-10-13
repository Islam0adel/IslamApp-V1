// lib/views/dashboard/stock_balance_page.dart

import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';

// import '../../models/inventory_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';
import '../../services/stock_balance_service.dart';

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
  // ✅ تم نقل المنطق إلى StockBalanceService
  // بحيث يمكن استخدامه من صفحة التقارير أيضاً.
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
      // ✅ استخدام الخدمة المشتركة
      final itemsData = await StockBalanceService.calculateBalances(
        companyCode: widget.companyCode,
        branchCode: _selectedBranchCode!,
        storeCode: _selectedStoreCode!,
        toDate: _selectedDate,
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
        SnackBar(
          content:
              Text('لا توجد بيانات للتصدير'),
          backgroundColor:
              AppTheme.warningOrangeFor(context),
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
        SnackBar(
          content:
              Text('تم تصدير البيانات بنجاح'),
          backgroundColor:
              AppTheme.successStrongFor(context),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content:
              Text('فشل التصدير: $e'),
          backgroundColor:
              AppTheme.dangerStrongFor(context),
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
        SnackBar(
          content:
              Text('لا توجد بيانات للتصدير'),
          backgroundColor:
              AppTheme.warningOrangeFor(context),
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
        SnackBar(
          content:
              Text('تم تصدير البيانات بنجاح'),
          backgroundColor:
              AppTheme.successStrongFor(context),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content:
              Text('فشل تصدير PDF: $e'),
          backgroundColor:
              AppTheme.dangerStrongFor(context),
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
                TextStyle(
              color:
                  AppTheme.accentAltFor(context),
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
                TextStyle(
              color:
                  AppTheme.textHintFor(context),
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
                TextStyle(
              color:
                  AppTheme.textSoftFor(context),
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
                TextStyle(
              color:
                  AppTheme.textMainFor(context),
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
                TextStyle(
              color:
                  AppTheme.accentFor(context),
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
                  TextStyle(
                color:
                    AppTheme.successFor(context),
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
                  TextStyle(
                color:
                    AppTheme.successFor(context),
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
                TextStyle(
              color:
                  AppTheme.warningFor(context),
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
                TextStyle(
              color:
                  AppTheme.warningFor(context),
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
                color: GlassStyle.line05For(context),
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
                    GlassStyle.fill10For(context),
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
              Text(
            'رصيد المخزون',
            style:
                TextStyle(
              color:
                  AppTheme.textMainFor(context),
            ),
          ),
          backgroundColor:
              AppTheme.appBarBg,
          elevation: 0,
        ),
        body:
            Container(
          decoration:
              BoxDecoration(gradient: LinearGradient(colors: AppTheme.pageGradient(context),
              begin:
                  Alignment.topLeft,
              end:
                  Alignment.bottomRight,
            ),
          ),
          child:
              Center(
            child:
                Text(
              'ليس لديك صلاحية لعرض رصيد المخزون',
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

    return Scaffold(
      appBar:
          AppBar(
        title:
            Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            Text(
              'رصيد المخزون',
              style:
                  TextStyle(
                color:
                    AppTheme.textMainFor(context),
                fontFamily:
                    'Cairo',
                fontSize:
                    16,
              ),
            ),
            Text(
              'الفرع: ${_getBranchName()}',
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
        elevation: 0,
        centerTitle: true,
        toolbarHeight: 75,
        leading:
            IconButton(
          icon:
              Icon(
            Icons.arrow_back,
            color:
                AppTheme.textMainFor(context),
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
                  Icon(
                Icons.download,
                color:
                    AppTheme.infoFor(context),
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
                  Icon(
                Icons.picture_as_pdf,
                color:
                    AppTheme.dangerFor(context),
              ),
              onPressed:
                  _exportPDF,
              tooltip:
                  'تصدير PDF',
            ),
          IconButton(
            icon:
                Icon(
              Icons.refresh,
              color:
                  AppTheme.textMainFor(context),
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
            BoxDecoration(gradient: LinearGradient(colors: AppTheme.pageGradient(context),
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
                                  AppTheme.dropdownBackground(context),
                              style:
                                  TextStyle(
                                color:
                                    AppTheme.textMainFor(context),
                              ),
                              decoration:
                                  InputDecoration(
                                labelText:
                                    'المخزن',
                                labelStyle:
                                    TextStyle(
                                  color:
                                      AppTheme.textSoftFor(context),
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
                                      GlassStyle.fill05For(context),
                                  borderRadius:
                                      BorderRadius.circular(
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
                                      Icons.calendar_today,
                                      color:
                                          AppTheme.warningFor(context),
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
                                          TextStyle(
                                        color:
                                            AppTheme.textMainFor(context),
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
                                    GlassStyle.accentFill10For(context),
                                borderRadius:
                                    BorderRadius.circular(
                                  8,
                                ),
                                border:
                                    Border.all(
                                  color:
                                      GlassStyle.accentBorder30For(context),
                                ),
                              ),
                              child:
                                  Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color:
                                        AppTheme.accentFor(context),
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
                                        TextStyle(
                                      color:
                                          AppTheme.accentFor(context),
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
                        ? Center(
                            child:
                                CircularProgressIndicator(
                              color:
                                  AppTheme.textMainFor(context),
                            ),
                          )
                        : !_hasData
                            ? Center(
                                child:
                                    Text(
                                  'اختر المخزن لعرض الرصيد',
                                  style:
                                      TextStyle(
                                    color:
                                        AppTheme.textMutedFor(context),
                                  ),
                                ),
                              )
                            : _itemsData.isEmpty
                                ? Center(
                                    child:
                                        Text(
                                      'لا توجد أصناف برصيد أكبر من صفر',
                                      style:
                                          TextStyle(
                                        color:
                                            AppTheme.textMutedFor(context),
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
                        GlassStyle.fill05For(context),
                    border:
                        Border(
                      top:
                          BorderSide(
                        color:
                            GlassStyle.line10For(context),
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
                          Text(
                            'إجمالي الكميات',
                            style:
                                TextStyle(
                              color:
                                  AppTheme.textMutedFor(context),
                              fontSize:
                                  12,
                              fontFamily:
                                  'Cairo',
                            ),
                          ),
                          Text(
                            _formatQuantity(totalQuantity),
                            style:
                                TextStyle(
                              color:
                                  AppTheme.accentFor(context),
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
                            GlassStyle.line24For(context),
                      ),
                      if (PermissionsService()
                          .canViewStockWholesalePrice)
                        Column(
                          children: [
                            Text(
                              'قيمة الجملة',
                              style:
                                  TextStyle(
                                color:
                                    AppTheme.textMutedFor(context),
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
                      if (PermissionsService()
                          .canViewStockWholesalePrice)
                        Container(
                          width:
                              1,
                          height:
                              30,
                          color:
                              GlassStyle.line24For(context),
                        ),
                      Column(
                        children: [
                          Text(
                            'قيمة البيع',
                            style:
                                TextStyle(
                              color:
                                  AppTheme.textMutedFor(context),
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
                                TextStyle(
                              color:
                                  AppTheme.warningFor(context),
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
// ملاحظة: تم نقل _StockEvent إلى ملف
// lib/services/stock_balance_service.dart
// ليستخدمه كل من صفحة رصيد المخزون وصفحة التقارير.
// ============================================================