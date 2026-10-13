// import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:universal_html/html.dart' as html;
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';
import '../../services/export_service.dart';
import '../../services/stock_balance_service.dart';

class ReportsPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final int initialReportType;

  const ReportsPage({super.key, required this.companyCode, this.selectedBranchCode, this.initialReportType = 1});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();
  int _selectedReportType = 1;
  Map<String, dynamic> _extendedSummary = {};
  List<Map<String, dynamic>> _extendedSupplierBalances = [];
  double _extendedInventoryValue = 0.0;

  Map<String, double> _incomeDetails = {};
  Map<String, double> _expenseDetails = {};

  double _expensesWithoutGoods = 0.0;
  double _expensesWithoutGoodsAndProfit = 0.0;

  @override
  void initState() {
    super.initState();
    _selectedReportType = widget.initialReportType;
    _setDefaultReportType();
    _calculateExtendedReport();
  }

  void _setDefaultReportType() {
    if (widget.initialReportType == 1 && PermissionsService().canViewReportsSales) {
      _selectedReportType = 1;
      return;
    }
    if (widget.initialReportType == 2 && PermissionsService().canViewReportsPeriod) {
      _selectedReportType = 2;
      return;
    }
    if (widget.initialReportType == 3 && PermissionsService().canViewExtendedReport && PermissionsService().canViewReportsPeriod) {
      _selectedReportType = 3;
      return;
    }
    if (PermissionsService().canViewReportsSales) {
      _selectedReportType = 1;
    } else if (PermissionsService().canViewReportsPeriod) {
      _selectedReportType = 2;
    } else {
      _selectedReportType = 1;
    }
  }

  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    final Box codingBox = Hive.box('coding_box');
    final rawData = codingBox.get("${widget.companyCode}_branches", defaultValue: []);
    for (var item in rawData) {
      if (item['code']?.toString() == code) return item['name']?.toString() ?? "فرع غير معروف";
    }
    return "فرع غير معروف";
  }

  Future<String> _getCompanyName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString('company_name');
      if (name != null && name.isNotEmpty) return name;
    } catch (e) {
      // ignore
    }
    final Box codingBox = Hive.box('coding_box');
    final companyData = codingBox.get("${widget.companyCode}_company");
    if (companyData is Map) {
      final name = companyData['name']?.toString() ??
          companyData['company_name']?.toString() ??
          companyData['companyName']?.toString();
      if (name != null && name.isNotEmpty) return name;
    }
    final directName = codingBox.get("${widget.companyCode}_name")?.toString() ??
        codingBox.get("${widget.companyCode}_companyName")?.toString();
    if (directName != null && directName.isNotEmpty) return directName;
    final companiesList = codingBox.get('companies');
    if (companiesList is List) {
      for (var company in companiesList) {
        if (company is Map) {
          final code = company['code']?.toString();
          if (code == widget.companyCode) {
            final name = company['name']?.toString() ??
                company['company_name']?.toString() ??
                company['companyName']?.toString();
            if (name != null && name.isNotEmpty) return name;
          }
        }
      }
    }
    final companyList2 = codingBox.get('company_list');
    if (companyList2 is List) {
      for (var company in companyList2) {
        if (company is Map) {
          final code = company['code']?.toString();
          if (code == widget.companyCode) {
            final name = company['name']?.toString() ??
                company['company_name']?.toString() ??
                company['companyName']?.toString();
            if (name != null && name.isNotEmpty) return name;
          }
        }
      }
    }
    return widget.companyCode;
  }

  String _formatNumber(double value) {
    return NumberFormat('#,##0.00', 'en_US').format(value);
  }

  List<Map<dynamic, dynamic>> _getFilteredTransactions() {
    final box = Hive.box('daily_transactions_box');
    return box.values.where((tx) {
      if (tx['company_code'] != widget.companyCode) return false;
      if (tx['category'] == 'transfer_hidden') return false;
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
    if (!PermissionsService().canShareReports) {
      _showErrorSnackBar("ليس لديك صلاحية لتصدير التقارير");
      return;
    }
    if (_selectedReportType == 3) {
      await _exportExtendedExcel();
      return;
    }
    final transactions = _getFilteredTransactions();
    if (transactions.isEmpty) return _showEmptySheetRow();

    try {
      var excel = excel_lib.Excel.createExcel();
      String defaultSheet = excel.tables.keys.first;
      excel.rename(defaultSheet, 'التقرير المفلتر');
      excel_lib.Sheet sheetObject = excel['التقرير المفلتر'];

      String branchName = _getBranchName(widget.selectedBranchCode);
      String dateStr = "من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}";

      sheetObject.appendRow([excel_lib.TextCellValue(_selectedReportType == 1 ? "تقرير المبيعات" : "تقرير الفترة")]);
      sheetObject.appendRow([excel_lib.TextCellValue("الفرع: $branchName")]);
      sheetObject.appendRow([excel_lib.TextCellValue("الفترة: $dateStr")]);
      sheetObject.appendRow([]);

      if (_selectedReportType == 1) {
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

        List<String> headers = ['التاريخ', ...categories, 'الإجمالي اليومي'];
        sheetObject.appendRow(headers.map((h) => excel_lib.TextCellValue(h)).toList());

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
        sheetObject.appendRow([excel_lib.TextCellValue("المتوسط اليومي"), excel_lib.DoubleCellValue(dailyData.isEmpty ? 0 : grandTotal / dailyData.length)]);
      } else if (_selectedReportType == 2) {
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
    if (!PermissionsService().canShareReports) {
      _showErrorSnackBar("ليس لديك صلاحية لتصدير التقارير");
      return;
    }
    if (_selectedReportType == 1) {
      await _exportSalesPdf();
      return;
    }
    if (_selectedReportType == 3) {
      await _exportExtendedPdf();
      return;
    }
    final transactions = _getFilteredTransactions();
    if (transactions.isEmpty) return _showEmptySheetRow();

    try {
      final pdf = pw.Document();
      var arabicFont = pw.Font.ttf(await rootBundle.load("assets/fonts/Cairo-Regular.ttf"));
      String companyName = await _getCompanyName();

      String branchName = _getBranchName(widget.selectedBranchCode);
      String dateStr = "من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}";
      final primaryColor = PdfColor.fromHex('#050F4C');
      final accentColor = PdfColor.fromHex('#3062F8');

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
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
                      companyName,
                      style: pw.TextStyle(font: arabicFont, fontSize: 18, color: PdfColors.white, fontWeight: pw.FontWeight.bold),
                    ),
                    pw.SizedBox(height: 5),
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
              if (_selectedReportType == 1)
                _buildPdfSalesReportStructure(transactions, arabicFont, primaryColor, companyName)
              else
                ..._buildPdfFinanceReportStructure(transactions, arabicFont, primaryColor, accentColor, companyName),
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

  // ===== دوال التصدير للتقرير الموسع (المعدلة) =====
  Future<void> _exportExtendedExcel() async {
    if (_extendedSummary.isEmpty) await _calculateExtendedReport();

    List<Map<String, dynamic>> detailRows = [];

    detailRows.add({'البند': '--- الإيرادات ---', 'القيمة': ''});
    _incomeDetails.forEach((key, value) {
      detailRows.add({'البند': key, 'القيمة': value});
    });

    detailRows.add({'البند': '--- المصروفات ---', 'القيمة': ''});
    _expenseDetails.forEach((key, value) {
      detailRows.add({'البند': key, 'القيمة': value});
    });

    Map<String, dynamic> summaryMap = {
      ..._extendedSummary,
    };

    String companyName = await _getCompanyName();

    await ExportService.exportToExcel(
      detailRows,
      'التقرير المالي الموسع',
      const ['البند', 'القيمة'],
      const ['البند', 'القيمة'],
      companyName: companyName,
      branchName: _getBranchName(widget.selectedBranchCode),
      period: 'من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}',
      summary: summaryMap,
    );
  }

  Future<void> _exportExtendedPdf() async {
    if (_extendedSummary.isEmpty) await _calculateExtendedReport();
    if (_extendedSummary.isEmpty) {
      _showEmptySheetRow();
      return;
    }

    try {
      final pdf = pw.Document();
      final font = pw.Font.ttf(await rootBundle.load("assets/fonts/Cairo-Regular.ttf"));
      final primaryColor = PdfColor.fromHex('#050F4C');
      final accentColor = PdfColor.fromHex('#3062F8');

      String companyName = await _getCompanyName();
      String branchName = _getBranchName(widget.selectedBranchCode);
      String period = 'من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}';

      final incomeTotal = _incomeDetails.values.fold<double>(0.0, (s, v) => s + v);
      final expenseTotal = _expenseDetails.values.fold<double>(0.0, (s, v) => s + v);
      final supplierTotal = _extendedSupplierBalances.fold<double>(0.0, (s, e) => s + (e['الرصيد'] as double));

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          theme: pw.ThemeData.withFont(base: font),
          textDirection: pw.TextDirection.rtl,
          build: (context) => [
            // ===== Header =====
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
                  pw.Text(companyName,
                      style: pw.TextStyle(font: font, fontSize: 18,
                          color: PdfColors.white, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 5),
                  pw.Text('التقرير المالي الموسع',
                      style: pw.TextStyle(font: font, fontSize: 18,
                          color: PdfColors.amber, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 5),
                  pw.Text('الفرع: $branchName',
                      style: pw.TextStyle(font: font, fontSize: 12, color: PdfColors.white)),
                  pw.Text('الفترة: $period',
                      style: pw.TextStyle(font: font, fontSize: 11,
                          color: const PdfColor(1, 1, 1, 0.8))),
                ],
              ),
            ),
            pw.SizedBox(height: 15),

            // ===== 1. تفاصيل الإيرادات =====
            if (_incomeDetails.isNotEmpty)
              ..._pdfKeyValueTable(
                title: 'تفاصيل الإيرادات',
                items: _incomeDetails,
                font: font,
                titleColor: PdfColors.green700,
                total: incomeTotal,
              ),

            // ===== 2. تفاصيل المصروفات =====
            if (_expenseDetails.isNotEmpty)
              ..._pdfKeyValueTable(
                title: 'تفاصيل المصروفات',
                items: _expenseDetails,
                font: font,
                titleColor: PdfColors.red700,
                total: expenseTotal,
              ),

            // ===== 3. الإجمالي المالي =====
            ..._pdfKeyValueTable(
              title: 'الإجمالي المالي',
              items: {
                'الإيراد': _extendedSummary['إجمالي الإيراد'] as double,
                'المصروفات': _extendedSummary['المصروفات'] as double,
                'الرصيد المتبقي': _extendedSummary['الرصيد المتبقي'] as double,
                'إجمالي المصروفات (بدون بضاعة)': _expensesWithoutGoods,
                'إجمالي المصروفات (بدون بضاعة وأرباح)': _expensesWithoutGoodsAndProfit,
              },
              font: font,
              titleColor: PdfColors.blue700,
              showTotal: false,
            ),

            // ===== 4. الأصول المملوكة للشركة =====
            ..._pdfKeyValueTable(
              title: 'الأصول المملوكة للشركة',
              items: {
                'الجرد الفعلي بسعر الجملة': _extendedSummary['الجرد الفعلي بسعر الجملة'] as double,
                'رصيد الخزينة': _extendedSummary['الرصيد المتبقي'] as double,
                'أرصدة العملاء غير المحصلة': _extendedSummary['أرصدة العملاء غير المحصلة'] as double,
              },
              font: font,
              titleColor: PdfColors.teal700,
              total: _extendedSummary['إجمالي ملك الشركة'] as double,
            ),

            // ===== 5. مديونيات الموردين =====
            if (_extendedSupplierBalances.isNotEmpty) ...[
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: pw.BoxDecoration(
                  color: PdfColors.deepOrange700,
                  borderRadius: const pw.BorderRadius.only(
                      topLeft: pw.Radius.circular(6),
                      topRight: pw.Radius.circular(6)),
                ),
                child: pw.Text('مديونيات الموردين',
                    style: pw.TextStyle(font: font, fontSize: 12,
                        fontWeight: pw.FontWeight.bold, color: PdfColors.white),
                    textAlign: pw.TextAlign.right,
                    textDirection: pw.TextDirection.rtl),
              ),
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: PdfColors.deepOrange700),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('المورد',
                            style: pw.TextStyle(font: font, color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold, fontSize: 11),
                            textAlign: pw.TextAlign.center),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('الرصيد',
                            style: pw.TextStyle(font: font, color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold, fontSize: 11),
                            textAlign: pw.TextAlign.center),
                      ),
                    ],
                  ),
                  ..._extendedSupplierBalances.map((e) => pw.TableRow(children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(5),
                      child: pw.Text(e['المورد'].toString(),
                          style: pw.TextStyle(font: font, fontSize: 10),
                          textAlign: pw.TextAlign.right,
                          textDirection: pw.TextDirection.rtl),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(5),
                      child: pw.Text(_formatNumber(e['الرصيد'] as double),
                          style: pw.TextStyle(font: font, fontSize: 10),
                          textAlign: pw.TextAlign.center),
                    ),
                  ])),
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('الإجمالي',
                            style: pw.TextStyle(font: font, fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.deepOrange700),
                            textAlign: pw.TextAlign.right,
                            textDirection: pw.TextDirection.rtl),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text(_formatNumber(supplierTotal),
                            style: pw.TextStyle(font: font, fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.deepOrange700),
                            textAlign: pw.TextAlign.center),
                      ),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 10),
            ],

            // ===== 6. الملخص النهائي =====
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.blue50,
                borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: accentColor, width: 0.8),
              ),
              child: pw.Column(
                children: [
                  _pdfSummaryRow('إجمالي المدين / ملك الشركة:',
                      _extendedSummary['إجمالي ملك الشركة'] as double, PdfColors.cyan, font),
                  pw.Divider(color: PdfColors.grey300),
                  _pdfSummaryRow('إجمالي الدائن / على الشركة:',
                      _extendedSummary['إجمالي ما على الشركة'] as double, PdfColors.red, font),
                  pw.Divider(color: PdfColors.grey300),
                  _pdfSummaryRow('صافي الجرد الحالي:',
                      _extendedSummary['صافي الجرد الحالي'] as double,
                      PdfColors.amber, font, isBold: true),
                  _pdfSummaryRow('صافي الجرد السابق:',
                      _extendedSummary['صافي الجرد السابق'] as double,
                      PdfColors.grey700, font),
                  _pdfSummaryRow('الفرق / صافي الأرباح:',
                      _extendedSummary['الفرق / صافي الأرباح'] as double,
                      PdfColors.green, font, isBold: true),
                  _pdfSummaryRow('المتبقي بعد توزيع الأرباح:',
                      _extendedSummary['المتبقي بعد توزيع الأرباح'] as double,
                      PdfColors.blue, font),
                  _pdfSummaryRow('نسبة الربح:',
                      _extendedSummary['نسبة الربح'] as double,
                      PdfColors.deepPurple, font, isBold: true, suffix: '%'),
                ],
              ),
            ),
          ],
        ),
      );

      final pdfBytes = await pdf.save();
      String fileName = "التقرير_الموسع_${DateTime.now().millisecondsSinceEpoch}.pdf";

      if (kIsWeb) {
        final blob = html.Blob([pdfBytes], 'application/pdf');
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute("download", fileName)
          ..click();
        html.Url.revokeObjectUrl(url);
      } else {
        final xFile = XFile.fromData(pdfBytes,
            mimeType: 'application/pdf', name: fileName);
        await Share.shareXFiles([xFile], text: "مرفق لكم التقرير الموسع PDF");
      }
    } catch (e) {
      _showErrorSnackBar("فشل تصدير PDF: $e");
    }
  }

  void _showShareBottomSheet() {
    if (!PermissionsService().canShareReports) {
      _showErrorSnackBar("ليس لديك صلاحية لمشاركة التقارير");
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.sheetBackground(context),
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
                  style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textMainFor(context), fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildShareOptionItem(
                      icon: Icons.table_chart,
                      color: AppTheme.successFor(context),
                      label: "ملف Excel",
                      onTap: () { Navigator.pop(context); _shareAsExcel(); }
                    ),
                    _buildShareOptionItem(
                      icon: Icons.picture_as_pdf,
                      color: AppTheme.dangerFor(context),
                      label: "تقرير PDF ملون",
                      onTap: () { Navigator.pop(context); _shareAsPdf(); }
                    ),
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
          color: GlassStyle.fill05For(context),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 12, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Future<void> _exportSalesPdf() async {
    final transactions = _getFilteredTransactions();
    if (transactions.isEmpty) {
      _showEmptySheetRow();
      return;
    }

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

    List<Map<String, dynamic>> rows = [];
    for (var date in sortedDates) {
      Map<String, dynamic> row = {'التاريخ': date};
      for (var cat in columns) {
        row[cat] = dailyData[date]![cat] ?? 0.0;
      }
      row['الإجمالي اليومي'] = dailyData[date]!['total']!;
      rows.add(row);
    }

    Map<String, double> categoryTotals = {};
    for (var date in sortedDates) {
      for (var cat in columns) {
        categoryTotals[cat] = (categoryTotals[cat] ?? 0.0) + (dailyData[date]![cat] ?? 0.0);
      }
    }
    double grandTotal = categoryTotals.values.fold(0.0, (sum, v) => sum + v);
    double average = rows.isEmpty ? 0 : grandTotal / rows.length;

    Map<String, dynamic> summary = {
      'إجمالي الفئات': '',
      ...categoryTotals,
      'الإجمالي الكلي': grandTotal,
      'المتوسط اليومي': average,
    };

    String companyName = await _getCompanyName();
    String branchName = _getBranchName(widget.selectedBranchCode);
    String period = 'من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}';

    List<String> headers = ['التاريخ', ...columns, 'الإجمالي اليومي'];

    await ExportService.exportToPDF(
      data: rows,
      title: 'تقرير المبيعات التفصيلي',
      headers: headers,
      keys: headers,
      companyName: companyName,
      branchName: branchName,
      period: period,
      summary: summary,
      totalAmount: grandTotal,
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
              primary: AppTheme.datePickerPrimary,
              onPrimary: AppTheme.datePickerOnPrimary,
              surface: AppTheme.datePickerSurface,
              onSurface: AppTheme.datePickerOnSurface,
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
      if (_selectedReportType == 3) {
        _calculateExtendedReport();
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    bool canSales = PermissionsService().canViewReportsSales;
    bool canPeriod = PermissionsService().canViewReportsPeriod;

    if (_selectedReportType == 1 && !canSales) {
      if (canPeriod) {
        _selectedReportType = 2;
      }
    } else if (_selectedReportType == 2 && !canPeriod) {
      if (canSales) {
        _selectedReportType = 1;
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.appBarBgTint,
        elevation: 0,
        actions: [
          if (PermissionsService().canShareReports)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
              child: Container(
                decoration: BoxDecoration(
                  color: GlassStyle.fill12For(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: GlassStyle.accentBorder40For(context)),
                ),
                child: IconButton(
                  icon: Icon(Icons.share, color: AppTheme.accentFor(context), size: 22),
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
                color: GlassStyle.accentFill10For(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                "فرع: ${_getBranchName(widget.selectedBranchCode)}",
                style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppTheme.accentFor(context)),
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
            colors: AppTheme.dashGradientBlue(context),
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
                    child: (!canSales && !canPeriod)
                        ? Center(
                            child: Text(
                              'لا توجد تقارير متاحة لك',
                              style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo', fontSize: 16),
                            ),
                          )
                        : _selectedReportType == 1
                            ? _buildSalesReport()
                            : _selectedReportType == 2
                                ? _buildIncomeExpenseReport()
                                : _buildExtendedReport(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // تقرير المبيعات PDF (كما هو - لم يتغير)
  // ============================================================
  pw.Widget _buildPdfSalesReportStructure(
    List<Map<dynamic, dynamic>> transactions,
    pw.Font font,
    PdfColor primaryColor,
    String companyName,
  ) {
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

    Map<String, double> categoryTotals = {};
    for (var date in sortedDates) {
      for (var cat in columns) {
        categoryTotals[cat] = (categoryTotals[cat] ?? 0.0) + (dailyData[date]![cat] ?? 0.0);
      }
    }
    double grandTotal = categoryTotals.values.fold(0.0, (sum, v) => sum + v);

    List<pw.TableRow> rows = [];

    // ---------- رأس الجدول ----------
    rows.add(
      pw.TableRow(
        decoration: pw.BoxDecoration(color: primaryColor),
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.all(6),
            child: pw.Text(
              "التاريخ",
              style: pw.TextStyle(font: font, color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 11),
              textAlign: pw.TextAlign.center,
            ),
          ),
          ...columns.map((c) => pw.Padding(
                padding: const pw.EdgeInsets.all(6),
                child: pw.Text(
                  c,
                  style: pw.TextStyle(font: font, color: PdfColors.white, fontSize: 11, fontWeight: pw.FontWeight.bold),
                  textAlign: pw.TextAlign.center,
                ),
              )),
          pw.Padding(
            padding: const pw.EdgeInsets.all(6),
            child: pw.Text(
              "الإجمالي",
              style: pw.TextStyle(font: font, color: PdfColors.amber, fontWeight: pw.FontWeight.bold, fontSize: 11),
              textAlign: pw.TextAlign.center,
            ),
          ),
        ],
      ),
    );

    // ---------- صفوف البيانات ----------
    for (var date in sortedDates) {
      List<pw.Widget> cells = [];
      cells.add(pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(
          date,
          style: pw.TextStyle(font: font, fontSize: 10),
          textAlign: pw.TextAlign.center,
        ),
      ));
      for (var cat in columns) {
        double val = dailyData[date]![cat] ?? 0.0;
        cells.add(pw.Padding(
          padding: const pw.EdgeInsets.all(5),
          child: pw.Text(
            _formatNumber(val),
            style: pw.TextStyle(font: font, fontSize: 10),
            textAlign: pw.TextAlign.center,
          ),
        ));
      }
      cells.add(pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(
          _formatNumber(dailyData[date]!['total']!),
          style: pw.TextStyle(font: font, fontSize: 10, fontWeight: pw.FontWeight.bold),
          textAlign: pw.TextAlign.center,
        ),
      ));
      rows.add(pw.TableRow(children: cells));
    }

    // ---------- إجمالي الفئات ----------
    List<pw.Widget> totalCells = [];
    totalCells.add(pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        "إجمالي الفئات",
        style: pw.TextStyle(font: font, fontSize: 11, fontWeight: pw.FontWeight.bold, color: primaryColor),
        textAlign: pw.TextAlign.center,
      ),
    ));
    for (var cat in columns) {
      totalCells.add(pw.Padding(
        padding: const pw.EdgeInsets.all(6),
        child: pw.Text(
          _formatNumber(categoryTotals[cat] ?? 0.0),
          style: pw.TextStyle(font: font, fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.blue800),
          textAlign: pw.TextAlign.center,
        ),
      ));
    }
    totalCells.add(pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        _formatNumber(grandTotal),
        style: pw.TextStyle(font: font, fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.amber),
        textAlign: pw.TextAlign.center,
      ),
    ));
    rows.add(pw.TableRow(
      decoration: pw.BoxDecoration(color: PdfColors.grey100),
      children: totalCells,
    ));

    // ---------- الإجمالي الكلي ----------
    List<pw.Widget> grandCells = [];
    grandCells.add(pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        "الإجمالي الكلي",
        style: pw.TextStyle(font: font, fontSize: 12, fontWeight: pw.FontWeight.bold, color: primaryColor),
        textAlign: pw.TextAlign.center,
      ),
    ));
    for (var i = 0; i < columns.length; i++) {
      grandCells.add(pw.Padding(
        padding: const pw.EdgeInsets.all(6),
        child: pw.Text("", style: pw.TextStyle(font: font, fontSize: 12)),
      ));
    }
    grandCells.add(pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        _formatNumber(grandTotal),
        style: pw.TextStyle(font: font, fontSize: 13, fontWeight: pw.FontWeight.bold, color: primaryColor),
        textAlign: pw.TextAlign.center,
      ),
    ));
    rows.add(pw.TableRow(children: grandCells));

    // ---------- الإخراج النهائي ----------
    return pw.Column(children: [
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        children: rows,
      ),
      pw.SizedBox(height: 8),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          _pdfSummaryRow("الإجمالي الكلي:", grandTotal, PdfColors.amber, font, isBold: true),
          _pdfSummaryRow("المتوسط اليومي:", dailyData.isEmpty ? 0 : grandTotal / dailyData.length, PdfColors.cyan, font),
        ],
      ),
    ]);
  }

  // ============================================================
  // تقرير الفترة PDF - يعرض نفس ما على الشاشة
  // ============================================================
  List<pw.Widget> _buildPdfFinanceReportStructure(
    List<Map<dynamic, dynamic>> transactions,
    pw.Font font,
    PdfColor primaryColor,
    PdfColor accentColor,
    String companyName,
  ) {
    double totalIncome = 0, totalExpenses = 0, totalGoods = 0;
    final incomeByTreasury = <String, double>{};
    final expenseByCategory = <String, double>{};

    for (var tx in transactions) {
      double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;
      if (tx['type'] == 'وارد') {
        totalIncome += amount;
        final treasury = tx['treasury']?.toString() ?? 'غير محدد';
        incomeByTreasury[treasury] = (incomeByTreasury[treasury] ?? 0) + amount;
      } else if (tx['type'] == 'صادر') {
        totalExpenses += amount;
        final cat = tx['category']?.toString() ?? 'عام';
        expenseByCategory[cat] = (expenseByCategory[cat] ?? 0) + amount;
        if (cat == 'بضاعة') totalGoods += amount;
      }
    }

    double netExpenses = totalExpenses - totalGoods;
    double finalBalance = totalIncome - totalExpenses;

    return [
      // جدول الإيرادات
      ..._pdfKeyValueTable(
        title: 'إجمالي الإيرادات',
        items: incomeByTreasury,
        font: font,
        titleColor: PdfColors.green700,
        total: totalIncome,
      ),
      // جدول المصروفات
      ..._pdfKeyValueTable(
        title: 'المصروفات',
        items: expenseByCategory,
        font: font,
        titleColor: PdfColors.red700,
        total: totalExpenses,
      ),
      // الملخص النهائي
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: PdfColors.blue50,
          borderRadius: pw.BorderRadius.circular(8),
          border: pw.Border.all(color: accentColor, width: 0.8),
        ),
        child: pw.Column(
          children: [
            _pdfSummaryRow("إجمالي المصروفات (بدون البضاعة):",
                netExpenses, PdfColors.orange, font),
            pw.Divider(color: PdfColors.grey300),
            _pdfSummaryRow("إجمالي المصروفات:",
                totalExpenses, PdfColors.red, font),
            pw.Divider(color: PdfColors.grey300),
            _pdfSummaryRow(
              "الرصيد المتبقي:",
              finalBalance,
              finalBalance >= 0 ? PdfColors.green : PdfColors.red,
              font,
              isBold: true,
            ),
          ],
        ),
      ),
    ];
  }

  // ============================================================
  // جدول بند/قيمة قابلة للانقسام بين الصفحات (مع تكرار الرأس)
  // ============================================================
  List<pw.Widget> _pdfKeyValueTable({
    required String title,
    required Map<String, double> items,
    required pw.Font font,
    required PdfColor titleColor,
    double? total,
    String totalLabel = 'الإجمالي',
    bool showTotal = true,
  }) {
    // تجهيز البيانات كقائمة صفوف
    final List<List<String>> data = [];
    items.forEach((key, value) {
      data.add([key, _formatNumber(value)]);
    });
    if (showTotal && total != null) {
      data.add([totalLabel, _formatNumber(total)]);
    }

    return [
      // 1) العنوان قطعة مستقلة
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: pw.BoxDecoration(
          color: titleColor,
          borderRadius: const pw.BorderRadius.only(
              topLeft: pw.Radius.circular(6),
              topRight: pw.Radius.circular(6)),
        ),
        child: pw.Text(title,
            style: pw.TextStyle(font: font, fontSize: 12,
                fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            textAlign: pw.TextAlign.right,
            textDirection: pw.TextDirection.rtl),
      ),
      // 2) الجدول قابل للانقسام بين الصفحات مع تكرار الرأس
      pw.TableHelper.fromTextArray(
        headers: const ['البند', 'القيمة'],
        data: data,
        headerCount: 1,
        headerStyle: pw.TextStyle(
          font: font,
          color: PdfColors.white,
          fontWeight: pw.FontWeight.bold,
          fontSize: 11,
        ),
        headerDecoration: pw.BoxDecoration(color: titleColor),
        cellStyle: pw.TextStyle(font: font, fontSize: 10),
        cellAlignments: {
          0: pw.Alignment.centerRight,
          1: pw.Alignment.center,
        },
        cellDecoration: (index, data, rowNum) {
          // تلوين آخر صف (الإجمالي) فقط
          if (showTotal && total != null && rowNum == data.length - 1) {
            return pw.BoxDecoration(color: PdfColors.grey200);
          }
          return const pw.BoxDecoration();
        },
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      ),
      // 3) مسافة بعد الجدول
      pw.SizedBox(height: 12),
    ];
  }

  pw.Widget _pdfSummaryRow(
    String label,
    double val,
    PdfColor col,
    pw.Font font, {
    bool isBold = false,
    String suffix = '',
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              font: font,
              fontSize: isBold ? 14 : 12,
              fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
          pw.Text(
            '${_formatNumber(val)}$suffix',
            style: pw.TextStyle(
              font: font,
              fontSize: isBold ? 15 : 13,
              color: col,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  void _showEmptySheetRow() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("لا توجد بيانات للفترة المحددة لتصديرها")));
  void _showErrorSnackBar(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, textAlign: TextAlign.center), backgroundColor: AppTheme.dangerStrongFor(context)));

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
          color: GlassStyle.fill05For(context),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: GlassStyle.line20For(context)),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(color: AppTheme.textSoftFor(context), fontSize: 12, fontFamily: 'Cairo')),
            const SizedBox(height: 4),
            Text(DateFormat('yyyy-MM-dd').format(date), style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildReportTypeSelector() {
    final buttons = <Widget>[];
    if (PermissionsService().canViewReportsSales) {
      buttons.add(_reportButton(1, 'المبيعات'));
    }
    if (PermissionsService().canViewReportsPeriod) {
      buttons.add(_reportButton(2, 'تقرير الفترة'));
    }
    if (PermissionsService().canViewExtendedReport && PermissionsService().canViewReportsPeriod) {
      buttons.add(_reportButton(3, 'صافي الجرد الحالي'));
    }
    if (buttons.isEmpty) {
      return Center(
        child: Text(
          'ليس لديك صلاحية لعرض أي تقرير',
          style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo'),
        ),
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _reportButton(int type, String label) => ElevatedButton(
    style: ElevatedButton.styleFrom(
      backgroundColor: _selectedReportType == type ? Theme.of(context).primaryColor : GlassStyle.fill10For(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
    ),
    onPressed: () { setState(() => _selectedReportType = type); if (type == 3) _calculateExtendedReport(); },
    child: Text(label, style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
  );

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
      return Center(child: Text("لا توجد مبيعات في هذه الفترة", style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo')));
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
                headingRowColor: MaterialStateProperty.all(GlassStyle.fill10For(context)),
                columns: [
                  DataColumn(label: Text('التاريخ', style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo'))),
                  ...columns.map((c) => DataColumn(label: Text(c, style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo')))),
                  DataColumn(label: Text('إجمالي اليوم', style: TextStyle(color: AppTheme.warningFor(context), fontFamily: 'Cairo', fontWeight: FontWeight.bold))),
                ],
                rows: sortedDates.map((date) {
                  return DataRow(
                    cells: [
                      DataCell(Text(date, style: TextStyle(color: AppTheme.textSoftFor(context)))),
                      ...columns.map((c) => DataCell(Text(_formatNumber(dailyData[date]![c] ?? 0), style: TextStyle(color: AppTheme.textSoftFor(context))))),
                      DataCell(Text(_formatNumber(dailyData[date]!['total']!), style: TextStyle(color: AppTheme.warningFor(context)))),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        Divider(color: GlassStyle.line24For(context)),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: GlassStyle.fill05For(context), borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("الإجماليات للفترة المحددة:", style: TextStyle(color: AppTheme.textMainFor(context), fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              const SizedBox(height: 5),
              Wrap(
                spacing: 15,
                children: columns.map((c) => Text("$c: ${_formatNumber(categoryTotals[c]!)}", style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo'))).toList(),
              ),
              const SizedBox(height: 5),
              Text("الإجمالي الكلي: ${_formatNumber(grandTotal)}", style: TextStyle(color: AppTheme.warningFor(context), fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              Text("المتوسط اليومي: ${_formatNumber(grandTotal / sortedDates.length)}", style: TextStyle(color: AppTheme.accentFor(context), fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
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
          _buildSummarySection("اجمالي الايراد", safeIncomes, totalIncome, AppTheme.successStrongFor(context), showTotal: false),
          const SizedBox(height: 15),
          _buildSummarySection("المصروفات", expenseCategories, totalExpenses, AppTheme.dangerFor(context), showTotal: false),
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
                _summaryRow("إجمالي المصروفات (بدون البضاعة):", netExpenses, AppTheme.warningOrangeSoftFor(context)),
                Divider(color: GlassStyle.line24For(context)),
                _summaryRow("إجمالي المصروفات:", totalExpenses, AppTheme.dangerSoftFor(context)),
                Divider(color: GlassStyle.line24For(context)),
                _summaryRow("الرصيد المتبقي:", finalBalance, finalBalance >= 0 ? AppTheme.successFor(context) : AppTheme.dangerFor(context), isBold: true),
              ],
            ),
          )
        ],
      ),
    );
  }

  Future<void> _calculateExtendedReport() async {
    final box = Hive.box('daily_transactions_box');
    final from = DateTime(_fromDate.year, _fromDate.month, _fromDate.day);
    final to = DateTime(_toDate.year, _toDate.month, _toDate.day);
    double income = 0, expenses = 0, goods = 0, previousIncome = 0, previousExpenses = 0;
    final expenseByCategory = <String, double>{};
    final incomeByTreasury = <String, double>{};

    for (final raw in box.values) {
      if (raw is! Map || raw['company_code']?.toString() != widget.companyCode || raw['category'] == 'transfer_hidden') continue;
      if (widget.selectedBranchCode != null && widget.selectedBranchCode != 'all' && raw['branch_code']?.toString() != widget.selectedBranchCode) continue;
      final d = DateTime.tryParse(raw['date']?.toString().substring(0, 10) ?? '');
      if (d == null || d.isAfter(to)) continue;
      final amount = double.tryParse(raw['amount']?.toString() ?? '0') ?? 0;
      if (d.isBefore(from)) {
        if (raw['type'] == 'وارد') previousIncome += amount;
        if (raw['type'] == 'صادر') previousExpenses += amount;
        continue;
      }
      if (raw['type'] == 'وارد') {
        income += amount;
        final treasury = raw['treasury']?.toString() ?? 'غير محدد';
        incomeByTreasury[treasury] = (incomeByTreasury[treasury] ?? 0) + amount;
      }
      if (raw['type'] == 'صادر') {
        expenses += amount;
        final cat = raw['category']?.toString() ?? 'عام';
        expenseByCategory[cat] = (expenseByCategory[cat] ?? 0) + amount;
        if (cat == 'بضاعة') goods += amount;
      }
    }

    final currentCash = income - expenses;
    final previousCash = previousIncome - previousExpenses;
    _extendedSupplierBalances = await _getExtendedSupplierBalances(to);
    _extendedInventoryValue = await _getTotalInventoryWholesale(to);
    final previousSupplierBalances = await _getExtendedSupplierBalances(from.subtract(const Duration(days: 1)));
    final supplierTotal = _extendedSupplierBalances.fold<double>(0, (s, e) => s + (e['الرصيد'] as double));
    final previousSupplierTotal = previousSupplierBalances.fold<double>(0, (s, e) => s + (e['الرصيد'] as double));
    final customerTotal = 0.0;
    final totalDebit = _extendedInventoryValue + currentCash + customerTotal;
    final totalCredit = supplierTotal;
    final currentNet = totalDebit - totalCredit;
    final previousInventoryValue = await _getTotalInventoryWholesale(from.subtract(const Duration(days: 1)));
    final previousNet = previousInventoryValue + previousCash - previousSupplierTotal;
    final netProfit = currentNet - previousNet;
    final profitDistributed = expenseByCategory['ارباح'] ?? expenseByCategory['أرباح'] ?? 0.0;
    final remainingAfterProfit = netProfit - profitDistributed;

    final expensesWithoutGoods = expenses - goods;
    final expensesWithoutGoodsAndProfit = expensesWithoutGoods - profitDistributed;

    final profitRatio = income == 0 ? 0.0 : ((netProfit + expensesWithoutGoodsAndProfit) / income) * 100;

    if (!mounted) return;
    setState(() {
      _incomeDetails = {
        'الرصيد السابق': previousCash,
        ...incomeByTreasury,
      };
      _expenseDetails = expenseByCategory;

      _expensesWithoutGoods = expensesWithoutGoods;
      _expensesWithoutGoodsAndProfit = expensesWithoutGoodsAndProfit;

      _extendedSummary = {
        'إجمالي الإيراد': income,
        'المصروفات': expenses,
        'الرصيد المتبقي': currentCash,
        'الجرد الفعلي بسعر الجملة': _extendedInventoryValue,
        'أرصدة العملاء غير المحصلة': customerTotal,
        'إجمالي ملك الشركة': totalDebit,
        'إجمالي ما على الشركة': totalCredit,
        'صافي الجرد الحالي': currentNet,
        'صافي الجرد السابق': previousNet,
        'الفرق / صافي الأرباح': netProfit,
        'المتبقي بعد توزيع الأرباح': remainingAfterProfit,
        'نسبة الربح': profitRatio,
      };
    });
  }

  Future<List<Map<String, dynamic>>> _getExtendedSupplierBalances(DateTime to) async {
    final coding = Hive.box('coding_box').get('${widget.companyCode}_suppliers', defaultValue: []);
    final names = <String>{};
    if (coding is List) {
      for (final x in coding.whereType<Map>()) {
        final n = x['name']?.toString() ?? '';
        if (n.isNotEmpty) names.add(n);
      }
    }
    final result = <Map<String, dynamic>>[];
    final purchases = Hive.box('supplier_box');
    final settlements = Hive.box('supplier_settlement_box');
    final totals = <String, double>{};
    for (final rawList in purchases.values) {
      if (rawList is! List) continue;
      for (final raw in rawList.whereType<Map>()) {
        if (raw['is_deleted'] == true || raw['company_code']?.toString() != widget.companyCode) continue;
        if (widget.selectedBranchCode != null && widget.selectedBranchCode != 'all' && raw['branch_code']?.toString() != widget.selectedBranchCode) continue;
        final d = DateTime.tryParse(raw['date']?.toString() ?? '');
        if (d == null || d.isAfter(to)) continue;
        final n = raw['supplier_name']?.toString() ?? 'غير محدد';
        names.add(n);
        totals[n] = (totals[n] ?? 0) + (double.tryParse(raw['total_amount']?.toString() ?? '0') ?? 0);
      }
    }
    for (final rawList in settlements.values) {
      if (rawList is! List) continue;
      for (final raw in rawList.whereType<Map>()) {
        if (raw['is_deleted'] == true || raw['company_code']?.toString() != widget.companyCode) continue;
        if (widget.selectedBranchCode != null && widget.selectedBranchCode != 'all' && raw['branch_code']?.toString() != widget.selectedBranchCode) continue;
        final d = DateTime.tryParse(raw['date']?.toString() ?? '');
        if (d == null || d.isAfter(to)) continue;
        final n = raw['supplier_name']?.toString() ?? 'غير محدد';
        totals[n] = (totals[n] ?? 0) - (double.tryParse(raw['amount']?.toString() ?? '0') ?? 0);
      }
    }
    for (final n in names) result.add({'المورد': n, 'الرصيد': totals[n] ?? 0.0});
    result.sort((a,b) => (b['الرصيد'] as double).compareTo(a['الرصيد'] as double));
    return result;
  }

  Future<double> _getTotalInventoryWholesale(DateTime toDate) async {
    final codingBox = Hive.box('coding_box');
    final rawStores = codingBox.get('${widget.companyCode}_stores', defaultValue: []);
    final List<String> stores = [];
    if (rawStores is List) {
      for (final s in rawStores.whereType<Map>()) {
        final code = s['code']?.toString() ?? '';
        if (code.isNotEmpty) stores.add(code);
      }
    }

    final List<String> branches = [];
    if (widget.selectedBranchCode != null &&
        widget.selectedBranchCode != 'all' &&
        widget.selectedBranchCode != '') {
      branches.add(widget.selectedBranchCode!);
    } else {
      final rawBranches = codingBox.get('${widget.companyCode}_branches', defaultValue: []);
      if (rawBranches is List) {
        for (final b in rawBranches.whereType<Map>()) {
          final code = b['code']?.toString() ?? '';
          if (code.isNotEmpty) branches.add(code);
        }
      }
    }

    double total = 0.0;
    for (final branchCode in branches) {
      for (final storeCode in stores) {
        final value = await StockBalanceService.calculateTotalWholesale(
          companyCode: widget.companyCode,
          branchCode: branchCode,
          storeCode: storeCode,
          toDate: toDate,
        );
        total += value;
      }
    }

    return total;
  }

  Widget _buildExtendedReport() {
    if (_extendedSummary.isEmpty) return Center(child: CircularProgressIndicator(color: AppTheme.textMainFor(context)));

    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildDetailSection('تفاصيل الإيرادات (الواردات)', _incomeDetails, AppTheme.successStrongFor(context)),
        const SizedBox(height: 10),

        _buildDetailSection('تفاصيل المصروفات', _expenseDetails, AppTheme.dangerFor(context)),
        const SizedBox(height: 10),

        _buildSummarySection(
          'الإجمالي المالي',
          {
            'الإيراد': _extendedSummary['إجمالي الإيراد'] as double,
            'المصروفات': _extendedSummary['المصروفات'] as double,
            'الرصيد المتبقي': _extendedSummary['الرصيد المتبقي'] as double,
            'إجمالي المصروفات (بدون بضاعة)': _expensesWithoutGoods,
            'إجمالي المصروفات (بدون بضاعة وأرباح)': _expensesWithoutGoodsAndProfit,
          },
          _extendedSummary['إجمالي الإيراد'] as double,
          AppTheme.successStrongFor(context),
          showTotal: false,
        ),
        const SizedBox(height: 10),

        _buildSummarySection('الأصول المملوكة للشركة', {
          'الجرد الفعلي بسعر الجملة': _extendedSummary['الجرد الفعلي بسعر الجملة'] as double,
          'رصيد الخزينة': _extendedSummary['الرصيد المتبقي'] as double,
          'أرصدة العملاء غير المحصلة': _extendedSummary['أرصدة العملاء غير المحصلة'] as double,
          'الإجمالي': _extendedSummary['إجمالي ملك الشركة'] as double,
        }, _extendedSummary['إجمالي ملك الشركة'] as double, AppTheme.accentFor(context), showTotal: false),
        const SizedBox(height: 10),

        _buildSupplierBalanceSection(),
        const SizedBox(height: 10),

        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: GlassStyle.fill05For(context),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: GlassStyle.line24For(context)),
          ),
          child: Column(children: [
            _summaryRow('إجمالي المدين / ملك الشركة:', _extendedSummary['إجمالي ملك الشركة'] as double, AppTheme.accentFor(context)),
            Divider(color: GlassStyle.line24For(context)),
            _summaryRow('إجمالي الدائن / على الشركة:', _extendedSummary['إجمالي ما على الشركة'] as double, AppTheme.dangerFor(context)),
            Divider(color: GlassStyle.line24For(context)),
            _summaryRow('صافي الجرد الحالي:', _extendedSummary['صافي الجرد الحالي'] as double, AppTheme.warningFor(context), isBold: true),
            _summaryRow('صافي الجرد السابق:', _extendedSummary['صافي الجرد السابق'] as double, AppTheme.textSoftFor(context)),
            _summaryRow('الفرق / صافي الأرباح:', _extendedSummary['الفرق / صافي الأرباح'] as double, AppTheme.successFor(context), isBold: true),
            _summaryRow('المتبقي بعد توزيع الأرباح:', _extendedSummary['المتبقي بعد توزيع الأرباح'] as double, AppTheme.accentFor(context)),
            _summaryRow('نسبة الربح:', _extendedSummary['نسبة الربح'] as double, AppTheme.warningFor(context), isBold: true, suffix: '%'),
          ]),
        ),
      ]),
    );
  }

  Widget _buildSupplierBalanceSection() {
    final total = _extendedSupplierBalances.fold<double>(0, (s, e) => s + (e['الرصيد'] as double));
    return Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: GlassStyle.fill03For(context), borderRadius: BorderRadius.circular(15), border: Border.all(color: GlassStyle.line10For(context))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('مديونيات الموردين', style: TextStyle(color: AppTheme.dangerFor(context), fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
      Divider(color: GlassStyle.line10For(context)),
      ..._extendedSupplierBalances.map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(e['المورد'].toString(), style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo')),
        Text(_formatNumber(e['الرصيد'] as double), style: TextStyle(color: (e['الرصيد'] as double) >= 0 ? AppTheme.dangerFor(context) : AppTheme.successFor(context), fontFamily: 'Cairo')),
      ]))),
      Divider(color: GlassStyle.line10For(context)),
      _summaryRow('الإجمالي', total, AppTheme.dangerFor(context), isBold: true),
    ]));
  }

  Widget _buildDetailSection(String title, Map<String, double> items, Color titleColor) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GlassStyle.fill03For(context),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: titleColor, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          Divider(color: GlassStyle.line10For(context)),
          ...items.entries.map((e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(e.key, style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo')),
                Text(_formatNumber(e.value), style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo')),
              ],
            ),
          )),
          Divider(color: GlassStyle.line10For(context)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("الإجمالي", style: TextStyle(color: AppTheme.textMainFor(context), fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              Text(_formatNumber(items.values.fold(0.0, (sum, v) => sum + v)),
                  style: TextStyle(color: titleColor, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummarySection(String title, Map<String, double> items, double total, Color titleColor, {bool showTotal = true}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GlassStyle.fill03For(context),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: titleColor, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          Divider(color: GlassStyle.line10For(context)),
          ...items.entries.map((e) {
            final isTotalRow = e.key == 'الإجمالي';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    e.key,
                    style: TextStyle(
                      color: isTotalRow ? AppTheme.textMainFor(context) : AppTheme.textSoftFor(context),
                      fontWeight: isTotalRow ? FontWeight.bold : FontWeight.normal,
                      fontFamily: 'Cairo',
                    ),
                  ),
                  Text(
                    _formatNumber(e.value),
                    style: TextStyle(
                      color: isTotalRow ? titleColor : AppTheme.textMainFor(context),
                      fontWeight: isTotalRow ? FontWeight.bold : FontWeight.normal,
                      fontFamily: 'Cairo',
                    ),
                  ),
                ],
              ),
            );
          }),
          if (showTotal) ...[
            Divider(color: GlassStyle.line10For(context)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("الإجمالي", style: TextStyle(color: AppTheme.textMainFor(context), fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
                Text(_formatNumber(total), style: TextStyle(color: titleColor, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(String label, double amount, Color color, {bool isBold = false, String suffix = ''}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: AppTheme.textMainFor(context), fontSize: isBold ? 16 : 14, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, fontFamily: 'Cairo')),
        Text('${_formatNumber(amount)}$suffix', style: TextStyle(color: color, fontSize: isBold ? 18 : 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
      ],
    );
  }
}