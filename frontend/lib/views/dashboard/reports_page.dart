// import 'dart:ui' as ui; 
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
// import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:universal_html/html.dart' as html;
import '../../views/widgets/glass_card.dart';
// import 'package:screenshot/screenshot.dart';

class ReportsPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;  // ✅ تغيير من selectedBranch إلى selectedBranchCode
  
  const ReportsPage({super.key, required this.companyCode, this.selectedBranchCode});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
  
}

class _ReportsPageState extends State<ReportsPage> {
  
  // final ScreenshotController _screenshotController = ScreenshotController();

  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();
  int _selectedReportType = 1;

  // ✅ دالة مساعدة لجلب اسم الفرع من الكود
  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    final Box codingBox = Hive.box('coding_box');
    final rawData = codingBox.get("${widget.companyCode}_branches", defaultValue: []);
    for (var item in rawData) {
      if (item['code']?.toString() == code) return item['name']?.toString() ?? "فرع غير معروف";
    }
    return "فرع غير معروف";
  }

  List<Map<dynamic, dynamic>> _getFilteredTransactions() {
    final box = Hive.box('daily_transactions_box');
    return box.values.where((tx) {
      if (tx['company_code'] != widget.companyCode) return false;

      // ✅ الفلترة باستخدام كود الفرع بدلاً من الاسم
      if (widget.selectedBranchCode != null &&
          widget.selectedBranchCode != "all" &&
          widget.selectedBranchCode != "") {
        if (tx['branch_code']?.toString() != widget.selectedBranchCode) return false;
      }

      try {
        DateTime txDate = DateTime.parse(tx['date'].toString().substring(0, 10));
        DateTime from = DateTime(_fromDate.year, _fromDate.month, _fromDate.day);
        DateTime to = DateTime(_toDate.year, _toDate.month, _toDate.day);

        return (txDate.isAtSameMomentAs(from) || txDate.isAfter(from)) &&
               (txDate.isAtSameMomentAs(to) || txDate.isBefore(to));
      } catch (e) {
        return false;
      }
    }).map((e) => e as Map<dynamic, dynamic>).toList();
  }

  // ===================== تصدير EXCEL =====================
  Future<void> _shareAsExcel() async {
  final transactions = _getFilteredTransactions();
  if (transactions.isEmpty) return _showEmptySheetRow();

  try {
    var excel = excel_lib.Excel.createExcel();
    String defaultSheet = excel.tables.keys.first;
    excel.rename(defaultSheet, 'التقرير المفلتر');
    excel_lib.Sheet sheetObject = excel['التقرير المفلتر'];

    String branchName = _getBranchName(widget.selectedBranchCode);
    String dateStr = "من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}";

    // عنوان رئيسي
    sheetObject.appendRow([excel_lib.TextCellValue(_selectedReportType == 1 ? "تقرير المبيعات" : "تقرير الفترة")]);
    sheetObject.appendRow([excel_lib.TextCellValue("الفرع: $branchName")]);
    sheetObject.appendRow([excel_lib.TextCellValue("الفترة: $dateStr")]);
    sheetObject.appendRow([]); // سطر فارغ

    // ------ إضافة البيانات حسب نوع التقرير ------
    if (_selectedReportType == 1) {
      // تقرير المبيعات (وارد)
      // تجميع البيانات اليومية والفئات
      Map<String, Map<String, double>> dailyData = {};
      Set<String> allCategories = {};
      for (var tx in transactions) {
        if (tx['type'] == 'وارد') {
          String date = tx['date'].toString().substring(0, 10);
          String category = tx['category'] ?? 'عام';
          double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;
          allCategories.add(category);
          dailyData.putIfAbsent(date, () => {});
          dailyData[date]![category] = (dailyData[date]![category] ?? 0.0) + amount;
          dailyData[date]!['الإجمالي اليومي'] = (dailyData[date]!['الإجمالي اليومي'] ?? 0.0) + amount;
        }
      }
      List<String> sortedDates = dailyData.keys.toList()..sort();
      List<String> categories = allCategories.toList()..sort();

      // صف العناوين
      List<String> headers = ['التاريخ', ...categories, 'الإجمالي اليومي'];
      sheetObject.appendRow(headers.map((h) => excel_lib.TextCellValue(h)).toList());

      // صفوف البيانات
      for (String date in sortedDates) {
        List<excel_lib.CellValue?> row = [excel_lib.TextCellValue(date)];
        for (String cat in categories) {
          double val = dailyData[date]![cat] ?? 0.0;
          row.add(excel_lib.DoubleCellValue(val));
        }
        double total = dailyData[date]!['الإجمالي اليومي'] ?? 0.0;
        row.add(excel_lib.DoubleCellValue(total));
        sheetObject.appendRow(row);
      }

      // إجماليات نهائية
      sheetObject.appendRow([]);
      Map<String, double> categoryTotals = {};
      for (var tx in transactions.where((t) => t['type'] == 'وارد')) {
        String cat = tx['category'] ?? 'عام';
        double amt = double.tryParse(tx['amount'].toString()) ?? 0.0;
        categoryTotals[cat] = (categoryTotals[cat] ?? 0.0) + amt;
      }
      double grandTotal = categoryTotals.values.fold(0.0, (sum, val) => sum + val);
      sheetObject.appendRow([excel_lib.TextCellValue("إجمالي الفترة")]);
      for (String cat in categories) {
        sheetObject.appendRow([excel_lib.TextCellValue(cat), excel_lib.DoubleCellValue(categoryTotals[cat] ?? 0.0)]);
      }
      sheetObject.appendRow([excel_lib.TextCellValue("الإجمالي الكلي"), excel_lib.DoubleCellValue(grandTotal)]);
    } 
    else if (_selectedReportType == 2) {
      // تقرير الفترة (إيرادات ومصروفات)
      double totalIncome = 0, totalExpenses = 0, totalGoods = 0;
      Map<String, double> incomeByTreasury = {};
      Map<String, double> expensesByCategory = {};

      for (var tx in transactions) {
        double amt = double.tryParse(tx['amount'].toString()) ?? 0.0;
        if (tx['type'] == 'وارد') {
          totalIncome += amt;
          String treasury = tx['treasury'] ?? 'غير محدد';
          incomeByTreasury[treasury] = (incomeByTreasury[treasury] ?? 0.0) + amt;
        } else if (tx['type'] == 'صادر') {
          totalExpenses += amt;
          String cat = tx['category'] ?? 'عام';
          expensesByCategory[cat] = (expensesByCategory[cat] ?? 0.0) + amt;
          if (cat == 'بضاعة') totalGoods += amt;
        }
      }

      sheetObject.appendRow([excel_lib.TextCellValue("تفاصيل الإيرادات")]);
      sheetObject.appendRow(["الخزينة", "المبلغ"].map((h) => excel_lib.TextCellValue(h)).toList());
      incomeByTreasury.forEach((key, val) {
        sheetObject.appendRow([excel_lib.TextCellValue(key), excel_lib.DoubleCellValue(val)]);
      });
      sheetObject.appendRow([excel_lib.TextCellValue("إجمالي الإيرادات"), excel_lib.DoubleCellValue(totalIncome)]);

      sheetObject.appendRow([]);
      sheetObject.appendRow([excel_lib.TextCellValue("تفاصيل المصروفات")]);
      sheetObject.appendRow(["الفئة", "المبلغ"].map((h) => excel_lib.TextCellValue(h)).toList());
      expensesByCategory.forEach((key, val) {
        sheetObject.appendRow([excel_lib.TextCellValue(key), excel_lib.DoubleCellValue(val)]);
      });
      sheetObject.appendRow([excel_lib.TextCellValue("إجمالي المصروفات"), excel_lib.DoubleCellValue(totalExpenses)]);

      sheetObject.appendRow([]);
      double netExpenses = totalExpenses - totalGoods;
      double finalBalance = totalIncome - totalExpenses;
      sheetObject.appendRow([excel_lib.TextCellValue("صافي المصروفات (بدون بضاعة)"), excel_lib.DoubleCellValue(netExpenses)]);
      sheetObject.appendRow([excel_lib.TextCellValue("قيمة البضاعة المشتراة"), excel_lib.DoubleCellValue(totalGoods)]);
      sheetObject.appendRow([excel_lib.TextCellValue("صافي الرصيد النهائي"), excel_lib.DoubleCellValue(finalBalance)]);
    }

    var fileBytes = excel.encode();
    if (fileBytes == null) return;

    String fileName = "تقرير_${DateTime.now().millisecondsSinceEpoch}.xlsx";

    if (kIsWeb) {
      final blob = html.Blob([fileBytes], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute("download", fileName)
        ..click();
      html.Url.revokeObjectUrl(url);
    } else {
      final xFile = XFile.fromData(
        Uint8List.fromList(fileBytes),
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        name: fileName,
      );
      await Share.shareXFiles([xFile], text: "مرفق لكم تقرير إكسيل");
    }
  } catch (e) {
    _showErrorSnackBar(e.toString());
  }
}

  // ===================== تصدير PDF =====================
  Future<void> _shareAsPdf() async {
    final transactions = _getFilteredTransactions();
    if (transactions.isEmpty) return _showEmptySheetRow();

    try {
      final pdf = pw.Document();
      var arabicFont = pw.Font.ttf(await rootBundle.load("assets/fonts/Cairo-Regular.ttf"));

      String branchName = _getBranchName(widget.selectedBranchCode); // ✅ استخدام الاسم للعرض
      String dateStr = "من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}";
      final primaryColor = PdfColor.fromHex('#050F4C');
      final accentColor = PdfColor.fromHex('#3062F8');

      pdf.addPage(
        pw.MultiPage(
          theme: pw.ThemeData.withFont(base: arabicFont),
          textDirection: pw.TextDirection.rtl,
          build: (pw.Context context) {
            return [
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(15),
                decoration: pw.BoxDecoration(
                  color: primaryColor,
                  borderRadius: pw.BorderRadius.circular(10),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      _selectedReportType == 1 ? "تقرير المبيعات التفصيلي" : "تقرير الأداء المالي (الفترة)",
                      style: pw.TextStyle(font: arabicFont, fontSize: 20, color: PdfColors.amber, fontWeight: pw.FontWeight.bold),
                    ),
                    pw.SizedBox(height: 5),
                    pw.Text("الفرع الحالي: $branchName", style: pw.TextStyle(font: arabicFont, fontSize: 13, color: PdfColors.white)),
                    pw.Text("الفترة الزمنية: $dateStr", style: pw.TextStyle(font: arabicFont, fontSize: 11, color: const PdfColor(1, 1, 1, 0.8))),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),
              _selectedReportType == 1
                  ? _buildPdfSalesReportStructure(transactions, arabicFont, primaryColor)
                  : _buildPdfFinanceReportStructure(transactions, arabicFont, primaryColor, accentColor),
            ];
          },
        ),
      );

      final pdfBytes = await pdf.save();
      String fileName = "تقرير_${DateTime.now().millisecondsSinceEpoch}.pdf";

      if (kIsWeb) {
        final blob = html.Blob([pdfBytes], 'application/pdf');
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute("download", fileName)
          ..click();
        html.Url.revokeObjectUrl(url);
      } else {
        final xFile = XFile.fromData(pdfBytes, mimeType: 'application/pdf', name: fileName);
        await Share.shareXFiles([xFile], text: "مرفق لكم تقرير PDF ملون");
      }
    } catch (e) {
      _showErrorSnackBar("تأكد من إعداد ملف الخط بشكل صحيح: $e");
    }
  }

  // ===================== تصدير صورة =====================
//   Future<void> _shareAsImage() async {
//   try {
//     // عرض مؤشر تحميل
//     showDialog(
//       context: context,
//       barrierDismissible: false,
//       builder: (context) => const Center(
//         child: CircularProgressIndicator(color: Colors.cyanAccent),
//       ),
//     );

//     // انتظر لحظة لضمان اكتمال بناء الـ Widget
//     await Future.delayed(const Duration(milliseconds: 500));

//     // التقاط الصورة لكامل المحتوى (حتى الطويل)
//     Uint8List? pngBytes = await _screenshotController.capture();

//     // إغلاق مؤشر التحميل إذا كانت الصفحة لا تزال موجودة
//     if (mounted) Navigator.pop(context);

//     if (pngBytes == null) return;

//     // إنشاء اسم الملف
//     String fileName = "تقرير_مصور_${DateTime.now().millisecondsSinceEpoch}.png";

//     if (kIsWeb) {
//       // حفظ على المتصفح
//       final blob = html.Blob([pngBytes], 'image/png');
//       final url = html.Url.createObjectUrlFromBlob(blob);
//       html.AnchorElement(href: url)
//         ..setAttribute("download", fileName)
//         ..click();
//       html.Url.revokeObjectUrl(url);
//     } else {
//       // مشاركة على الهاتف
//       final xFile = XFile.fromData(pngBytes, mimeType: 'image/png', name: fileName);
//       await Share.shareXFiles([xFile], text: "مرفق لقطة صورة للتقرير");
//     }
//   } catch (e) {
//     // إغلاق مؤشر التحميل في حالة الخطأ
//     if (mounted) Navigator.pop(context);
//     _showErrorSnackBar("فشل التقاط الصورة: $e");
//   }
// }

  void _showShareBottomSheet() {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color.fromARGB(255, 11, 20, 78),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                kIsWeb ? "تحميل التقرير الحالي على جهازك" : "مشاركة التقرير عبر تطبيقات الهاتف",
                style: const TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildShareOptionItem(
                    icon: Icons.table_chart,
                    color: Colors.greenAccent,
                    label: "ملف Excel",
                    onTap: () { Navigator.pop(context); _shareAsExcel(); }
                  ),
                  _buildShareOptionItem(
                    icon: Icons.picture_as_pdf,
                    color: Colors.redAccent,
                    label: "تقرير PDF ملون",
                    onTap: () { Navigator.pop(context); _shareAsPdf(); }
                  ),
                  // ❌ تم إزالة خيار الصورة بسبب مشكلة التوافق
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

  Widget _buildShareOptionItem({required IconData icon, required Color color, required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Future<void> _selectDate(BuildContext context, bool isFrom) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _fromDate : _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.blueAccent,
              onPrimary: Colors.white,
              surface: Color.fromARGB(255, 30, 30, 30),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _fromDate = picked;
          if (_toDate.isBefore(_fromDate)) _toDate = _fromDate;
        } else {
          _toDate = picked;
          if (_fromDate.isAfter(_toDate)) _fromDate = _toDate;
        }
      });
    }
  }

  @override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(
      backgroundColor: const Color.fromARGB(149, 5, 15, 76),
      elevation: 0,
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.cyanAccent.withOpacity(0.4)),
            ),
            child: IconButton(
              icon: const Icon(Icons.share, color: Colors.cyanAccent, size: 22),
              onPressed: _showShareBottomSheet,
            ),
          ),
        ),
      ],
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("التقارير", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 16)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.cyanAccent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              "فرع: ${_getBranchName(widget.selectedBranchCode)}",
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.cyanAccent),
            ),
          ),
        ],
      ),
      centerTitle: true,
    ),
    extendBodyBehindAppBar: true,
    body: Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Theme.of(context).scaffoldBackgroundColor, const Color.fromARGB(238, 48, 98, 248)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              _buildDateFilters(),
              const SizedBox(height: 15),
              _buildReportTypeSelector(),
              const SizedBox(height: 20),
              Expanded(
                child: GlassCard(
                  child: _selectedReportType == 1
                      ? _buildSalesReport()
                      : _buildIncomeExpenseReport(),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

  pw.Widget _buildPdfSalesReportStructure(List<Map<dynamic, dynamic>> transactions, pw.Font font, PdfColor primaryColor) {
    Map<String, Map<String, double>> dailyData = {};
    Set<String> allCategories = {};
    for (var tx in transactions) {
      if (tx['type'] == 'وارد') {
        String date = tx['date'].toString().substring(0, 10);
        String category = tx['category'] ?? 'عام';
        double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;
        allCategories.add(category);
        dailyData.putIfAbsent(date, () => {'total': 0.0});
        dailyData[date]![category] = (dailyData[date]![category] ?? 0.0) + amount;
        dailyData[date]!['total'] = dailyData[date]!['total']! + amount;
      }
    }
    List<String> sortedDates = dailyData.keys.toList()..sort();
    List<String> columns = allCategories.toList()..sort();

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(color: primaryColor),
          children: [
            pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("التاريخ", style: pw.TextStyle(font: font, color: PdfColors.white, fontWeight: pw.FontWeight.bold))),
            ...columns.map((c) => pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(c, style: pw.TextStyle(font: font, color: PdfColors.white)))),
            pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("الإجمالي", style: pw.TextStyle(font: font, color: PdfColors.amber, fontWeight: pw.FontWeight.bold))),
          ]
        ),
        ...sortedDates.map((date) => pw.TableRow(
          children: [
            pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text(date)),
            ...columns.map((c) => pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text((dailyData[date]![c] ?? 0).toStringAsFixed(2)))),
            pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text(dailyData[date]!['total']!.toStringAsFixed(2), style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
          ]
        ))
      ]
    );
  }

  pw.Widget _buildPdfFinanceReportStructure(List<Map<dynamic, dynamic>> transactions, pw.Font font, PdfColor primaryColor, PdfColor accentColor) {
    double totalIncome = 0; double totalExpenses = 0; double totalGoods = 0;
    for (var tx in transactions) {
      double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;
      if (tx['type'] == 'وارد') { totalIncome += amount; }
      else if (tx['type'] == 'صادر') {
        totalExpenses += amount;
        if (tx['category'] == 'بضاعة') totalGoods += amount;
      }
    }
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(color: PdfColors.grey100, borderRadius: pw.BorderRadius.circular(8)),
      child: pw.Column(
        children: [
          _pdfSummaryRow("إجمالي الإيرادات الكلية:", totalIncome, PdfColors.green, font),
          pw.Divider(color: PdfColors.grey300),
          _pdfSummaryRow("إجمالي المصروفات التشغيلية:", totalExpenses - totalGoods, PdfColors.orange, font),
          _pdfSummaryRow("إجمالي قيمة البضاعة المشتراة:", totalGoods, PdfColors.orange, font),
          pw.Divider(color: PdfColors.grey400),
          _pdfSummaryRow("صافي الرصيد المتبقي النهائي:", totalIncome - totalExpenses, (totalIncome - totalExpenses) >= 0 ? PdfColors.blue : PdfColors.red, font, isBold: true),
        ]
      )
    );
  }

  pw.Widget _pdfSummaryRow(String label, double val, PdfColor col, pw.Font font, {bool isBold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(font: font, fontSize: isBold ? 14 : 12, fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text(val.toStringAsFixed(2), style: pw.TextStyle(font: font, fontSize: isBold ? 15 : 13, color: col, fontWeight: pw.FontWeight.bold)),
        ]
      )
    );
  }

  void _showEmptySheetRow() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("لا توجد بيانات للفترة المحددة لتصديرها")));
  void _showErrorSnackBar(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, textAlign: TextAlign.center), backgroundColor: Colors.red));

  Widget _buildDateFilters() {
    return Row(
      children: [
        Expanded(child: _dateButton("من", _fromDate, () => _selectDate(context, true))),
        const SizedBox(width: 10),
        Expanded(child: _dateButton("إلى", _toDate, () => _selectDate(context, false))),
      ],
    );
  }

  Widget _dateButton(String label, DateTime date, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'Cairo')),
            const SizedBox(height: 4),
            Text(DateFormat('yyyy-MM-dd').format(date), style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildReportTypeSelector() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _selectedReportType == 1 ? Theme.of(context).primaryColor : Colors.white.withOpacity(0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () => setState(() => _selectedReportType = 1),
            child: const Text("تقرير المبيعات (وارد)", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _selectedReportType == 2 ? Theme.of(context).primaryColor : Colors.white.withOpacity(0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () => setState(() => _selectedReportType = 2),
            child: const Text("تقرير فترة", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _buildSalesReport() {
    final transactions = _getFilteredTransactions();
    Map<String, Map<String, double>> dailyData = {};
    Set<String> allCategories = {};
    double grandTotal = 0;
    Map<String, double> categoryTotals = {};

    for (var tx in transactions) {
      if (tx['type'] == 'وارد') {
        String date = tx['date'].toString().substring(0, 10);
        String category = tx['category'] ?? 'عام';
        double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;
        allCategories.add(category);
        dailyData.putIfAbsent(date, () => {'total': 0.0});
        dailyData[date]![category] = (dailyData[date]![category] ?? 0.0) + amount;
        dailyData[date]!['total'] = dailyData[date]!['total']! + amount;
        categoryTotals[category] = (categoryTotals[category] ?? 0.0) + amount;
        grandTotal += amount;
      }
    }

    List<String> sortedDates = dailyData.keys.toList()..sort();
    List<String> columns = allCategories.toList()..sort();

    if (dailyData.isEmpty) {
      return const Center(child: Text("لا توجد مبيعات في هذه الفترة", style: TextStyle(color: Colors.white, fontFamily: 'Cairo')));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: MaterialStateProperty.all(Colors.white.withOpacity(0.1)),
                columns: [
                  const DataColumn(label: Text('التاريخ', style: TextStyle(color: Colors.white, fontFamily: 'Cairo'))),
                  ...columns.map((c) => DataColumn(label: Text(c, style: const TextStyle(color: Colors.white, fontFamily: 'Cairo')))),
                  const DataColumn(label: Text('إجمالي اليوم', style: TextStyle(color: Colors.amber, fontFamily: 'Cairo', fontWeight: FontWeight.bold))),
                ],
                rows: sortedDates.map((date) {
                  return DataRow(
                    cells: [
                      DataCell(Text(date, style: const TextStyle(color: Colors.white70))),
                      ...columns.map((c) => DataCell(Text((dailyData[date]![c] ?? 0).toStringAsFixed(2), style: const TextStyle(color: Colors.white70)))),
                      DataCell(Text(dailyData[date]!['total']!.toStringAsFixed(2), style: const TextStyle(color: Colors.amber))),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        const Divider(color: Colors.white24),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("الإجماليات للفترة المحددة:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              const SizedBox(height: 5),
              Wrap(
                spacing: 15,
                children: columns.map((c) => Text("$c: ${categoryTotals[c]!.toStringAsFixed(2)}", style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo'))).toList(),
              ),
              const SizedBox(height: 5),
              Text("الإجمالي الكلي: ${grandTotal.toStringAsFixed(2)}", style: const TextStyle(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIncomeExpenseReport() {
    final transactions = _getFilteredTransactions();
    double totalIncome = 0; Map<String, double> safeIncomes = {};
    double totalExpenses = 0; double totalGoods = 0; Map<String, double> expenseCategories = {};

    for (var tx in transactions) {
      double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;
      if (tx['type'] == 'وارد') {
        totalIncome += amount;
        String treasury = tx['treasury'] ?? 'غير محدد';
        safeIncomes[treasury] = (safeIncomes[treasury] ?? 0.0) + amount;
      } else if (tx['type'] == 'صادر') {
        String category = tx['category'] ?? 'عام';
        totalExpenses += amount;
        expenseCategories[category] = (expenseCategories[category] ?? 0.0) + amount;
        if (category == 'بضاعة') totalGoods += amount;
      }
    }

    double netExpenses = totalExpenses - totalGoods;
    double finalBalance = totalIncome - totalExpenses;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummarySection("اجمالي الايراد", safeIncomes, totalIncome, Colors.green),
          const SizedBox(height: 15),
          _buildSummarySection("المصروفات", expenseCategories, totalExpenses, Colors.redAccent),
          const SizedBox(height: 15),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.3),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Theme.of(context).primaryColor),
            ),
            child: Column(
              children: [
                _summaryRow("إجمالي المصروفات (بدون البضاعة):", netExpenses, Colors.orangeAccent),
                const Divider(color: Colors.white24),
                _summaryRow("إجمالي المصروفات:", totalExpenses, Colors.redAccent.shade100),
                const Divider(color: Colors.white24),
                _summaryRow("الرصيد المتبقي:", finalBalance, finalBalance >= 0 ? Colors.greenAccent : Colors.redAccent, isBold: true),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildSummarySection(String title, Map<String, double> items, double total, Color titleColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: titleColor, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          const Divider(color: Colors.white10),
          ...items.entries.map((e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(e.key, style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo')),
                Text(e.value.toStringAsFixed(2), style: const TextStyle(color: Colors.white, fontFamily: 'Cairo')),
              ],
            ),
          )),
          const Divider(color: Colors.white10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("الإجمالي", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              Text(total.toStringAsFixed(2), style: TextStyle(color: titleColor, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, double amount, Color color, {bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.white, fontSize: isBold ? 16 : 14, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, fontFamily: 'Cairo')),
        Text(amount.toStringAsFixed(2), style: TextStyle(color: color, fontSize: isBold ? 18 : 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
      ],
    );
  }
}