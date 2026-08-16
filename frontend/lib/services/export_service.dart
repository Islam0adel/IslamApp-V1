// lib/services/export_service.dart

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';

import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:universal_html/html.dart' as html;

class ExportService {
  static pw.Font? _arabicFont;

  // ============================================================
  // تحميل الخط العربي
  // ============================================================

  static Future<pw.Font> _loadArabicFont() async {
    if (_arabicFont != null) {
      return _arabicFont!;
    }

    try {
      final fontData = await rootBundle.load(
        'assets/fonts/Cairo-Regular.ttf',
      );

      _arabicFont = pw.Font.ttf(
        fontData.buffer.asByteData(),
      );

      return _arabicFont!;
    } catch (e) {
      debugPrint('⚠️ فشل تحميل خط Cairo: $e');

      _arabicFont = pw.Font.helvetica();

      return _arabicFont!;
    }
  }

  // ============================================================
  // تصدير Excel
  // ============================================================

  static Future<void> exportToExcel(
    List<Map<String, dynamic>> data,
    String title,
    List<String> headers,
    List<String> keys, {
    String? companyName,
    String? branchName,
    String? storeName,
    String? serial,
    String? date,
    String? period,
    String? supplierName,
    String? employee,
    Map<String, dynamic>? summary,
  }) async {
    try {
      final excel = excel_lib.Excel.createExcel();

      final String sheetName = _safeSheetName(title);
      final String defaultSheet = excel.tables.keys.first;

      excel.rename(
        defaultSheet,
        sheetName,
      );

      final sheet = excel[sheetName];

      // ========================================================
      // عنوان التقرير
      // ========================================================

      sheet.appendRow([
        excel_lib.TextCellValue(title),
      ]);

      // ========================================================
      // بيانات التقرير الأساسية
      // ========================================================

      if (companyName != null && companyName.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'اسم الشركة: $companyName',
          ),
        ]);
      }

      if (branchName != null && branchName.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'الفرع: $branchName',
          ),
        ]);
      }

      if (storeName != null && storeName.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'المخزن: $storeName',
          ),
        ]);
      }

      if (serial != null && serial.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'رقم الإذن: $serial',
          ),
        ]);
      }

      if (date != null && date.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'التاريخ: $date',
          ),
        ]);
      }

      if (period != null && period.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'الفترة: $period',
          ),
        ]);
      }

      if (supplierName != null && supplierName.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'المورد: $supplierName',
          ),
        ]);
      }

      if (employee != null && employee.isNotEmpty) {
        sheet.appendRow([
          excel_lib.TextCellValue(
            'الموظف: $employee',
          ),
        ]);
      }

      sheet.appendRow([]);

      // ========================================================
      // عناوين الأعمدة
      // ========================================================

      sheet.appendRow(
        headers
            .map(
              (header) => excel_lib.TextCellValue(header),
            )
            .toList(),
      );

      // ========================================================
      // البيانات
      // ========================================================

      for (final row in data) {
        final List<excel_lib.CellValue> cells = [];

        for (final key in keys) {
          final dynamic value = row[key];

          if (value is num) {
            cells.add(
              excel_lib.DoubleCellValue(
                value.toDouble(),
              ),
            );
          } else {
            cells.add(
              excel_lib.TextCellValue(
                value?.toString() ?? '',
              ),
            );
          }
        }

        sheet.appendRow(cells);
      }

      // ========================================================
      // قسم الإجماليات
      // ========================================================

      if (summary != null && summary.isNotEmpty) {
        sheet.appendRow([]);

        sheet.appendRow([
          excel_lib.TextCellValue('الإجماليات'),
        ]);

        for (final entry in summary.entries) {
          sheet.appendRow([
            excel_lib.TextCellValue(
              entry.key,
            ),
            _excelCellValue(entry.value),
          ]);
        }
      }

      // ========================================================
      // إنشاء الملف
      // ========================================================

      final fileBytes = excel.encode();

      if (fileBytes == null) {
        throw Exception('فشل إنشاء ملف Excel');
      }

      final fileName =
          '${_safeFileName(title)}_'
          '${DateTime.now().millisecondsSinceEpoch}.xlsx';

      // ========================================================
      // Web
      // ========================================================

      if (kIsWeb) {
        final blob = html.Blob(
          [fileBytes],
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );

        final url =
            html.Url.createObjectUrlFromBlob(blob);

        final anchor = html.AnchorElement(
          href: url,
        )
          ..setAttribute(
            'download',
            fileName,
          )
          ..style.display = 'none';

        html.document.body?.append(anchor);

        anchor.click();
        anchor.remove();

        html.Url.revokeObjectUrl(url);

        return;
      }

      // ========================================================
      // Mobile / Desktop
      // ========================================================

      String? selectedPath =
          await FilePicker.platform.saveFile(
        dialogTitle:
            'اختر مكان حفظ ملف Excel',
        fileName:
            fileName,
        type:
            FileType.custom,
        allowedExtensions:
            ['xlsx'],
      );

      if (selectedPath == null) {
        return;
      }

      if (!selectedPath.toLowerCase().endsWith('.xlsx')) {
        selectedPath += '.xlsx';
      }

      final file = File(selectedPath);

      await file.writeAsBytes(
        fileBytes,
      );
    } catch (e) {
      debugPrint(
        '❌ خطأ في تصدير Excel: $e',
      );

      rethrow;
    }
  }

  // ============================================================
  // تصدير PDF
  // ============================================================

  static Future<void> exportToPDF({
    required List<Map<String, dynamic>> data,
    required String title,
    required List<String> headers,
    required List<String> keys,

    String? companyName,
    String? branchName,
    String? storeName,
    String? serial,
    String? date,
    String? period,
    String? supplierName,
    String? employee,

    Map<String, dynamic>? summary,
    double? totalAmount,
  }) async {
    try {
      final font = await _loadArabicFont();

      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),

          build: (pw.Context context) {
            final List<pw.Widget> widgets = [];

            // ==================================================
            // رأس التقرير
            // ==================================================

            widgets.add(
              pw.Directionality(
                textDirection: pw.TextDirection.rtl,
                child: pw.Column(
                  crossAxisAlignment:
                      pw.CrossAxisAlignment.end,
                  children: [
                    if (companyName != null &&
                        companyName.isNotEmpty)
                      pw.Text(
                        companyName,
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 16,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blue900,
                        ),
                        textDirection:
                            pw.TextDirection.rtl,
                      ),

                    pw.SizedBox(height: 4),

                    pw.Text(
                      title,
                      style: pw.TextStyle(
                        font: font,
                        fontSize: 22,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.blue900,
                      ),
                      textDirection:
                          pw.TextDirection.rtl,
                    ),

                    pw.SizedBox(height: 8),

                    if (serial != null &&
                        serial.isNotEmpty)
                      _metaText(
                        font,
                        'رقم الإذن',
                        serial,
                      ),

                    if (date != null &&
                        date.isNotEmpty)
                      _metaText(
                        font,
                        'التاريخ',
                        date,
                      ),

                    if (period != null &&
                        period.isNotEmpty)
                      _metaText(
                        font,
                        'الفترة',
                        period,
                      ),

                    if (branchName != null &&
                        branchName.isNotEmpty)
                      _metaText(
                        font,
                        'الفرع',
                        branchName,
                      ),

                    if (storeName != null &&
                        storeName.isNotEmpty)
                      _metaText(
                        font,
                        'المخزن',
                        storeName,
                      ),

                    if (supplierName != null &&
                        supplierName.isNotEmpty)
                      _metaText(
                        font,
                        'المورد',
                        supplierName,
                      ),

                    if (employee != null &&
                        employee.isNotEmpty)
                      _metaText(
                        font,
                        'الموظف',
                        employee,
                      ),

                    pw.SizedBox(height: 6),

                    pw.Divider(
                      thickness: 1,
                      color: PdfColors.blue200,
                    ),

                    pw.SizedBox(height: 10),
                  ],
                ),
              ),
            );

            // ==================================================
            // جدول التقرير
            // ==================================================

            widgets.add(
              pw.Directionality(
                textDirection:
                    pw.TextDirection.rtl,
                child: pw.Table(
                  border:
                      pw.TableBorder.all(
                    color:
                        PdfColors.grey400,
                    width:
                        0.5,
                  ),
                  columnWidths:
                      <int, pw.TableColumnWidth>{
                    for (
                      int i = 0;
                      i < headers.length;
                      i++
                    )
                      i: const pw.FlexColumnWidth(1),
                  },
                  children: [
                    // ==========================================
                    // Header
                    // ==========================================

                    pw.TableRow(
                      decoration:
                          const pw.BoxDecoration(
                        color:
                            PdfColors.blue100,
                      ),
                      children:
                          headers.map(
                        (header) {
                          return pw.Padding(
                            padding:
                                const pw.EdgeInsets.all(7),
                            child:
                                pw.Text(
                              header,
                              style:
                                  pw.TextStyle(
                                font:
                                    font,
                                fontWeight:
                                    pw.FontWeight.bold,
                                fontSize:
                                    11,
                                color:
                                    PdfColors.blue800,
                              ),
                              textAlign:
                                  pw.TextAlign.center,
                              textDirection:
                                  pw.TextDirection.rtl,
                            ),
                          );
                        },
                      ).toList(),
                    ),

                    // ==========================================
                    // Rows
                    // ==========================================

                    ...data.map(
                      (row) {
                        return pw.TableRow(
                          children:
                              keys.map(
                            (key) {
                              final value =
                                  _formatPdfValue(
                                key,
                                row[key],
                              );

                              return pw.Padding(
                                padding:
                                    const pw.EdgeInsets.all(6),
                                child:
                                    pw.Text(
                                  value,
                                  style:
                                      pw.TextStyle(
                                    font:
                                        font,
                                    fontSize:
                                        9,
                                  ),
                                  textAlign:
                                      pw.TextAlign.center,
                                  textDirection:
                                      pw.TextDirection.rtl,
                                ),
                              );
                            },
                          ).toList(),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );

            // ==================================================
            // قسم الإجماليات
            // ==================================================

            if (summary != null &&
                summary.isNotEmpty) {
              widgets.add(
                pw.SizedBox(height: 15),
              );

              widgets.add(
                pw.Directionality(
                  textDirection:
                      pw.TextDirection.rtl,
                  child: pw.Container(
                    padding:
                        const pw.EdgeInsets.all(10),
                    decoration:
                        pw.BoxDecoration(
                      color:
                          PdfColors.green50,
                      border:
                          pw.Border.all(
                        color:
                            PdfColors.green200,
                        width:
                            0.7,
                      ),
                    ),
                    child: pw.Column(
                      crossAxisAlignment:
                          pw.CrossAxisAlignment.stretch,
                      children: [
                        pw.Text(
                          'الإجماليات',
                          style:
                              pw.TextStyle(
                            font:
                                font,
                            fontSize:
                                14,
                            fontWeight:
                                pw.FontWeight.bold,
                            color:
                                PdfColors.green800,
                          ),
                          textDirection:
                              pw.TextDirection.rtl,
                        ),

                        pw.SizedBox(
                          height: 8,
                        ),

                        ...summary.entries.map(
                          (entry) {
                            final value =
                                _formatSummaryValue(
                              entry.value,
                            );

                            return pw.Padding(
                              padding:
                                  const pw.EdgeInsets.symmetric(
                                vertical:
                                    3,
                              ),
                              child:
                                  pw.Row(
                                mainAxisAlignment:
                                    pw.MainAxisAlignment.spaceBetween,
                                children: [
                                  pw.Text(
                                    entry.key,
                                    style:
                                        pw.TextStyle(
                                      font:
                                          font,
                                      fontSize:
                                          11,
                                      fontWeight:
                                          pw.FontWeight.bold,
                                      color:
                                          PdfColors.grey800,
                                    ),
                                    textDirection:
                                        pw.TextDirection.rtl,
                                  ),
                                  pw.Text(
                                    value,
                                    style:
                                        pw.TextStyle(
                                      font:
                                          font,
                                      fontSize:
                                          11,
                                      fontWeight:
                                          pw.FontWeight.bold,
                                      color:
                                          PdfColors.green800,
                                    ),
                                    textDirection:
                                        pw.TextDirection.rtl,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            // ==================================================
            // إجمالي المبلغ الرئيسي
            // ==================================================

            if (totalAmount != null) {
              widgets.add(
                pw.SizedBox(height: 15),
              );

              widgets.add(
                pw.Directionality(
                  textDirection:
                      pw.TextDirection.rtl,
                  child: pw.Align(
                    alignment:
                        pw.Alignment.centerRight,
                    child:
                        pw.Text(
                      'إجمالي المبلغ: '
                      '${totalAmount.toStringAsFixed(2)}',
                      style:
                          pw.TextStyle(
                        font:
                            font,
                        fontSize:
                            14,
                        fontWeight:
                            pw.FontWeight.bold,
                        color:
                            PdfColors.green700,
                      ),
                      textDirection:
                          pw.TextDirection.rtl,
                    ),
                  ),
                ),
              );
            }

            // ==================================================
            // Footer
            // ==================================================

            widgets.add(
              pw.SizedBox(height: 20),
            );

            widgets.add(
              pw.Directionality(
                textDirection:
                    pw.TextDirection.rtl,
                child: pw.Row(
                  mainAxisAlignment:
                      pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'تم التصدير بواسطة IslamApp V1.0',
                      style: pw.TextStyle(
                        font:
                            font,
                        fontSize:
                            9,
                        color:
                            PdfColors.grey600,
                      ),
                      textDirection:
                          pw.TextDirection.rtl,
                    ),
                    pw.Text(
                      'تاريخ التصدير: '
                      '${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
                      style: pw.TextStyle(
                        font:
                            font,
                        fontSize:
                            9,
                        color:
                            PdfColors.grey600,
                      ),
                      textDirection:
                          pw.TextDirection.rtl,
                    ),
                  ],
                ),
              ),
            );

            return widgets;
          },
        ),
      );

      // ========================================================
      // حفظ PDF
      // ========================================================

      final bytes = await pdf.save();

      final fileName =
          '${_safeFileName(title)}_'
          '${DateTime.now().millisecondsSinceEpoch}.pdf';

      // ========================================================
      // Web
      // ========================================================

      if (kIsWeb) {
        final blob = html.Blob(
          [bytes],
          'application/pdf',
        );

        final url =
            html.Url.createObjectUrlFromBlob(
          blob,
        );

        final anchor =
            html.AnchorElement(
          href: url,
        )
              ..setAttribute(
                'download',
                fileName,
              )
              ..style.display = 'none';

        html.document.body?.append(anchor);

        anchor.click();
        anchor.remove();

        html.Url.revokeObjectUrl(url);

        return;
      }

      // ========================================================
      // Mobile / Desktop
      // ========================================================

      String? selectedPath =
          await FilePicker.platform.saveFile(
        dialogTitle:
            'اختر مكان حفظ ملف PDF',
        fileName:
            fileName,
        type:
            FileType.custom,
        allowedExtensions:
            ['pdf'],
      );

      if (selectedPath == null) {
        return;
      }

      if (!selectedPath.toLowerCase().endsWith('.pdf')) {
        selectedPath += '.pdf';
      }

      final file = File(selectedPath);

      await file.writeAsBytes(
        bytes,
      );
    } catch (e) {
      debugPrint(
        '❌ خطأ في تصدير PDF: $e',
      );

      rethrow;
    }
  }

  // ============================================================
  // PDF Metadata
  // ============================================================

  static pw.Widget _metaText(
    pw.Font font,
    String label,
    String value,
  ) {
    return pw.Padding(
      padding:
          const pw.EdgeInsets.only(
        bottom: 2,
      ),
      child: pw.Text(
        '$label: $value',
        style:
            pw.TextStyle(
          font:
              font,
          fontSize:
              11,
          color:
              PdfColors.grey700,
        ),
        textDirection:
            pw.TextDirection.rtl,
      ),
    );
  }

  // ============================================================
  // Excel Cell
  // ============================================================

  static excel_lib.CellValue _excelCellValue(
    dynamic value,
  ) {
    if (value is num) {
      return excel_lib.DoubleCellValue(
        value.toDouble(),
      );
    }

    return excel_lib.TextCellValue(
      value?.toString() ?? '',
    );
  }

  // ============================================================
  // PDF Value
  // ============================================================

  static String _formatPdfValue(
    String key,
    dynamic value,
  ) {
    if (value == null) {
      return '';
    }

    if (value is num) {
      if (_isDecimalField(key)) {
        return value.toStringAsFixed(2);
      }

      return value.toString();
    }

    final text = value.toString();

    if (_isDecimalField(key)) {
      final parsed =
          double.tryParse(text);

      if (parsed != null) {
        return parsed.toStringAsFixed(2);
      }
    }

    return text;
  }

  // ============================================================
  // Summary Value
  // ============================================================

  static String _formatSummaryValue(
    dynamic value,
  ) {
    if (value == null) {
      return '';
    }

    if (value is num) {
      return NumberFormat(
        '#,##0.00',
        'en_US',
      ).format(
        value.toDouble(),
      );
    }

    return value.toString();
  }

  // ============================================================
  // هل الحقل رقم عشري؟
  // ============================================================

  static bool _isDecimalField(
    String key,
  ) {
    final lower =
        key.toLowerCase();

    return lower.contains('سعر') ||
        lower.contains('قيمة') ||
        lower.contains('مبلغ') ||
        lower.contains('إجمالي') ||
        lower.contains('الاجمالي') ||
        lower.contains('amount') ||
        lower.contains('price') ||
        lower.contains('total') ||
        lower.contains('value');
  }

  // ============================================================
  // اسم الملف
  // ============================================================

  static String _safeFileName(
    String value,
  ) {
    String result =
        value.trim();

    if (result.isEmpty) {
      result = 'report';
    }

    result = result.replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '_',
    );

    return result;
  }

  // ============================================================
  // اسم Sheet
  // ============================================================

  static String _safeSheetName(
    String value,
  ) {
    String result =
        value.trim();

    if (result.isEmpty) {
      result = 'Report';
    }

    result = result.replaceAll(
      RegExp(r'[\[\]\*\/\\\?:]'),
      '_',
    );

    if (result.length > 31) {
      result =
          result.substring(0, 31);
    }

    return result;
  }
}