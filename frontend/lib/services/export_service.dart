// lib/services/export_service.dart
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:universal_html/html.dart' as html;

class ExportService {
  static pw.Font? _arabicFont;

  static Future<pw.Font> _loadArabicFont() async {
    if (_arabicFont != null) return _arabicFont!;
    try {
      final fontData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
      _arabicFont = pw.Font.ttf(fontData.buffer.asByteData());
      return _arabicFont!;
    } catch (e) {
      print('⚠️ فشل تحميل الخط: $e');
      _arabicFont = pw.Font.helvetica();
      return _arabicFont!;
    }
  }

  // تصدير إلى Excel (نفس الكود السابق)
  static Future<void> exportToExcel(
    List<Map<String, dynamic>> data,
    String title,
    List<String> headers,
    List<String> keys,
  ) async {
    // ... (نفس الكود السابق، لا تغيير)
    try {
      var excel = excel_lib.Excel.createExcel();
      excel.rename(excel.tables.keys.first, title);
      var sheet = excel[title];
      sheet.appendRow(headers.map((h) => excel_lib.TextCellValue(h)).toList());
      for (var row in data) {
        List<excel_lib.CellValue> cells = [];
        for (var key in keys) {
          var value = row[key];
          if (value is String) cells.add(excel_lib.TextCellValue(value));
          else if (value is double || value is int) cells.add(excel_lib.DoubleCellValue(value.toDouble()));
          else cells.add(excel_lib.TextCellValue(value?.toString() ?? ''));
        }
        sheet.appendRow(cells);
      }
      var fileBytes = excel.encode();
      if (fileBytes == null) throw 'فشل ترميز الملف';
      String fileName = '${title}_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      if (identical(0, 0.0)) {
        final blob = html.Blob([fileBytes], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
        final url = html.Url.createObjectUrlFromBlob(blob);
        final anchor = html.AnchorElement(href: url)..setAttribute('download', fileName)..style.display = 'none';
        html.document.body?.append(anchor);
        anchor.click();
        anchor.remove();
        html.Url.revokeObjectUrl(url);
      } else {
        String? selectedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'اختر مكان حفظ الملف',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['xlsx'],
        );
        if (selectedPath != null) {
          if (!selectedPath.endsWith('.xlsx')) selectedPath += '.xlsx';
          final file = File(selectedPath);
          await file.writeAsBytes(fileBytes);
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  // تصدير PDF محسن مع إجماليات ودعم كامل للعربية
  // lib/services/export_service.dart
// أضف هذا المعامل إلى دالة exportToPDF:
static Future<void> exportToPDF({
  required List<Map<String, dynamic>> data,
  required String title,
  required List<String> headers,
  required List<String> keys,
  Map<String, dynamic>? summary,
  String? branchName,
  String? storeName,
  String? date,
  String? serial,
  double? totalAmount, // ✅ إضافة المعامل الجديد
}) async {
  try {
    final font = await _loadArabicFont();

    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(30),
        build: (pw.Context context) {
          return [
            // ===== رأس الصفحة ===== (نفس الكود)
            pw.Directionality(
              textDirection: pw.TextDirection.rtl,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    title,
                    style: pw.TextStyle(
                      font: font,
                      fontSize: 22,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.blue900,
                    ),
                    textDirection: pw.TextDirection.rtl,
                  ),
                  pw.SizedBox(height: 6),
                  if (serial != null)
                    pw.Text(
                      'رقم الإذن: $serial',
                      style: pw.TextStyle(font: font, fontSize: 12, color: PdfColors.grey700),
                      textDirection: pw.TextDirection.rtl,
                    ),
                  if (date != null)
                    pw.Text(
                      'التاريخ: $date',
                      style: pw.TextStyle(font: font, fontSize: 12, color: PdfColors.grey700),
                      textDirection: pw.TextDirection.rtl,
                    ),
                  if (branchName != null && branchName.isNotEmpty)
                    pw.Text(
                      'الفرع: $branchName',
                      style: pw.TextStyle(font: font, fontSize: 12, color: PdfColors.grey700),
                      textDirection: pw.TextDirection.rtl,
                    ),
                  if (storeName != null && storeName.isNotEmpty)
                    pw.Text(
                      'المخزن: $storeName',
                      style: pw.TextStyle(font: font, fontSize: 12, color: PdfColors.grey700),
                      textDirection: pw.TextDirection.rtl,
                    ),
                  pw.Divider(thickness: 1, color: PdfColors.blue200),
                  pw.SizedBox(height: 10),
                ],
              ),
            ),

            // ===== جدول البيانات ===== (نفس الكود)
            pw.Directionality(
              textDirection: pw.TextDirection.rtl,
              child: pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
                columnWidths: {
                  for (int i = 0; i < headers.length; i++) i: pw.FlexColumnWidth(1),
                },
                children: [
                  // رأس الجدول
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: PdfColors.blue100),
                    children: headers.map((h) =>
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          h,
                          style: pw.TextStyle(
                            font: font,
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 12,
                            color: PdfColors.blue800,
                          ),
                          textAlign: pw.TextAlign.center,
                          textDirection: pw.TextDirection.rtl,
                        ),
                      )
                    ).toList(),
                  ),
                  // صفوف البيانات
                  ...data.map((row) {
                    return pw.TableRow(
                      children: keys.map((key) {
                        var value = row[key]?.toString() ?? '';
                        String displayValue = value;
                        if (key.contains('سعر') || key.contains('قيمة') || key.contains('الإجمالي')) {
                          final num = double.tryParse(value);
                          if (num != null) {
                            displayValue = num.toStringAsFixed(2);
                          }
                        }
                        return pw.Padding(
                          padding: const pw.EdgeInsets.all(6),
                          child: pw.Text(
                            displayValue,
                            style: pw.TextStyle(font: font, fontSize: 10),
                            textAlign: pw.TextAlign.center,
                            textDirection: pw.TextDirection.rtl,
                          ),
                        );
                      }).toList(),
                    );
                  }),
                  // صف الإجماليات (إذا وجد summary)
                  if (summary != null && summary.isNotEmpty)
                    pw.TableRow(
                      decoration: pw.BoxDecoration(color: PdfColors.green50),
                      children: headers.map((h) {
                        String value = '';
                        if (h.contains('الكمية') || h == 'الكمية') {
                          value = summary['totalQuantity']?.toStringAsFixed(0) ?? '';
                        } else if (h.contains('قيمة الجملة') || h == 'قيمة الجملة') {
                          value = summary['totalWholesale']?.toStringAsFixed(2) ?? '';
                        } else if (h.contains('قيمة البيع') || h == 'قيمة البيع') {
                          value = summary['totalRetail']?.toStringAsFixed(2) ?? '';
                        } else if (h.contains('الإجمالي') || h == 'الإجمالي') {
                          value = 'الإجمالي';
                        }
                        return pw.Padding(
                          padding: const pw.EdgeInsets.all(6),
                          child: pw.Text(
                            value,
                            style: pw.TextStyle(
                              font: font,
                              fontWeight: pw.FontWeight.bold,
                              fontSize: 11,
                              color: PdfColors.green800,
                            ),
                            textAlign: pw.TextAlign.center,
                            textDirection: pw.TextDirection.rtl,
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),

            // ===== تذييل الصفحة (مع إجمالي المبلغ) =====
            pw.SizedBox(height: 20),
            pw.Directionality(
              textDirection: pw.TextDirection.rtl,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  // ✅ عرض الإجمالي إذا تم تمريره
                  if (totalAmount != null)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 8),
                      child: pw.Text(
                        'إجمالي المبلغ: ${totalAmount.toStringAsFixed(2)}',
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 14,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.green700,
                        ),
                        textDirection: pw.TextDirection.rtl,
                      ),
                    ),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'تم التصدير بواسطة IslamApp V1.0',
                        style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey600),
                        textDirection: pw.TextDirection.rtl,
                      ),
                      pw.Text(
                        'تاريخ التصدير: ${DateTime.now().toLocal().toString().split(' ')[0]}',
                        style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey600),
                        textDirection: pw.TextDirection.rtl,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ];
        },
      ),
    );

    // حفظ الملف (نفس الكود)
    String fileName = '${title.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.pdf';
    if (identical(0, 0.0)) {
      final bytes = await pdf.save();
      final blob = html.Blob([bytes], 'application/pdf');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)..setAttribute('download', fileName)..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(url);
    } else {
      String? selectedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'اختر مكان حفظ ملف PDF',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (selectedPath != null) {
        if (!selectedPath.endsWith('.pdf')) selectedPath += '.pdf';
        final file = File(selectedPath);
        final bytes = await pdf.save();
        await file.writeAsBytes(bytes);
      }
    }
  } catch (e) {
    rethrow;
  }
}
}