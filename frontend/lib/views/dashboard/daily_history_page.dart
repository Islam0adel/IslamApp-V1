import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
// Alias عشان نحل مشكلة الـ Border والتعارض مع فلاتر

import 'package:file_picker/file_picker.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import 'daily_page.dart';
import 'package:universal_html/html.dart' as html; // للتحميل في الويب
import 'package:excel/excel.dart' as excel_lib;

class DailyHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? userName; // خليه اختياري بعلامة الاستفهام

  const DailyHistoryPage({
    super.key,
    required this.companyCode,
    this.userName, // شيل كلمة required من هنا
  });

  @override
  State<DailyHistoryPage> createState() => _DailyHistoryPageState();
}

class _DailyHistoryPageState extends State<DailyHistoryPage> {
  final DailyService _dailyService = DailyService();
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 7));
  DateTime _toDate = DateTime.now();
  List<dynamic> _historyData = [];
  bool _isLoading = false;
  bool _isCategoryGrouped = false; // تشغيل/إيقاف فلتر التصنيف

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final data = await _dailyService.getTransactionsHistory(
        widget.companyCode,
        DateFormat('yyyy-MM-dd').format(_fromDate),
        DateFormat('yyyy-MM-dd').format(_toDate),
      );

      setState(() {
        _historyData = data;
        _applySorting();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar("خطأ في التحميل: $e", Colors.red);
    }
  }

  void _applySorting() {
    setState(() {
      if (_isCategoryGrouped) {
        _historyData.sort((a, b) {
          int cmp = a['category'].compareTo(b['category']);
          if (cmp != 0) return cmp;
          return a['serial'].compareTo(b['serial']);
        });
      } else {
        _historyData.sort((a, b) => a['serial'].compareTo(b['serial']));
      }
    });
  }

// تأكد إنك بتمرر اسم المستخدم للصفحة دي أو بتجيبه من التخزين
  // هفترض إن عندك متغير اسمه userName موجود في الصفحة

Future<void> _exportToExcel() async {
  // 1. التحقق من وجود بيانات
  if (_historyData.isEmpty) {
    _showSnackBar("لا توجد بيانات لتصديرها", Colors.orange);
    return;
  }

  try {
    // 2. إعداد اسم الملف مع التاريخ (مثال: تقرير_اليومية_15-5-2026.xlsx)
    String formattedDate = "${DateTime.now().day}-${DateTime.now().month}-${DateTime.now().year}";
    String fileName = "تقرير_اليومية_$formattedDate.xlsx";

    // 3. إنشاء كائن Excel
    var excel = excel_lib.Excel.createExcel();

    // 4. حل مشكلة الشيتات الزائدة (مثل شيت فلاتر أو Sheet1)
    // نقوم بتغيير اسم أول شيت افتراضي للمكتبة بدلاً من إنشاء شيت جديد
    String defaultSheet = excel.tables.keys.first;
    excel.rename(defaultSheet, 'Daily_Records');
    excel_lib.Sheet sheetObject = excel['Daily_Records'];

    // التأكد من حذف أي شيتات أخرى قد تظهر
    for (var table in excel.tables.keys.toList()) {
      if (table != 'Daily_Records') {
        excel.delete(table);
      }
    }

    // 5. إضافة سطر العناوين
    sheetObject.appendRow([
      excel_lib.TextCellValue("رقم الإذن"),
      excel_lib.TextCellValue("المبلغ"),
      excel_lib.TextCellValue("البيان"),
      excel_lib.TextCellValue("التصنيف"),
      excel_lib.TextCellValue("التاريخ"),
    ]);

    // 6. إضافة البيانات من القائمة
    for (var row in _historyData) {
      sheetObject.appendRow([
        excel_lib.TextCellValue(row['serial']?.toString() ?? ""),
        excel_lib.TextCellValue(row['amount']?.toString() ?? "0"),
        excel_lib.TextCellValue(row['statement'] ?? ""),
        excel_lib.TextCellValue(row['category'] ?? ""),
        excel_lib.TextCellValue(row['date'] ?? ""),
      ]);
    }

    // 7. تحويل الملف إلى بايتات (Encode)
    var fileBytes = excel.encode();
    if (fileBytes == null) return;

    // 8. منطق التحميل حسب المنصة (ويب أو ويندوز)
    if (identical(0, 0.0)) {
      // --- كود الويب (تحميل مباشر للمتصفح) ---
      final blob = html.Blob([fileBytes], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      final url = html.Url.createObjectUrlFromBlob(blob);
      
      // final anchor = html.AnchorElement(href: url)
      //   ..setAttribute("download", fileName)
      //   ..click();
      
      html.Url.revokeObjectUrl(url);
      _showSnackBar("تم تحميل $fileName بنجاح", Colors.green);
    } else {
      // --- كود الويندوز (حفظ في مسار محدد) ---
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
    debugPrint("Export Error: $e");
    _showSnackBar("فشل التصدير: $e", Colors.red);
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title:
            const Text("معاينة الأذون", style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share, color: Colors.greenAccent),
            onPressed: _exportToExcel,
            tooltip: "تصدير إكسيل",
          ),
          IconButton(
            icon: Icon(
              _isCategoryGrouped ? Icons.filter_alt : Icons.filter_alt_off,
              color: _isCategoryGrouped ? Colors.amber : Colors.white70,
            ),
            onPressed: () {
              setState(() {
                _isCategoryGrouped = !_isCategoryGrouped;
                _applySorting();
              });
              _showSnackBar(
                  _isCategoryGrouped ? "ترتيب حسب التصنيف" : "ترتيب حسب الإذن",
                  Colors.indigo);
            },
          ),
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
          child: Column(
            children: [
              _buildDateFilters(),
              _buildTableHeader(),
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(color: Colors.white))
                    : _historyData.isEmpty
                        ? const Center(
                            child: Text("لا توجد بيانات",
                                style: TextStyle(color: Colors.white38)))
                        : ListView.builder(
                            itemCount: _historyData.length,
                            itemBuilder: (context, index) =>
                                _buildDataRow(_historyData[index]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 1. ويدجت فلتر التاريخ
  Widget _buildDateFilters() {
    return Padding(
      padding: const EdgeInsets.all(15),
      child: GlassCard(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _datePickerBtn("من", _fromDate, (d) {
              setState(() => _fromDate = d!);
              _fetchData();
            }),
            const Icon(Icons.arrow_forward_ios,
                color: Colors.white24, size: 15),
            _datePickerBtn("إلى", _toDate, (d) {
              setState(() => _toDate = d!);
              _fetchData();
            }),
          ],
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
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
          Text(DateFormat('yyyy-MM-dd').format(date),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // 2. رأس الجدول
  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
      margin: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
          color: Colors.white10, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: const [
          Expanded(
              flex: 2,
              child: Text("المبلغ",
                  style: TextStyle(
                      color: Colors.cyan, fontWeight: FontWeight.bold))),
          Expanded(
              flex: 3,
              child: Text("البيان",
                  style: TextStyle(
                      color: Colors.cyan, fontWeight: FontWeight.bold))),
          Expanded(
              flex: 2,
              child: Text("التصنيف",
                  style: TextStyle(
                      color: Colors.cyan, fontWeight: FontWeight.bold))),
          Expanded(
              flex: 2,
              child: Text("التاريخ",
                  style: TextStyle(
                      color: Colors.cyan, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  // 3. سطر البيانات
  Widget _buildDataRow(Map<String, dynamic> item) {
    return InkWell(
      onTap: () => _showOptionsModal(item),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 15),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
                flex: 2,
                child: Text("${item['amount']}",
                    style: const TextStyle(color: Colors.white))),
            Expanded(
                flex: 3,
                child: Text("${item['statement']}",
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis)),
            Expanded(
                flex: 2,
                child: Text("${item['category']}",
                    style: const TextStyle(color: Colors.white70))),
            Expanded(
                flex: 2,
                child: Text("${item['date']}",
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 11))),
          ],
        ),
      ),
    );
  }

  // 4. دالة التعديل (المصلحة)
  void _editTransaction(Map<String, dynamic> item) async {
    // ننتقل لصفحة اليومية وننتظر نتيجة (true) عند الحفظ
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DailyPage(
          companyCode: widget.companyCode,
          editItem: item, // نمرر البيانات للتعديل
        ),
      ),
    );

    // لو رجعنا بـ true يعني التعديل نجح، نحدث القائمة فوراً
    if (result == true) {
      _fetchData();
    }
  }

  void _showOptionsModal(Map<String, dynamic> item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.indigo.shade900,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.orange),
            title: const Text("تعديل الإذن",
                style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              _editTransaction(item);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title:
                const Text("حذف الإذن", style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              _confirmDelete(item);
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  void _confirmDelete(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("تأكيد الحذف"),
        content: Text("حذف إذن رقم ${item['serial']}؟"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("إلغاء")),
          TextButton(
              onPressed: () async {
                await _dailyService.deleteTransaction(
                    widget.companyCode, item['serial']);
                Navigator.pop(context);
                _fetchData();
              },
              child: const Text("حذف", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

  void _showSnackBar(String m, Color c) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(m, textAlign: TextAlign.center), backgroundColor: c));
}
