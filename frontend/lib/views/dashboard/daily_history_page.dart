// lib/views/dashboard/daily_history_page.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
// import 'package:shared_preferences/shared_preferences.dart'; // ✅ إضافة الاستيراد
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import 'daily_page.dart';
import 'package:universal_html/html.dart' as html;
import 'package:excel/excel.dart' as excel_lib;
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/permissions_service.dart'; // ✅ استيراد خدمة الصلاحيات
import '../../services/export_service.dart';
// import '../../core/constants.dart'; // ✅ استيراد الثوابت لـ LAST_SYNC_DAILY

class DailyHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? userName;
  final String? selectedBranchCode; // 🌟 التعديل هنا: استقبال الكود بدلاً من الاسم

  const DailyHistoryPage({
    super.key,
    required this.companyCode,
    this.userName,
    this.selectedBranchCode,
  });

  @override
  State<DailyHistoryPage> createState() => _DailyHistoryPageState();
}

class _DailyHistoryPageState extends State<DailyHistoryPage> {
  final DailyService _dailyService = DailyService();
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 7));
  DateTime _toDate = DateTime.now();

  // 🌟 هذا هو السطر السحري الناقص الذي كان يسبب الإيرور في الملف كله:
  // ignore: unused_field
  List<Map<String, dynamic>> _historyData = [];

  bool _isLoading = false;
  bool _isInitializing = false;

  // ✅ متغيرات الفلتر الجديدة
  Set<String> _selectedCategories = {}; // التصنيفات المختارة للفلتر
  // bool _isFilterApplied = false;

  // ✅ مستمع للتغييرات في صندوق اليوميات
  VoidCallback? _boxListener;
  bool _isUpdating = false; // ✅ متغير علم لمنع التحديث المتكرر



  @override
  void initState() {
    super.initState();
    // ✅ إضافة مستمع لتغييرات الصندوق لإعادة تحميل البيانات تلقائياً
    // عند تغيير Hive (بسبب WebSocket أو المزامنة الخلفية)، يتم تحديث الصفحة فوراً
    _boxListener = () {
      if (!_isUpdating && mounted) {
        _fetchData();
      }
    };
    Hive.box('daily_transactions_box').listenable().addListener(_boxListener!);
    _initialize();
  }

  @override
  void dispose() {
    if (_boxListener != null) {
      Hive.box('daily_transactions_box').listenable().removeListener(_boxListener!);
    }
    super.dispose();
  }

  Future<void> _initialize() async {
    if (_isInitializing) return;
    _isInitializing = true;

    // ✅ قراءة البيانات من Hive مباشرة (بدون مزامنة)
    // المزامنة تتم مركزياً في main.dart (عند بدء التشغيل، تسجيل الدخول، أو إعادة اتصال WebSocket)
    // هذا يضمن:
    // 1. سرعة عرض الصفحة (لا انتظار لتحميل البيانات)
    // 2. عدم تكرار استدعاءات المزامنة من عدة صفحات
    // 3. تحديث تلقائي عند تغيير Hive عبر المستمع (_boxListener)
    
    final Box dailyBox = Hive.box('daily_transactions_box');
    bool hasLocalData = dailyBox.values.any((tx) => tx is Map && tx['company_code'] == widget.companyCode);

    // ✅ إذا لم تكن هناك بيانات محلية، نعرض رسالة "لا توجد بيانات" بدلاً من تحميلها
    // (سيتم تحميل البيانات من main.dart في الخلفية)
    if (!hasLocalData) {
      print("ℹ️ لا توجد بيانات محلية في الهيستوري، سيتم تحميلها من main.dart");
    }

    // ✅ جلب التحديثات التزايدية من السيرفر باستخدام وقت آخر مزامنة
    // ملاحظة: هذا الكود تم تعليقه لأنه يتم تنفيذه في main.dart
    // لكننا نتركه للتوافق مع الكود القديم وللتذكير بالآلية
    /*
    final prefs = await SharedPreferences.getInstance();
    final lastSyncKey = '${ApiConstants.LAST_SYNC_DAILY}${widget.companyCode}';
    final lastSyncTime = prefs.getString(lastSyncKey);
    
    if (lastSyncTime != null) {
      print("📡 جاري جلب التحديثات من السيرفر منذ آخر مزامنة: $lastSyncTime");
      await _dailyService.syncChangesFromServer(widget.companyCode, lastSyncTime);
      await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
    } else {
      print("📥 لا يوجد وقت مزامنة سابق، جاري جلب كل البيانات من السيرفر");
      await _dailyService.syncAllTransactions(widget.companyCode);
      await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
    }
    */

    // ✅ التحقق قبل _fetchData
    if (!mounted) {
      _isInitializing = false;
      return;
    }
    
    // ✅ عرض البيانات المخزنة محلياً فوراً (بدون انتظار)
    _fetchData();
    _isInitializing = false;
  }

  void _fetchData() async {
    // ✅ منع التنفيذ إذا كان الـ Widget غير موجود أو قيد التحديث
    if (!mounted || _isUpdating) return;
    
    _isUpdating = true;
    setState(() => _isLoading = true);
    try {
      final data = await _dailyService.getTransactionsHistory(
        widget.companyCode,
        DateFormat('yyyy-MM-dd').format(_fromDate),
        DateFormat('yyyy-MM-dd').format(_toDate),
        branchCode: widget.selectedBranchCode,
      );

      // ✅ التحقق قبل تحديث الحالة
      if (!mounted) {
        _isUpdating = false;
        return;
      }
      setState(() {
        _historyData = data.map<Map<String, dynamic>>((item) => Map<String, dynamic>.from(item)).toList();
        _isLoading = false;
        _isUpdating = false;
      });
    } catch (e) {
      // ✅ التحقق قبل تحديث الحالة في حالة الخطأ
      if (!mounted) {
        _isUpdating = false;
        return;
      }
      setState(() {
        _isLoading = false;
        _isUpdating = false;
      });
      print("خطأ في جلب التاريخ: $e");
    }
  }

  // 🌟 دالة مساعدة لجلب اسم الفرع من الكود الخاص به لعرضه للمستخدم
  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    final Box codingBox = Hive.box('coding_box');
    final rawData = codingBox.get("${widget.companyCode}_branches", defaultValue: []);
    for(var item in rawData) {
      if(item['code']?.toString() == code.toString()) return item['name']?.toString() ?? "فرع غير معروف";
    }
    return "فرع غير معروف";
  }

  // دالة لفلترة وترتيب البيانات
  List<Map<String, dynamic>> _applyFiltersAndSort(List<Map<String, dynamic>> list) {
    List<Map<String, dynamic>> filteredList = List.from(list);

    // 1️⃣ تطبيق فلتر التصنيفات
    if (_selectedCategories.isNotEmpty) {
      filteredList = filteredList.where((item) {
        String category = item['category']?.toString() ?? '';
        return _selectedCategories.contains(category);
      }).toList();
    }

    // 2️⃣ الترتيب الشرطي حسب وجود فلتر أم لا
    if (_selectedCategories.isNotEmpty) {
      // ✅ حالة وجود فلتر: الترتيب أبجدي حسب التصنيف، ثم التاريخ
      filteredList.sort((a, b) {
        // أولاً: الترتيب الأبجدي حسب اسم التصنيف (تصاعدي)
        String catA = a['category']?.toString() ?? '';
        String catB = b['category']?.toString() ?? '';
        int catCmp = catA.compareTo(catB);
        if (catCmp != 0) return catCmp;

        // ثانياً: الترتيب حسب التاريخ (من الأقدم للأحدث)
        String dateA = a['date'] ?? '';
        String dateB = b['date'] ?? '';
        return dateA.compareTo(dateB);
      });
    } else {
      // ✅ حالة عدم وجود فلتر: ترتيب حسب التاريخ ثم رقم الإذن
      filteredList.sort((a, b) {
        String dateA = a['date'] ?? '';
        String dateB = b['date'] ?? '';
        int dateCmp = dateA.compareTo(dateB);
        if (dateCmp != 0) return dateCmp;
        return (a['serial'] ?? 0).compareTo(b['serial'] ?? 0);
      });
    }

    return filteredList;
  }

  // حساب إجمالي المبلغ للبيانات المعروضة
  double _calculateTotal(List<Map<String, dynamic>> list) {
    double total = 0.0;
    for (var item in list) {
      total += double.tryParse(item['amount']?.toString() ?? '0') ?? 0.0;
    }
    return total;
  }

  // عرض مربع حوار لاختيار التصنيفات
  void _showFilterDialog(List<Map<String, dynamic>> currentData) {
    // استخراج جميع التصنيفات الفريدة
    Set<String> allCategories = {};
    for (var item in currentData) {
      String cat = item['category']?.toString() ?? '';
      if (cat.isNotEmpty) allCategories.add(cat);
    }

    if (allCategories.isEmpty) {
      _showSnackBar("لا توجد تصنيفات لعرضها في النطاق الزمني الحالي", Colors.orange);
      return;
    }

    // نسخة مؤقتة للاختيارات داخل الحوار
    Set<String> tempSelected = Set.from(_selectedCategories);

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text(
                'فلترة حسب التصنيف',
                style: TextStyle(fontFamily: 'Cairo'),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // أزرار تحديد الكل / إلغاء الكل
                    Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            setStateDialog(() {
                              tempSelected = Set.from(allCategories);
                            });
                          },
                          child: const Text('تحديد الكل', style: TextStyle(fontFamily: 'Cairo')),
                        ),
                        const SizedBox(width: 10),
                        TextButton(
                          onPressed: () {
                            setStateDialog(() {
                              tempSelected.clear();
                            });
                          },
                          child: const Text('إلغاء الكل', style: TextStyle(fontFamily: 'Cairo')),
                        ),
                      ],
                    ),
                    const Divider(),
                    // قائمة التصنيفات مع Checkboxes
                    Expanded(
                      child: ListView(
                        shrinkWrap: true,
                        children: allCategories.toList().map((category) {
                          return CheckboxListTile(
                            title: Text(category, style: const TextStyle(fontFamily: 'Cairo')),
                            value: tempSelected.contains(category),
                            onChanged: (bool? checked) {
                              setStateDialog(() {
                                if (checked == true) {
                                  tempSelected.add(category);
                                } else {
                                  tempSelected.remove(category);
                                }
                              });
                            },
                            activeColor: Colors.cyanAccent,
                            checkColor: Colors.black,
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _selectedCategories = Set.from(tempSelected);
                    });
                    Navigator.pop(context);
                  },
                  child: const Text('تطبيق', style: TextStyle(fontFamily: 'Cairo')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _exportToPDF(List<Map<String, dynamic>> currentData) async {
    if (!PermissionsService().canExport) {
      _showSnackBar("ليس لديك صلاحية للتصدير", Colors.orange);
      return;
    }

    if (currentData.isEmpty) {
      _showSnackBar("لا توجد بيانات لتصديرها", Colors.orange);
      return;
    }

    try {
      // حساب الإجمالي
      double total = _calculateTotal(currentData);

      // تجهيز العناوين والمفاتيح (نفس المستخدمة في Excel)
      List<String> headers = ["رقم الإذن", "المبلغ", "البيان", "التصنيف", "التاريخ", "الفرع", "الموظف", "الخزينة"];
      List<String> keys = ["serial", "amount", "statement", "category", "date", "branch_name", "employee", "treasury"];

      // تحويل البيانات لتحل محل branch_code باسم الفرع
      List<Map<String, dynamic>> exportData = currentData.map((row) {
        return {
          ...row,
          "branch_name": _getBranchName(row['branch_code']?.toString()),
          "treasury": _getTreasuryName(row['treasury']),
        };
      }).toList();

      await ExportService.exportToPDF(
        data: exportData,
        title: "سجل الحركات",
        headers: headers,
        keys: keys,
        totalAmount: total,
        branchName: _getBranchName(widget.selectedBranchCode),
        date: "من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}",
        summary: null, // لا نحتاج summary هنا لأننا نمرر totalAmount
      );

      _showSnackBar("تم تصدير PDF بنجاح", Colors.green);
    } catch (e) {
      _showSnackBar("فشل التصدير: $e", Colors.red);
    }
  }

  Future<void> _exportToExcel(List<Map<String, dynamic>> currentData) async {
    // ✅ التحقق من صلاحية التصدير
    if (!PermissionsService().canExport) {
      _showSnackBar("ليس لديك صلاحية لتصدير البيانات", Colors.orange);
      return;
    }

    if (currentData.isEmpty) {
      _showSnackBar("لا توجد بيانات لتصديرها", Colors.orange);
      return;
    }

    try {
      String formattedDate =
          "${DateTime.now().day}-${DateTime.now().month}-${DateTime.now().year}";
      String fileName = "تقرير_اليومية_$formattedDate.xlsx";
      var excel = excel_lib.Excel.createExcel();

      String defaultSheet = excel.tables.keys.first;
      excel.rename(defaultSheet, 'Daily_Records');
      excel_lib.Sheet sheetObject = excel['Daily_Records'];

      for (var table in excel.tables.keys.toList()) {
        if (table != 'Daily_Records') {
          excel.delete(table);
        }
      }

      // 🌟 إضافة كل الأعمدة الجديدة لملف الإكسيل
      sheetObject.appendRow([
        excel_lib.TextCellValue("رقم الإذن"),
        excel_lib.TextCellValue("المبلغ"),
        excel_lib.TextCellValue("البيان"),
        excel_lib.TextCellValue("التصنيف"),
        excel_lib.TextCellValue("التاريخ"),
        excel_lib.TextCellValue("الفرع"),  // 👈 إضافة جديدة
        excel_lib.TextCellValue("الموظف"), // 👈 إضافة جديدة
        excel_lib.TextCellValue("الخزينة"), // ✅ إضافة عمود الخزينة
      ]);

      for (var row in currentData) {
        sheetObject.appendRow([
          excel_lib.TextCellValue(row['serial']?.toString() ?? ""),
          excel_lib.TextCellValue(row['amount']?.toString() ?? "0"),
          excel_lib.TextCellValue(row['statement'] ?? ""),
          excel_lib.TextCellValue(row['category'] ?? ""),
          excel_lib.TextCellValue(row['date'] ?? ""),
          excel_lib.TextCellValue(_getBranchName(row['branch_code']?.toString())), // 🌟 التعديل هنا
          excel_lib.TextCellValue(row['employee'] ?? "غير معروف"), // 👈 إضافة جديدة
          excel_lib.TextCellValue(_getTreasuryName(row['treasury'])), // ✅ إضافة الخزينة
        ]);
      }

      var fileBytes = excel.encode();
      if (fileBytes == null) return;

      if (identical(0, 0.0)) {
        final blob = html.Blob([
          fileBytes
        ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
        final url = html.Url.createObjectUrlFromBlob(blob);
        final anchor = html.AnchorElement(href: url)
          ..setAttribute("download", fileName)
          ..style.display = "none";
        html.document.body?.append(anchor);
        anchor.click();
        anchor.remove();
        html.Url.revokeObjectUrl(url);
        _showSnackBar("تم تحميل $fileName بنجاح", Colors.green);
      } else {
        String? selectedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'اختر مكان حفظ ملف الإكسيل',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['xlsx'],
        );

        if (selectedPath != null) {
          if (!selectedPath.endsWith('.xlsx')) selectedPath += '.xlsx';
          final file = File(selectedPath);
          await file.writeAsBytes(fileBytes);
          _showSnackBar("تم حفظ الملف في: $selectedPath", Colors.green);
        }
      }
    } catch (e) {
      _showSnackBar("فشل التصدير: $e", Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ✅ التحقق من صلاحية المعاينة
    if (!PermissionsService().canViewTransactions) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: const Text("سجل الحركات", style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.black, Colors.indigo.shade900, Colors.black],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Text(
              "ليس لديك صلاحية لعرض سجل الحركات",
              style: TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 16),
            ),
          ),
        ),
      );
    }

    double screenWidth = MediaQuery.of(context).size.width;
    bool isWebOrDesktop = screenWidth > 600;
    final Box dailyBox = Hive.box('daily_transactions_box');

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (context.mounted) {
          Navigator.pop(context);
        }
      },
      child: ValueListenableBuilder(
        valueListenable: dailyBox.listenable(),
        builder: (context, Box box, child) {
          // 1. استخراج الحركات حسب التاريخ والفرع
          List<Map<String, dynamic>> displayList = [];
          String startStr = DateFormat('yyyy-MM-dd').format(_fromDate);
          String endStr = DateFormat('yyyy-MM-dd').format(_toDate);

          for (var item in box.values) {
  if (item is! Map) continue;

  // السجل المحذوف لا يظهر في الواجهة
  if (item['is_deleted'] == true) continue;

  if (item['company_code'] != widget.companyCode) {
    continue;
  }

  if (widget.selectedBranchCode != null &&
      widget.selectedBranchCode != "all" &&
      widget.selectedBranchCode != "") {
    if (item['branch_code']?.toString() !=
        widget.selectedBranchCode) {
      continue;
    }
  }

  final String txDate =
      item['date']?.toString() ?? "";

  if (txDate.compareTo(startStr) >= 0 &&
      txDate.compareTo(endStr) <= 0) {
    displayList.add(
      Map<String, dynamic>.from(item),
    );
  }
}

          // 2. تطبيق الفلتر والترتيب (أبجدي حسب التصنيف)
          displayList = _applyFiltersAndSort(displayList);

          return Scaffold(
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              title: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "سجل الحركات",
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.cyanAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _getBranchName(widget.selectedBranchCode),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.cyanAccent),
                    ),
                  ),
                ],
              ),
              centerTitle: true,
              backgroundColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: 70,
              actions: [
                // 2️⃣ زر الفلتر المتقدم (اختيار تصنيفات متعددة)
                if (PermissionsService().canFilter)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Tooltip(
                      message: _selectedCategories.isNotEmpty
                          ? "تصفية حسب ${_selectedCategories.length} تصنيف"
                          : "فلترة التصنيفات",
                      child: Container(
                        decoration: BoxDecoration(
                          color: _selectedCategories.isNotEmpty
                              ? Colors.orange.withOpacity(0.2)
                              : Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _selectedCategories.isNotEmpty
                                ? Colors.orangeAccent.withOpacity(0.6)
                                : Colors.purpleAccent.withOpacity(0.3),
                          ),
                        ),
                        child: IconButton(
                          icon: Icon(
                            _selectedCategories.isNotEmpty
                                ? Icons.filter_list
                                : Icons.filter_list_outlined,
                            color: _selectedCategories.isNotEmpty
                                ? Colors.orangeAccent
                                : Colors.purpleAccent,
                            size: 22,
                          ),
                          onPressed: () {
                            _showFilterDialog(displayList);
                          },
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),

                // ✅ زر تصدير Excel
                if (PermissionsService().canExport)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Tooltip(
                      message: "تصدير البيانات المعروضة لإكسيل",
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.file_download, color: Colors.greenAccent, size: 22),
                          onPressed: () {
                            _exportToExcel(displayList);
                          },
                        ),
                      ),
                    ),
                  ),

                const SizedBox(width: 4),

                // ✅ زر تصدير PDF (جديد)
                if (PermissionsService().canExport)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Tooltip(
                      message: "تصدير البيانات المعروضة PDF",
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent, size: 22),
                          onPressed: () {
                            _exportToPDF(displayList);
                          },
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 12),
              ],
            ),
            body: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black, Colors.indigo.shade900, Colors.black],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: SafeArea(
                child: Center(
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: isWebOrDesktop ? 600 : double.infinity,
                    ),
                    child: Column(
                      children: [
                        _buildDateFilters(),
                        _buildTableHeader(),
                        Expanded(
                          child: _isLoading
                              ? const Center(
                                  child: CircularProgressIndicator(color: Colors.white))
                              : displayList.isEmpty
                                  ? const Center(
                                      child: Text(
                                        "لا توجد بيانات",
                                        style: TextStyle(
                                          color: Colors.white38,
                                          fontFamily: 'Cairo',
                                          fontSize: 14,
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      padding: const EdgeInsets.only(
                                          bottom: 20, left: 5, right: 5),
                                      itemCount: displayList.length,
                                      itemBuilder: (context, index) =>
                                          _buildDataRow(displayList[index]),
                                    ),
                        ),
                        // ✅ عرض إجمالي المبلغ (يظهر فقط عند وجود فلتر تصنيفات)
                        if (displayList.isNotEmpty && _selectedCategories.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'عدد الحركات: ${displayList.length}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontFamily: 'Cairo',
                                  ),
                                ),
                                Text(
                                  'الإجمالي: ${_calculateTotal(displayList).toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    color: Colors.cyanAccent,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Cairo',
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDateFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _datePickerBtn("من", _fromDate, (d) {
                setState(() => _fromDate = d!);
                _fetchData();
              }),
              const Icon(Icons.arrow_forward_ios,
                  color: Colors.white24, size: 10),
              _datePickerBtn("إلى", _toDate, (d) {
                setState(() => _toDate = d!);
                _fetchData();
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _datePickerBtn(
      String label, DateTime date, Function(DateTime?) onPick) {
    return InkWell(
      onTap: () async {
        DateTime? p = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(2020),
          lastDate: DateTime(2101),
        );
        if (p != null) onPick(p);
      },
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white60, fontSize: 10, fontFamily: 'Cairo')),
          Text(DateFormat('yyyy-MM-dd').format(date),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
          color: Colors.white10, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center, // ✅ توسيط الأعمدة
        children: const [
          Expanded(
              flex: 2,
              child: Text("المبلغ",
                  textAlign: TextAlign.center, // ✅ توسيط النص
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
          Expanded(
              flex: 3,
              child: Text("البيان",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
          Expanded(
              flex: 2,
              child: Text("التصنيف",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
          Expanded(
              flex: 2,
              child: Text("التاريخ",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  Widget _buildDataRow(Map<String, dynamic> item) {
    return InkWell(
      onTap: () => _showOptionsModal(item),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1️⃣ السطر الأول: بيانات الحركة القديمة (مع توسيط النصوص)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                    flex: 2,
                    child: Text("${item['amount'] ?? 0.0}",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600))),
                Expanded(
                    flex: 3,
                    child: Text("${item['statement'] ?? ''}",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontFamily: 'Cairo'),
                        overflow: TextOverflow.ellipsis)),
                Expanded(
                    flex: 2,
                    child: Text("${item['category'] ?? ''}",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontFamily: 'Cairo'),
                        overflow: TextOverflow.ellipsis)),
                Expanded(
                    flex: 2,
                    child: Text("${item['date'] ?? ''}",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 10))),
              ],
            ),

            const SizedBox(height: 6),

            // 2️⃣ السطر الثاني: رقم الإذن + الفرع + الموظف + الخزينة (جميعها في المنتصف)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // ✅ رقم الإذن
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.numbers, color: Colors.orange, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        "اذن: ${item['serial'] ?? ''}",
                        style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 9,
                            fontFamily: 'Cairo'),
                      ),
                    ],
                  ),
                ),
                // الخزينة
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.account_balance,
                          color: Colors.purple, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        "${_getTreasuryName(item['treasury'])}",
                        style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 9,
                            fontFamily: 'Cairo'),
                      ),
                    ],
                  ),
                ),
                
                // الموظف
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.person_rounded,
                          color: Colors.amber, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        "${item['employee'] ?? 'غير معروف'}",
                        style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 9,
                            fontFamily: 'Cairo'),
                      ),
                    ],
                  ),
                ),
                // الفرع
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.store_rounded,
                          color: Colors.cyan, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        "${_getBranchName(item['branch_code']?.toString())}",
                        style: const TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'Cairo'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _editTransaction(Map<String, dynamic> item) async {
    // 🌟 منع التعديل لحركات التحويل المزدوجة لحماية الأرصدة
    if (item['category'] == 'تحويل خزائن') {
      _showSnackBar("لا يمكن تعديل إذن التحويل المزدوج! الرجاء حذفه وإنشاء تحويل جديد.", Colors.orange);
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DailyPage(
          companyCode: widget.companyCode,
          editItem: item,
          userName: widget.userName, 
          selectedBranchCode: item['branch_code']?.toString() ?? widget.selectedBranchCode,
        ),
      ),
    );
    // ✅ بعد العودة من التعديل، نعيد تحميل البيانات
    _fetchData();
  }

  void _showOptionsModal(Map<String, dynamic> item) {
    bool canEdit = PermissionsService().canEditTransaction;
    bool canDelete = PermissionsService().canDeleteTransaction;

    // إذا لم تكن هناك صلاحية للتعديل ولا للحذف، نخرج بدون عرض القائمة
    if (!canEdit && !canDelete) {
      _showSnackBar("ليس لديك صلاحية لتعديل أو حذف الحركات", Colors.orange);
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.indigo.shade900,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(15))),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ✅ خيار التعديل يظهر فقط إذا كانت الصلاحية موجودة
          if (canEdit)
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.orange, size: 20),
              title: const Text("تعديل الإذن",
                  style: TextStyle(
                      color: Colors.white, fontFamily: 'Cairo', fontSize: 14)),
              onTap: () {
                Navigator.pop(context);
                _editTransaction(item);
              },
            ),
          // ✅ خيار الحذف يظهر فقط إذا كانت الصلاحية موجودة
          if (canDelete)
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red, size: 20),
              title: const Text("حذف الإذن",
                  style: TextStyle(
                      color: Colors.white, fontFamily: 'Cairo', fontSize: 14)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(item);
              },
            ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  void _confirmDelete(Map<String, dynamic> item) {
    // ✅ التحقق من صلاحية الحذف مرة أخرى قبل التأكيد
    if (!PermissionsService().canDeleteTransaction) {
      _showSnackBar("ليس لديك صلاحية للحذف", Colors.orange);
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.indigo.shade900,
        title: const Text("تأكيد الحذف", style: TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 15)),
        content: Text(
          item['category'] == 'تحويل خزائن' 
              ? "هل أنت متأكد من حذف هذا التحويل؟\n(سيقوم النظام آلياً بحذف حركة الصادر والوارد معاً لضبط الأرصدة)" 
              : "حذف إذن رقم ${item['serial']}؟", 
          style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                // 1. حذف الإذن الأساسي الذي ضغط عليه المستخدم
                await _dailyService.deleteTransaction(
                    widget.companyCode, item['serial'] ?? 0, item['branch_code']?.toString() ?? "1"); 
                
                // 2. 🌟 البحث الذكي عن الحركة التوأم (المقابلة) وحذفها آلياً
                if (item['category'] == 'تحويل خزائن') {
                  int counterpartSerial = -1;
                  String counterpartBranch = item['branch_code']?.toString() ?? "1";
                  double targetAmount = double.tryParse(item['amount'].toString()) ?? 0.0;
                  
                  final box = Hive.box('daily_transactions_box');
                  for (var val in box.values) {
                    if (val is Map && 
                        val['company_code'] == widget.companyCode && 
                        val['category'] == 'تحويل خزائن' && 
                        val['date'] == item['date'] && 
                        val['type'] != item['type'] && // نوع عكسي (لو صادر يبحث عن الوارد)
                        (double.tryParse(val['amount'].toString()) ?? 0.0) == targetAmount) {
                          
                      counterpartSerial = val['serial'] ?? -1;
                      counterpartBranch = val['branch_code']?.toString() ?? counterpartBranch;
                      break; // وجدنا الحركة التوأم!
                    }
                  }
                  
                  // إذا وجدنا التوأم، نحذفه فوراً من الفايربيز أيضاً
                  if (counterpartSerial != -1) {
                    await _dailyService.deleteTransaction(
                        widget.companyCode, counterpartSerial, counterpartBranch);
                  }
                }

                if (mounted) {
                  Navigator.pop(context); 
                  _showSnackBar(
                    item['category'] == 'تحويل خزائن' 
                        ? "تم حذف حركتي التحويل (الصادر والوارد) بنجاح لضبط ميزان الخزائن"
                        : "تم حذف الإذن بنجاح وتحديث الأرصدة محلياً", 
                    Colors.green
                  );
                  // ✅ إعادة تحميل البيانات بعد الحذف
                  _fetchData();
                }
              } catch (e) {
                if (mounted) {
                  Navigator.pop(context); 
                  _showSnackBar("فشل الحذف: ${e.toString()}", Colors.red); 
                }
              }
            },
            child: const Text("حذف", style: TextStyle(color: Colors.redAccent, fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 🌟 دالة مساعدة لجلب اسم الخزينة من الحقل المخزن
  String _getTreasuryName(String? treasury) {
    if (treasury == null || treasury.isEmpty) return 'غير محدد';
    return treasury; // الحقل يخزن الاسم مباشرة
  }

  void _showSnackBar(String m, Color c) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(m,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
          backgroundColor: c));
}