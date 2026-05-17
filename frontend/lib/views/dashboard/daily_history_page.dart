import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import 'daily_page.dart';
import 'package:universal_html/html.dart' as html; 
import 'package:excel/excel.dart' as excel_lib;

class DailyHistoryPage extends StatefulWidget {
  final String companyCode;
  final String selectedBranch; // 👈 إضافة حقل الفرع النشط هنا
  final String? userName; 

  const DailyHistoryPage({
    super.key,
    required this.companyCode,
    required this.selectedBranch, // مطلوب
    this.userName, 
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
  bool _isCategoryGrouped = false; 

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

      // تصفية العرض بناءً على الفرع المحدد في الشاشة الرئيسية (الفلترة الذكية)
      List<dynamic> filteredData = [];
      if (widget.selectedBranch == "كل الفروع") {
        filteredData = data;
      } else {
        filteredData = data.where((element) => (element['branch'] ?? 'الفرع الرئيسي') == widget.selectedBranch).toList();
      }

      setState(() {
        _historyData = filteredData;
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

  Future<void> _exportToExcel() async {
    if (_historyData.isEmpty) {
      _showSnackBar("لا توجد بيانات لتصديرها", Colors.orange);
      return;
    }

    try {
      String formattedDate = "${DateTime.now().day}-${DateTime.now().month}-${DateTime.now().year}";
      String fileName = "تقرير_اليومية_${widget.selectedBranch}_$formattedDate.xlsx";

      var excel = excel_lib.Excel.createExcel();
      String defaultSheet = excel.tables.keys.first;
      excel.rename(defaultSheet, 'Daily_Records');
      excel_lib.Sheet sheetObject = excel['Daily_Records'];

      for (var table in excel.tables.keys.toList()) {
        if (table != 'Daily_Records') excel.delete(table);
      }

      sheetObject.appendRow([
        excel_lib.TextCellValue("رقم الإذن"),
        excel_lib.TextCellValue("المبلغ"),
        excel_lib.TextCellValue("البيان"),
        excel_lib.TextCellValue("التصنيف"),
        excel_lib.TextCellValue("التاريخ"),
        excel_lib.TextCellValue("المسؤول"),
        excel_lib.TextCellValue("الفرع"),
        
      ]);

      for (var row in _historyData) {
        sheetObject.appendRow([
          excel_lib.TextCellValue(row['serial']?.toString() ?? ""),
          excel_lib.TextCellValue(row['amount']?.toString() ?? "0"),
          excel_lib.TextCellValue(row['statement'] ?? ""),
          excel_lib.TextCellValue(row['category'] ?? ""),
          excel_lib.TextCellValue(row['branch'] ?? "الفرع الرئيسي"),
          excel_lib.TextCellValue(row['employee'] ?? "غير محدد"),
          excel_lib.TextCellValue(row['date'] ?? ""),
        ]);
      }

      var fileBytes = excel.encode();
      if (fileBytes == null) return;

      if (identical(0, 0.0)) {
        final blob = html.Blob([fileBytes], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
        final url = html.Url.createObjectUrlFromBlob(blob);
        final anchor = html.AnchorElement(href: url)..setAttribute("download", fileName)..style.display = "none";
        html.document.body?.append(anchor);
        anchor.click();
        anchor.remove();
        html.Url.revokeObjectUrl(url);
        _showSnackBar("تم تحميل $fileName بنجاح", Colors.green);
      } else {
        String? selectedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'اختر مكان حفظ ملف الإكسيل', fileName: fileName, type: FileType.custom, allowedExtensions: ['xlsx'],
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
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("معاينة الحركات", style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.ios_share, color: Colors.greenAccent), onPressed: _exportToExcel, tooltip: "تصدير إكسيل"),
          IconButton(
            icon: Icon(_isCategoryGrouped ? Icons.filter_alt : Icons.filter_alt_off, color: _isCategoryGrouped ? Colors.amber : Colors.white70),
            onPressed: () {
              setState(() {
                _isCategoryGrouped = !_isCategoryGrouped;
                _applySorting();
              });
            },
          ),
        ],
      ),
      body: Container(
        width: double.infinity, height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [Colors.black, Colors.indigo.shade900, Colors.black], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // كارت يوضح للمستخدم الفرع النشط المفلتر به حالياً
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: Text("معاينة فرع: ${widget.selectedBranch}", style: const TextStyle(color: Colors.cyanAccent, fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              ),
              _buildDateFilters(),
              _buildTableHeader(),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.white))
                    : _historyData.isEmpty
                        ? const Center(child: Text("لا توجد بيانات لهذا الفرع", style: TextStyle(color: Colors.white38, fontFamily: 'Cairo')))
                        : ListView.builder(
                            itemCount: _historyData.length,
                            itemBuilder: (context, index) => _buildDataRow(_historyData[index]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
            const Icon(Icons.arrow_forward_ios, color: Colors.white24, size: 15),
            _datePickerBtn("إلى", _toDate, (d) {
              setState(() => _toDate = d!);
              _fetchData();
            }),
          ],
        ),
      ),
    );
  }

  Widget _datePickerBtn(String label, DateTime date, Function(DateTime?) onPick) {
    return InkWell(
      onTap: () async {
        DateTime? p = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime(2101));
        if (p != null) onPick(p);
      },
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'Cairo')),
          Text(DateFormat('yyyy-MM-dd').format(date), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
      margin: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: const [
          Expanded(flex: 2, child: Text("المبلغ", style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontFamily: 'Cairo'))),
          Expanded(flex: 3, child: Text("البيان والمسؤول", style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontFamily: 'Cairo'))),
          Expanded(flex: 2, child: Text("التصنيف", style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontFamily: 'Cairo'))),
          Expanded(flex: 2, child: Text("التاريخ", style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  // 🟢 تعديل سطر البيانات لعرض اسم المستخدم واسم الفرع بذكاء وأناقة تحت البيان
  Widget _buildDataRow(Map<String, dynamic> item) {
    String emp = item['employee'] ?? "غير محدد";
    String br = item['branch'] ?? "الفرع الرئيسي";

    return InkWell(
      onTap: () => _showOptionsModal(item),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5))),
        child: Row(
          children: [
            Expanded(flex: 2, child: Text("${item['amount']}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("${item['statement']}", style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Cairo'), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  // 🚀 كتابة اسم المسجل والفرع بخط صغير منور
                  Text("بواسطة: $emp ($br)", style: const TextStyle(color: Colors.amberAccent, fontSize: 10, fontFamily: 'Cairo')),
                ],
              ),
            ),
            Expanded(flex: 2, child: Text("${item['category']}", style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'Cairo'))),
            Expanded(flex: 2, child: Text("${item['date']}", style: const TextStyle(color: Colors.white60, fontSize: 11))),
          ],
        ),
      ),
    );
  }

  void _editTransaction(Map<String, dynamic> item) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DailyPage(
          companyCode: widget.companyCode,
          selectedBranch: widget.selectedBranch,
          userName: widget.userName ?? "مدير",
          editItem: item,
        ),
      ),
    );
    if (result == true) _fetchData();
  }

  void _showOptionsModal(Map<String, dynamic> item) {
    showModalBottomSheet(
      context: context, backgroundColor: Colors.indigo.shade900,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.orange), title: const Text("تعديل الإذن", style: TextStyle(color: Colors.white, fontFamily: 'Cairo')),
            onTap: () { Navigator.pop(context); _editTransaction(item); },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red), title: const Text("حذف الإذن", style: TextStyle(color: Colors.white, fontFamily: 'Cairo')),
            onTap: () { Navigator.pop(context); _confirmDelete(item); },
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
        title: const Text("تأكيد الحذف", style: TextStyle(fontFamily: 'Cairo')),
        content: Text("حذف إذن رقم ${item['serial']}؟", style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("إلغاء", style: TextStyle(fontFamily: 'Cairo'))),
          TextButton(
              onPressed: () async {
                await _dailyService.deleteTransaction(widget.companyCode, item['serial']);
                Navigator.pop(context);
                _fetchData();
              },
              child: const Text("حذف", style: TextStyle(color: Colors.red, fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: c));
}