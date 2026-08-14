// lib/views/dashboard/inventory_history_page.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../services/inventory_service.dart';
import '../../models/inventory_model.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';
import 'inventory_page.dart';

class InventoryHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? branchName;

  const InventoryHistoryPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.branchName,
  });

  @override
  State<InventoryHistoryPage> createState() =>
      _InventoryHistoryPageState();
}

class _InventoryHistoryPageState extends State<InventoryHistoryPage> {
  final InventoryService _inventoryService = InventoryService();

  List<InventoryModel> _inventories = [];
  bool _isLoading = true;
  bool _isInitializing = false;

  String? _filterStoreCode;
  String? _filterDate;

  List<Map<String, String>> _stores = [];

  InventoryModel? _selectedInventory;
  bool _showDetails = false;

  VoidCallback? _inventoryBoxListener;

  @override
  void initState() {
    super.initState();

    _inventoryBoxListener = _onInventoryBoxChanged;
    Hive.box('inventory_box')
        .listenable()
        .addListener(_inventoryBoxListener!);

    _initialize();
  }

  @override
  void dispose() {
    if (_inventoryBoxListener != null) {
      Hive.box('inventory_box')
          .listenable()
          .removeListener(_inventoryBoxListener!);
    }
    super.dispose();
  }

  void _onInventoryBoxChanged() {
    if (mounted) {
      _loadData();
    }
  }

  Future<void> _initialize() async {
    if (_isInitializing) return;
    _isInitializing = true;

    await _loadDropdowns();
    await _loadData();

    if (mounted) {
      setState(() {
        _isLoading = false;
        _isInitializing = false;
      });
    }
  }

  Future<void> _loadDropdowns() async {
    final box = Hive.box('coding_box');

    _stores = [
      {'code': 'all', 'name': 'كل المخازن'}
    ];

    final raw = box.get(
      '${widget.companyCode}_stores',
      defaultValue: [],
    );

    if (raw is List) {
      for (var item in raw) {
        if (item is Map) {
          _stores.add({
            'code': item['code']?.toString() ?? '',
            'name': item['name']?.toString() ?? '',
          });
        }
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadData() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final box = Hive.box('inventory_box');
      List<InventoryModel> all = [];

      // ========================================================
      // قراءة البيانات من Hive فقط
      // ========================================================

      for (var key in box.keys) {
        final raw = box.get(key);

        if (raw is! List) continue;

        for (var item in raw) {
          if (item is! Map) continue;

          // تجاهل المحذوف
          if (item['is_deleted'] == true) continue;

          if (item['company_code']?.toString() !=
              widget.companyCode) {
            continue;
          }

          try {
            all.add(
              InventoryModel.fromMap(
                Map<String, dynamic>.from(item),
              ),
            );
          } catch (e) {
            print('⚠️ فشل تحويل عنصر الجرد: $e');
          }
        }
      }

      // ========================================================
      // الفلاتر
      // ========================================================

      if (widget.selectedBranchCode != null &&
          widget.selectedBranchCode != 'all' &&
          widget.selectedBranchCode!.isNotEmpty) {
        all = all
            .where(
              (inv) =>
                  inv.branchCode ==
                  widget.selectedBranchCode,
            )
            .toList();
      }

      if (_filterStoreCode != null &&
          _filterStoreCode != 'all') {
        all = all
            .where(
              (inv) => inv.storeCode == _filterStoreCode,
            )
            .toList();
      }

      if (_filterDate != null &&
          _filterDate!.isNotEmpty) {
        all = all
            .where(
              (inv) => inv.date == _filterDate,
            )
            .toList();
      }

      all.sort((a, b) {
        final dateCmp = b.date.compareTo(a.date);
        if (dateCmp != 0) return dateCmp;
        return (b.serial ?? 0).compareTo(a.serial ?? 0);
      });

      if (!mounted) return;

      setState(() {
        _inventories = all;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() => _isLoading = false);
      print('❌ خطأ في تحميل الجردات: $e');
    }
  }

  // ============================================================
  // تحديث يدوي - Incremental فقط
  // ============================================================

  Future<void> _refreshFromServer() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      await _inventoryService.syncChangesFromServer(
        widget.companyCode,
      );

      await _loadData();

      if (mounted) {
        _showSnackBar(
          'تم تحديث الجرد بنجاح',
          Colors.green,
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          'فشل التحديث: $e',
          Colors.red,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') {
      return 'كل الفروع';
    }

    final box = Hive.box('coding_box');
    final rawData = box.get(
      "${widget.companyCode}_branches",
      defaultValue: [],
    );

    if (rawData is List) {
      for (var item in rawData) {
        if (item is Map &&
            item['code']?.toString() == code) {
          return item['name']?.toString() ??
              "فرع غير معروف";
        }
      }
    }

    return "فرع غير معروف";
  }

  String _getStoreName(String? code) {
    if (code == null || code == 'all') {
      return 'كل المخازن';
    }

    final found = _stores.firstWhere(
      (s) => s['code'] == code,
      orElse: () => {},
    );

    return found['name'] ?? code;
  }

  String _formatCurrency(double amount) {
    return NumberFormat(
      '#,##0.00',
      'ar_EG',
    ).format(amount);
  }

  void _showInventoryDetails(InventoryModel model) {
    setState(() {
      _selectedInventory = model;
      _showDetails = true;
    });
  }

  void _goBackToList() {
    setState(() {
      _showDetails = false;
      _selectedInventory = null;
    });
  }

  void _editInventory(InventoryModel model) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => InventoryPage(
          companyCode: widget.companyCode,
          editItem: model,
        ),
      ),
    ).then((_) => _loadData());
  }

  void _confirmDelete(InventoryModel model) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.indigo.shade900,
        title: const Text(
          'تأكيد الحذف',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'هل أنت متأكد من حذف جرد ${model.date} - إذن ${model.serial ?? ''}؟',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'إلغاء',
              style: TextStyle(color: Colors.white),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);

              if (model.docId == null) {
                _showSnackBar(
                  'رقم الجرد غير موجود',
                  Colors.red,
                );
                return;
              }

              final deleted =
                  await _inventoryService.deleteInventory(
                widget.companyCode,
                model.docId!,
              );

              if (deleted) {
                _showSnackBar(
                  'تم الحذف بنجاح',
                  Colors.green,
                );
                await _loadData();
              } else {
                _showSnackBar(
                  'فشل الحذف',
                  Colors.red,
                );
              }
            },
            child: const Text(
              'حذف',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportSingleExcel(
    InventoryModel inv,
  ) async {
    try {
      final data = inv.items
          .map(
            (item) => {
              'الكود': item.code,
              'الصنف': item.name,
              'الكمية': item.quantity,
              'سعر الجملة': item.wholesalePrice,
              'قيمة الجملة': item.wholesaleValue,
              'سعر البيع': item.retailPrice,
              'قيمة البيع': item.retailValue,
            },
          )
          .toList();

      await ExportService.exportToExcel(
        data,
        'جرد_${inv.date}_${inv.serial ?? ''}',
        [
          'الكود',
          'الصنف',
          'الكمية',
          'سعر الجملة',
          'قيمة الجملة',
          'سعر البيع',
          'قيمة البيع',
        ],
        [
          'الكود',
          'الصنف',
          'الكمية',
          'سعر الجملة',
          'قيمة الجملة',
          'سعر البيع',
          'قيمة البيع',
        ],
      );

      _showSnackBar(
        'تم تصدير الإذن بنجاح',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'فشل التصدير: $e',
        Colors.red,
      );
    }
  }

  Future<void> _exportSinglePDF(
    InventoryModel inv,
  ) async {
    try {
      final data = inv.items
          .map(
            (item) => {
              'الكود': item.code,
              'الصنف': item.name,
              'الكمية': item.quantity,
              'سعر الجملة': item.wholesalePrice,
              'قيمة الجملة': item.wholesaleValue,
              'سعر البيع': item.retailPrice,
              'قيمة البيع': item.retailValue,
            },
          )
          .toList();

      final summary = {
        'totalQuantity': inv.items.fold(
          0.0,
          (sum, item) => sum + item.quantity,
        ),
        'totalWholesale': inv.totalWholesale,
        'totalRetail': inv.totalRetail,
      };

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير جرد المخزون',
        headers: [
          'الكود',
          'الصنف',
          'الكمية',
          'سعر الجملة',
          'قيمة الجملة',
          'سعر البيع',
          'قيمة البيع',
        ],
        keys: [
          'الكود',
          'الصنف',
          'الكمية',
          'سعر الجملة',
          'قيمة الجملة',
          'سعر البيع',
          'قيمة البيع',
        ],
        summary: summary,
        serial: inv.serial?.toString(),
        date: inv.date,
        branchName: _getBranchName(inv.branchCode),
        storeName: _getStoreName(inv.storeCode),
      );

      _showSnackBar(
        'تم تصدير الإذن بنجاح',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'فشل تصدير PDF: $e',
        Colors.red,
      );
    }
  }

  Future<void> _exportAllExcel() async {
    if (_inventories.isEmpty) {
      _showSnackBar(
        'لا توجد بيانات للتصدير',
        Colors.orange,
      );
      return;
    }

    try {
      final data = _inventories
          .map(
            (inv) => {
              'رقم الإذن': inv.serial ?? '',
              'التاريخ': inv.date,
              'الفرع': _getBranchName(inv.branchCode),
              'المخزن': _getStoreName(inv.storeCode),
              'النوع': inv.inventoryType == 'general'
                  ? 'جرد عام'
                  : 'جرد محدد',
              'إجمالي الجملة': inv.totalWholesale,
              'إجمالي البيع': inv.totalRetail,
              'عدد الأصناف': inv.items.length,
              'إجمالي الكميات': inv.items.fold(
                0.0,
                (sum, item) => sum + item.quantity,
              ),
            },
          )
          .toList();

      await ExportService.exportToExcel(
        data,
        'الجردات_${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
        [
          'رقم الإذن',
          'التاريخ',
          'الفرع',
          'المخزن',
          'النوع',
          'إجمالي الجملة',
          'إجمالي البيع',
          'عدد الأصناف',
          'إجمالي الكميات',
        ],
        [
          'رقم الإذن',
          'التاريخ',
          'الفرع',
          'المخزن',
          'النوع',
          'إجمالي الجملة',
          'إجمالي البيع',
          'عدد الأصناف',
          'إجمالي الكميات',
        ],
      );

      _showSnackBar(
        'تم تصدير جميع الجردات بنجاح',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'فشل التصدير: $e',
        Colors.red,
      );
    }
  }

  Future<void> _exportAllPDF() async {
    if (_inventories.isEmpty) {
      _showSnackBar(
        'لا توجد بيانات للتصدير',
        Colors.orange,
      );
      return;
    }

    try {
      final data = _inventories
          .map(
            (inv) => {
              'رقم الإذن': inv.serial ?? '',
              'التاريخ': inv.date,
              'الفرع': _getBranchName(inv.branchCode),
              'المخزن': _getStoreName(inv.storeCode),
              'النوع': inv.inventoryType == 'general'
                  ? 'جرد عام'
                  : 'جرد محدد',
              'إجمالي الجملة': inv.totalWholesale,
              'إجمالي البيع': inv.totalRetail,
              'عدد الأصناف': inv.items.length,
              'إجمالي الكميات': inv.items.fold(
                0.0,
                (sum, item) => sum + item.quantity,
              ),
            },
          )
          .toList();

      await ExportService.exportToPDF(
        data: data,
        title: 'تقرير الجردات المجمعة',
        headers: [
          'رقم الإذن',
          'التاريخ',
          'الفرع',
          'المخزن',
          'النوع',
          'إجمالي الجملة',
          'إجمالي البيع',
          'عدد الأصناف',
          'إجمالي الكميات',
        ],
        keys: [
          'رقم الإذن',
          'التاريخ',
          'الفرع',
          'المخزن',
          'النوع',
          'إجمالي الجملة',
          'إجمالي البيع',
          'عدد الأصناف',
          'إجمالي الكميات',
        ],
      );

      _showSnackBar(
        'تم تصدير جميع الجردات بنجاح',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'فشل تصدير PDF: $e',
        Colors.red,
      );
    }
  }

  void _showSnackBar(
    String msg,
    Color color,
  ) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Cairo',
          ),
        ),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showDetails
              ? 'تفاصيل الجرد'
              : 'معاينة الجرد',
          style: const TextStyle(
            color: Colors.white,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: Colors.white,
          ),
          onPressed: _showDetails
              ? _goBackToList
              : () => Navigator.pop(context),
        ),
        actions: [
          if (!_showDetails &&
              PermissionsService().canExportInventory)
            IconButton(
              icon: const Icon(
                Icons.download,
                color: Colors.blueAccent,
              ),
              onPressed: _exportAllExcel,
              tooltip: 'تصدير جميع الجردات Excel',
            ),
          if (!_showDetails &&
              PermissionsService().canExportInventory)
            IconButton(
              icon: const Icon(
                Icons.picture_as_pdf,
                color: Colors.redAccent,
              ),
              onPressed: _exportAllPDF,
              tooltip: 'تصدير جميع الجردات PDF',
            ),
          if (!_showDetails)
            IconButton(
              icon: const Icon(
                Icons.refresh,
                color: Colors.white,
              ),
              onPressed: _refreshFromServer,
              tooltip: 'تحديث التغييرات من السيرفر',
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.black,
              Color(0xFF1A237E),
              Colors.black,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: Colors.white,
                  ),
                )
              : _showDetails && _selectedInventory != null
                  ? _buildDetailsView(
                      _selectedInventory!,
                    )
                  : _buildListView(),
        ),
      ),
    );
  }

  Widget _buildListView() {
    final bool isMobile =
        MediaQuery.of(context).size.width < 600;

    final String displayBranchName =
        widget.branchName ??
            _getBranchName(
              widget.selectedBranchCode,
            );

    return Column(
      children: [
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                const Icon(
                  Icons.storefront,
                  color: Colors.cyanAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'الفرع الحالي: $displayBranchName',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Cairo',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    value: _filterStoreCode,
                    dropdownColor: Colors.indigo.shade900,
                    style: const TextStyle(
                      color: Colors.white,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'المخزن',
                      isDense: true,
                    ),
                    items: _stores.map((s) {
                      return DropdownMenuItem<String?>(
                        value: s['code'],
                        child: Text(
                          s['name'] ?? '',
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _filterStoreCode = val;
                      });
                      _loadData();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: _filterDate,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'التاريخ',
                      suffixIcon: Icon(
                        Icons.calendar_today,
                      ),
                      isDense: true,
                    ),
                    onTap: () async {
                      final picked =
                          await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2101),
                      );

                      if (picked != null) {
                        setState(() {
                          _filterDate =
                              DateFormat(
                            'yyyy-MM-dd',
                          ).format(picked);
                        });
                        _loadData();
                      }
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.clear,
                    color: Colors.white70,
                  ),
                  onPressed: () {
                    setState(() {
                      _filterStoreCode = null;
                      _filterDate = null;
                    });
                    _loadData();
                  },
                  tooltip: 'إلغاء الفلاتر',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _inventories.isEmpty
              ? const Center(
                  child: Text(
                    'لا توجد جردات',
                    style: TextStyle(
                      color: Colors.white70,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _inventories.length,
                  itemBuilder: (c, i) {
                    final inv =
                        _inventories[i];

                    return Card(
                      color:
                          Colors.white.withOpacity(0.05),
                      margin:
                          const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      shape:
                          RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(10),
                        onTap: () =>
                            _showInventoryDetails(inv),
                        child: Padding(
                          padding:
                              EdgeInsets.all(
                            isMobile ? 8 : 12,
                          ),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    radius:
                                        isMobile ? 16 : 20,
                                    backgroundColor:
                                        Colors.cyanAccent
                                            .withOpacity(
                                      0.2,
                                    ),
                                    child: Text(
                                      '${inv.serial ?? ''}',
                                      style: TextStyle(
                                        color:
                                            Colors.cyanAccent,
                                        fontWeight:
                                            FontWeight.bold,
                                        fontSize:
                                            isMobile ? 10 : 12,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(
                                    width: 10,
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${_getBranchName(inv.branchCode)} - ${_getStoreName(inv.storeCode)}',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize:
                                                isMobile ? 12 : 14,
                                            fontWeight:
                                                FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          'التاريخ: ${inv.date}',
                                          style: TextStyle(
                                            color:
                                                Colors.white60,
                                            fontSize:
                                                isMobile ? 10 : 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding:
                                        const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration:
                                        BoxDecoration(
                                      color: inv.inventoryType ==
                                              'general'
                                          ? Colors.greenAccent
                                              .withOpacity(
                                              0.15,
                                            )
                                          : Colors.orangeAccent
                                              .withOpacity(
                                              0.15,
                                            ),
                                      borderRadius:
                                          BorderRadius.circular(
                                        10,
                                      ),
                                    ),
                                    child: Text(
                                      inv.inventoryType ==
                                              'general'
                                          ? 'جرد عام'
                                          : 'جرد محدد',
                                      style: TextStyle(
                                        color:
                                            inv.inventoryType ==
                                                    'general'
                                                ? Colors.greenAccent
                                                : Colors.orangeAccent,
                                        fontSize:
                                            isMobile ? 8 : 10,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing:
                                    isMobile ? 4 : 8,
                                runSpacing: 4,
                                children: [
                                  _buildInfoChip(
                                    'الأصناف',
                                    inv.items.length
                                        .toString(),
                                    Colors.blueAccent,
                                    isMobile,
                                  ),
                                  _buildInfoChip(
                                    'إجمالي الجملة',
                                    _formatCurrency(
                                      inv.totalWholesale,
                                    ),
                                    Colors.greenAccent,
                                    isMobile,
                                  ),
                                  _buildInfoChip(
                                    'إجمالي البيع',
                                    _formatCurrency(
                                      inv.totalRetail,
                                    ),
                                    Colors.amber,
                                    isMobile,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.end,
                                children: [
                                  if (PermissionsService()
                                      .canEditInventory)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.edit,
                                        color: Colors.orange,
                                        size: 18,
                                      ),
                                      onPressed: () =>
                                          _editInventory(inv),
                                      padding:
                                          EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints(),
                                    ),
                                  if (PermissionsService()
                                      .canDeleteInventory)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete,
                                        color: Colors.red,
                                        size: 18,
                                      ),
                                      onPressed: () =>
                                          _confirmDelete(inv),
                                      padding:
                                          EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints(),
                                    ),
                                  IconButton(
                                    icon: Icon(
                                      Icons.arrow_forward_ios,
                                      color:
                                          Colors.cyanAccent,
                                      size:
                                          isMobile ? 16 : 18,
                                    ),
                                    onPressed: () =>
                                        _showInventoryDetails(
                                      inv,
                                    ),
                                    padding:
                                        EdgeInsets.zero,
                                    constraints:
                                        const BoxConstraints(),
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

  Widget _buildInfoChip(
    String label,
    String value,
    Color color,
    bool isMobile,
  ) {
    return Container(
      padding:
          EdgeInsets.symmetric(
        horizontal: isMobile ? 6 : 8,
        vertical: isMobile ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius:
            BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize:
            MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white60,
              fontSize:
                  isMobile ? 9 : 11,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize:
                  isMobile ? 10 : 12,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsView(
    InventoryModel inv,
  ) {
    final bool isMobile =
        MediaQuery.of(context).size.width < 600;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              'إذن جرد رقم ${inv.serial ?? ''}',
                              style:
                                  TextStyle(
                                color:
                                    Colors.white,
                                fontSize:
                                    isMobile
                                        ? 16
                                        : 18,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                            const SizedBox(
                              height: 2,
                            ),
                            Text(
                              'التاريخ: ${inv.date}',
                              style:
                                  TextStyle(
                                color:
                                    Colors.white60,
                                fontSize:
                                    isMobile
                                        ? 12
                                        : 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        inv.inventoryType ==
                                'general'
                            ? 'جرد عام'
                            : 'جرد محدد',
                        style: TextStyle(
                          color: inv.inventoryType ==
                                  'general'
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                          fontWeight:
                              FontWeight.bold,
                          fontSize:
                              isMobile ? 10 : 12,
                        ),
                      ),
                    ],
                  ),
                  const Divider(
                    color: Colors.white24,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDetailItem(
                          'الفرع',
                          _getBranchName(
                            inv.branchCode,
                          ),
                          Icons.storefront,
                          isMobile,
                        ),
                      ),
                      Expanded(
                        child: _buildDetailItem(
                          'المخزن',
                          _getStoreName(
                            inv.storeCode,
                          ),
                          Icons.store,
                          isMobile,
                        ),
                      ),
                      Expanded(
                        child: _buildDetailItem(
                          'عدد الأصناف',
                          inv.items.length
                              .toString(),
                          Icons.list_alt,
                          isMobile,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.end,
                    children: [
                      if (PermissionsService()
                          .canExportInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _exportSingleExcel(
                            inv,
                          ),
                          icon: const Icon(
                            Icons.download,
                            color:
                                Colors.blueAccent,
                          ),
                          label:
                              const Text(
                            'تصدير Excel',
                            style:
                                TextStyle(
                              color:
                                  Colors.blueAccent,
                            ),
                          ),
                        ),
                      if (PermissionsService()
                          .canExportInventory)
                        TextButton.icon(
                          onPressed: () =>
                              _exportSinglePDF(
                            inv,
                          ),
                          icon:
                              const Icon(
                            Icons.picture_as_pdf,
                            color:
                                Colors.redAccent,
                          ),
                          label:
                              const Text(
                            'تصدير PDF',
                            style:
                                TextStyle(
                              color:
                                  Colors.redAccent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding:
                  const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'تفاصيل الأصناف',
                    style: TextStyle(
                      color:
                          Colors.cyanAccent,
                      fontSize: 16,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (isMobile)
                    SingleChildScrollView(
                      scrollDirection:
                          Axis.horizontal,
                      child: Column(
                        children: [
                          Row(
                            children: const [
                              SizedBox(
                                width: 30,
                                child: Text(
                                  '#',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.cyan,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 60,
                                child: Text(
                                  'الكود',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.cyan,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                child: Text(
                                  'الصنف',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.cyan,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 50,
                                child: Text(
                                  'الكمية',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.cyan,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 65,
                                child: Text(
                                  'جملة',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.greenAccent,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 65,
                                child: Text(
                                  'قيمة',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.greenAccent,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 65,
                                child: Text(
                                  'بيع',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.amber,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 65,
                                child: Text(
                                  'قيمة',
                                  textAlign:
                                      TextAlign.center,
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.amber,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ...inv.items
                              .asMap()
                              .entries
                              .map(
                                (entry) {
                              final item =
                                  entry.value;

                              return Row(
                                children: [
                                  SizedBox(
                                    width: 30,
                                    child:
                                        Text(
                                      '${entry.key + 1}',
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white54,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 60,
                                    child:
                                        Text(
                                      item.code,
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white70,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 80,
                                    child:
                                        Text(
                                      item.name,
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 50,
                                    child:
                                        Text(
                                      item.quantity
                                          .toStringAsFixed(
                                        0,
                                      ),
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white70,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 65,
                                    child:
                                        Text(
                                      _formatCurrency(
                                        item.wholesalePrice,
                                      ),
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.greenAccent,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 65,
                                    child:
                                        Text(
                                      _formatCurrency(
                                        item.wholesaleValue,
                                      ),
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.greenAccent,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 65,
                                    child:
                                        Text(
                                      _formatCurrency(
                                        item.retailPrice,
                                      ),
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.amber,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 65,
                                    child:
                                        Text(
                                      _formatCurrency(
                                        item.retailValue,
                                      ),
                                      textAlign:
                                          TextAlign.center,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.amber,
                                        fontSize:
                                            9,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    )
                  else
                    Column(
                      children: [
                        const Row(
                          children: [
                            Expanded(
                              child: Text(
                                '#',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.cyan,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'الكود',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.cyan,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                'الصنف',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.cyan,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'الكمية',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.cyan,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'سعر الجملة',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.greenAccent,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'قيمة الجملة',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.greenAccent,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'سعر البيع',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.amber,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'قيمة البيع',
                                textAlign:
                                    TextAlign.center,
                                style:
                                    TextStyle(
                                  color:
                                      Colors.amber,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(
                          height: 4,
                        ),
                        ListView.separated(
                          shrinkWrap:
                              true,
                          physics:
                              const NeverScrollableScrollPhysics(),
                          itemCount:
                              inv.items.length,
                          separatorBuilder:
                              (_, __) =>
                                  const Divider(
                            color:
                                Colors.white10,
                          ),
                          itemBuilder:
                              (ctx, idx) {
                            final item =
                                inv.items[idx];

                            return Row(
                              children: [
                                Expanded(
                                  child:
                                      Text(
                                    '${idx + 1}',
                                    textAlign:
                                        TextAlign.center,
                                    style:
                                        const TextStyle(
                                      color:
                                          Colors.white54,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child:
                                      Text(
                                    item.code,
                                    textAlign:
                                        TextAlign.center,
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child:
                                      Text(
                                    item.name,
                                    textAlign:
                                        TextAlign.center,
                                    style:
                                        const TextStyle(
                                      color:
                                          Colors.white,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child:
                                      Text(
                                    item.quantity
                                        .toStringAsFixed(
                                      0,
                                    ),
                                    textAlign:
                                        TextAlign.center,
                                  ),
                                ),
                                Expanded(
                                  child:
                                      Text(
                                    _formatCurrency(
                                      item.wholesalePrice,
                                    ),
                                    textAlign:
                                        TextAlign.center,
                                  ),
                                ),
                                Expanded(
                                  child:
                                      Text(
                                    _formatCurrency(
                                      item.wholesaleValue,
                                    ),
                                    textAlign:
                                        TextAlign.center,
                                  ),
                                ),
                                Expanded(
                                  child:
                                      Text(
                                    _formatCurrency(
                                      item.retailPrice,
                                    ),
                                    textAlign:
                                        TextAlign.center,
                                  ),
                                ),
                                Expanded(
                                  child:
                                      Text(
                                    _formatCurrency(
                                      item.retailValue,
                                    ),
                                    textAlign:
                                        TextAlign.center,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding:
                  const EdgeInsets.all(10),
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text(
                        'إجمالي الجملة',
                        style: TextStyle(
                          color:
                              Colors.white60,
                        ),
                      ),
                      Text(
                        _formatCurrency(
                          inv.totalWholesale,
                        ),
                        style: const TextStyle(
                          color:
                              Colors.greenAccent,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    width: 1,
                    height: 30,
                    color: Colors.white24,
                  ),
                  Column(
                    children: [
                      const Text(
                        'إجمالي البيع',
                        style: TextStyle(
                          color:
                              Colors.white60,
                        ),
                      ),
                      Text(
                        _formatCurrency(
                          inv.totalRetail,
                        ),
                        style: const TextStyle(
                          color: Colors.amber,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    width: 1,
                    height: 30,
                    color: Colors.white24,
                  ),
                  Column(
                    children: [
                      const Text(
                        'إجمالي الكميات',
                        style: TextStyle(
                          color:
                              Colors.white60,
                        ),
                      ),
                      Text(
                        inv.items
                            .fold(
                              0.0,
                              (sum, item) =>
                                  sum + item.quantity,
                            )
                            .toStringAsFixed(0),
                        style:
                            const TextStyle(
                          color:
                              Colors.cyanAccent,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailItem(
    String label,
    String value,
    IconData icon,
    bool isMobile,
  ) {
    return Row(
      children: [
        Icon(
          icon,
          color: Colors.cyanAccent,
          size: isMobile ? 14 : 16,
        ),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white60,
                fontSize:
                    isMobile ? 8 : 10,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize:
                    isMobile ? 11 : 13,
              ),
            ),
          ],
        ),
      ],
    );
  }
}