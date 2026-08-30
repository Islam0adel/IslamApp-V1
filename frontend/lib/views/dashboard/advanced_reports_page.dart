import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/export_service.dart';
import '../../services/permissions_service.dart';
import '../../views/widgets/glass_card.dart';

class AdvancedReportsPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final int reportId;
  final DateTime fromDate;
  final DateTime toDate;

  const AdvancedReportsPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    required this.reportId,
    required this.fromDate,
    required this.toDate,
  });

  @override
  State<AdvancedReportsPage> createState() => _AdvancedReportsPageState();
}

class _AdvancedReportsPageState extends State<AdvancedReportsPage> {
  static const _titles = <int, String>{
    1: 'بيان التدفق النقدي',
    2: 'تحليل هيكل المصروفات',
    3: 'الربحية الصافية لكل فرع',
    4: 'تحليل حجم الفاتورة (Basket Size)',
    5: 'تحليل الخزائن النقدية',
    6: 'الأصناف بطيئة الحركة (Dead Stock)',
    7: 'تحليل دقة الجرد (Shrinkage)',
    8: 'تقييم المخزون و ABC',
    9: 'تحليل أداء الموردين (Vendor Score)',
    10: 'تحليل العوائد والخصومات',
    11: 'تحليل الاتجاهات الموسمية',
    12: 'تحليل هامش الربح الفعلي',
    13: 'تحليل تجميع المنتجات (Basket Analysis)',
  };

  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic> _summary = {};
  bool _loading = true;

  // متغيرات التاريخ القابلة للتغيير
  late DateTime _fromDate;
  late DateTime _toDate;

  String get _title => _titles[widget.reportId] ?? 'تقرير تحليلي';

  bool _branchOk(dynamic value) {
    final b = widget.selectedBranchCode;
    return b == null || b.isEmpty || b == 'all' || value?.toString() == b;
  }

  double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '0') ?? 0;

  List<Map<String, dynamic>> _transactions({DateTime? before}) {
    final box = Hive.box('daily_transactions_box');
    final from = DateTime(_fromDate.year, _fromDate.month, _fromDate.day);
    final to = DateTime(_toDate.year, _toDate.month, _toDate.day);
    final result = <Map<String, dynamic>>[];
    for (final raw in box.values) {
      if (raw is! Map) continue;
      if (raw['company_code']?.toString() != widget.companyCode) continue;
      if (raw['category'] == 'transfer_hidden') continue;
      if (!_branchOk(raw['branch_code'])) continue;
      final date = DateTime.tryParse(raw['date']?.toString().substring(0, 10) ?? '');
      if (date == null) continue;
      if (before != null) {
        if (!date.isBefore(before)) continue;
      } else if (date.isBefore(from) || date.isAfter(to)) {
        continue;
      }
      result.add(Map<String, dynamic>.from(raw));
    }
    return result;
  }

  List<Map<String, dynamic>> _purchases() {
    final box = Hive.box('supplier_box');
    final from = DateTime(_fromDate.year, _fromDate.month, _fromDate.day);
    final to = DateTime(_toDate.year, _toDate.month, _toDate.day);
    final result = <Map<String, dynamic>>[];
    for (final rawList in box.values) {
      if (rawList is! List) continue;
      for (final raw in rawList) {
        if (raw is! Map || raw['is_deleted'] == true) continue;
        if (raw['company_code']?.toString() != widget.companyCode || !_branchOk(raw['branch_code'])) continue;
        final d = DateTime.tryParse(raw['date']?.toString() ?? '');
        if (d == null || d.isBefore(from) || d.isAfter(to)) continue;
        result.add(Map<String, dynamic>.from(raw));
      }
    }
    return result;
  }

  List<Map<String, dynamic>> _inventoryItems() {
    final box = Hive.box('inventory_box');
    final latest = <String, Map<String, dynamic>>{};
    DateTime? latestDate;
    for (final rawList in box.values) {
      if (rawList is! List) continue;
      for (final raw in rawList) {
        if (raw is! Map || raw['is_deleted'] == true) continue;
        if (raw['company_code']?.toString() != widget.companyCode || !_branchOk(raw['branch_code'])) continue;
        final d = DateTime.tryParse(raw['date']?.toString() ?? '');
        if (d == null || d.isAfter(_toDate)) continue;
        if (latestDate == null || d.isAfter(latestDate)) {
          latestDate = d;
          latest.clear();
          final items = raw['items'];
          if (items is List) {
            for (final item in items) {
              if (item is Map) latest[item['code']?.toString() ?? ''] = Map<String, dynamic>.from(item);
            }
          }
        }
      }
    }
    return latest.values.where((e) => e['code']?.toString().isNotEmpty == true).toList();
  }

  List<Map<String, dynamic>> _codingItems() {
    final box = Hive.box('coding_box');
    final raw = box.get('${widget.companyCode}_items', defaultValue: []);
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  List<Map<String, dynamic>> _supplierRows() {
    final box = Hive.box('supplier_box');
    final sums = <String, double>{};
    for (final rawList in box.values) {
      if (rawList is! List) continue;
      for (final raw in rawList) {
        if (raw is! Map || raw['is_deleted'] == true) continue;
        if (raw['company_code']?.toString() != widget.companyCode || !_branchOk(raw['branch_code'])) continue;
        final d = DateTime.tryParse(raw['date']?.toString() ?? '');
        if (d == null || d.isAfter(_toDate)) continue;
        final name = raw['supplier_name']?.toString() ?? 'غير محدد';
        sums[name] = (sums[name] ?? 0) + _num(raw['total_amount']);
      }
    }
    final settlementBox = Hive.box('supplier_settlement_box');
    for (final rawList in settlementBox.values) {
      if (rawList is! List) continue;
      for (final raw in rawList) {
        if (raw is! Map || raw['is_deleted'] == true) continue;
        if (raw['company_code']?.toString() != widget.companyCode || !_branchOk(raw['branch_code'])) continue;
        final d = DateTime.tryParse(raw['date']?.toString() ?? '');
        if (d == null || d.isAfter(_toDate)) continue;
        final name = raw['supplier_name']?.toString() ?? 'غير محدد';
        sums[name] = (sums[name] ?? 0) - _num(raw['amount']);
      }
    }
    return sums.entries
        .map<Map<String, dynamic>>(
          (e) => {'المورد': e.key, 'الرصيد': e.value},
        )
        .toList()
      ..sort((a, b) => _num(b['الرصيد']).compareTo(_num(a['رصيد'])));
  }

  void _buildReport() {
    final tx = _transactions();
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic> summary = {};

    switch (widget.reportId) {
      case 1:
        final byDay = <String, double>{};
        for (final t in tx) {
          final d = t['date'].toString().substring(0, 10);
          final sign = t['type'] == 'وارد' ? 1 : -1;
          byDay[d] = (byDay[d] ?? 0) + sign * _num(t['amount']);
        }
        rows.addAll(byDay.entries.map<Map<String, dynamic>>((e) => {'التاريخ': e.key, 'صافي التدفق': e.value}).toList()..sort((a, b) => a['التاريخ'].toString().compareTo(b['التاريخ'].toString())));
        summary = {'صافي التدفق': rows.fold<double>(0.0, (s, r) => s + _num(r['صافي التدفق'])), 'متوسط التدفق اليومي': rows.isEmpty ? 0 : rows.fold<double>(0.0, (s, r) => s + _num(r['صافي التدفق'])) / rows.length};
        break;
      case 2:
        final cats = <String, double>{};
        for (final t in tx.where((e) => e['type'] == 'صادر')) {
          final c = t['category']?.toString() ?? 'عام';
          cats[c] = (cats[c] ?? 0) + _num(t['amount']);
        }
        rows.addAll(cats.entries.map<Map<String, dynamic>>((e) => {'الفئة': e.key, 'المبلغ': e.value, 'النسبة': cats.values.fold<double>(0.0, (s, v) => s + v) == 0 ? 0.0 : e.value / cats.values.fold<double>(0.0, (s, v) => s + v) * 100}).toList()..sort((a, b) => _num(b['المبلغ']).compareTo(_num(a['المبلغ']))));
        summary = {'إجمالي المصروفات': cats.values.fold<double>(0.0, (s, v) => s + v)};
        break;
      case 3:
        final branches = <String, double>{};
        for (final t in tx) {
          final b = t['branch_code']?.toString() ?? 'غير محدد';
          final sign = t['type'] == 'وارد' ? 1 : -1;
          branches[b] = (branches[b] ?? 0) + sign * _num(t['amount']);
        }
        rows.addAll(branches.entries.map<Map<String, dynamic>>((e) => {'الفرع': e.key, 'صافي الربح/الخسارة': e.value}));
        summary = {'إجمالي صافي الفروع': branches.values.fold(0.0, (s, v) => s + v)};
        break;
      case 4:
        final byDay = <String, double>{};
        final counts = <String, int>{};
        for (final t in tx.where((e) => e['type'] == 'وارد')) {
          final d = t['date'].toString().substring(0, 10);
          byDay[d] = (byDay[d] ?? 0) + _num(t['amount']);
          counts[d] = (counts[d] ?? 0) + 1;
        }
        rows.addAll(byDay.keys.map((d) => {'التاريخ': d, 'عدد الأذون': counts[d] ?? 0, 'إجمالي المبيعات': byDay[d] ?? 0, 'متوسط الإذن': (byDay[d] ?? 0) / ((counts[d] ?? 1))}));
        summary = {'متوسط قيمة الإذن': rows.isEmpty ? 0 : rows.fold<double>(0.0, (s, r) => s + _num(r['متوسط الإذن'])) / rows.length};
        break;
      case 5:
        final safes = <String, double>{};
        for (final t in tx) {
          final s = t['treasury']?.toString() ?? 'غير محدد';
          safes[s] = (safes[s] ?? 0) + (t['type'] == 'وارد' ? 1 : -1) * _num(t['amount']);
        }
        rows.addAll(safes.entries.map<Map<String, dynamic>>((e) => {'الخزينة': e.key, 'الرصيد': e.value}));
        summary = {'إجمالي أرصدة الخزائن': safes.values.fold(0.0, (s, v) => s + v)};
        break;
      case 6:
        final items = _inventoryItems();
        final coding = _codingItems();
        final names = {for (final i in coding) i['code']?.toString() ?? '': i['name']?.toString() ?? ''};
        final purchases = _purchases();
        final moved = <String, DateTime>{};
        for (final p in purchases) {
          final d = DateTime.tryParse(p['date']?.toString() ?? '');
          final its = p['items'];
          if (d != null && its is List) for (final x in its.whereType<Map>()) {
            final c = x['code']?.toString() ?? '';
            if (c.isNotEmpty && (moved[c] == null || d.isAfter(moved[c]!))) moved[c] = d;
          }
        }
        for (final i in items) {
          final c = i['code']?.toString() ?? '';
          final d = moved[c];
          if (d == null || _toDate.difference(d).inDays >= 90) {
            rows.add({
              'الكود': c,
              'الصنف': names[c] ?? i['name'] ?? 'غير معروف',
              'آخر حركة': d == null ? 'لا توجد' : DateFormat('yyyy-MM-dd').format(d),
              'الكمية': _num(i['quantity']),
              'قيمة الجملة': _num(i['quantity']) * _num(i['wholesalePrice'] ?? i['wholesale_price']),
            });
          }
        }
        summary = {'قيمة المخزون البطيء': rows.fold<double>(0.0, (s, r) => s + _num(r['قيمة الجملة']))};
        break;
      case 7:
        rows.add({'الحالة': 'تحتاج بيانات المبيعات التفصيلية للأصناف لحساب النظري مقابل الفعلي بدقة', 'البيانات المتاحة': 'آخر جرد فعلي محفوظ موجود ويمكن عرضه من شاشة رصيد المخزون'});
        summary = {'الحالة': 'غير مكتمل بدون حركات بيع مرتبطة بكود الصنف'};
        break;
      case 8:
        final items = _inventoryItems();
        final total = items.fold(0.0, (s, i) => s + _num(i['quantity']) * _num(i['wholesalePrice'] ?? i['wholesale_price']));
        var cumulative = 0.0;
        items.sort((a, b) => (_num(b['quantity']) * _num(b['wholesalePrice'] ?? b['wholesale_price'])).compareTo(_num(a['quantity']) * _num(a['wholesalePrice'] ?? a['wholesale_price'])));
        for (final i in items) {
          final value = _num(i['quantity']) * _num(i['wholesalePrice'] ?? i['wholesale_price']);
          cumulative += value;
          rows.add({
            'الكود': i['code'],
            'الصنف': i['name'],
            'الكمية': _num(i['quantity']),
            'قيمة الجملة': value,
            'النسبة التراكمية': total == 0 ? 0 : cumulative / total * 100,
            'ABC': total == 0 ? 'C' : cumulative / total <= .80 ? 'A' : cumulative / total <= .95 ? 'B' : 'C',
          });
        }
        summary = {'إجمالي قيمة المخزون بالجملة': total};
        break;
      case 9:
        rows.addAll(_supplierRows().map((e) => {'المورد': e['المورد'], 'حجم التعامل/الرصيد': e['الرصيد'], 'التقييم': 'يُستكمل تلقائياً مع إضافة بيانات مواعيد التسليم والخصومات'}));
        summary = {'عدد الموردين': rows.length};
        break;
      case 10:
        final p = _purchases();
        double discounts = 0, gross = 0;
        for (final x in p) {
          gross += _num(x['total_amount']);
          final its = x['items'];
          if (its is List) for (final i in its.whereType<Map>()) discounts += _num(i['discountAmount']);
        }
        rows.add({'إجمالي المشتريات': gross, 'إجمالي الخصومات المسجلة': discounts, 'التكلفة بعد الخصم': gross - discounts});
        summary = {'أثر الخصم': gross == 0 ? 0 : discounts / gross * 100};
        break;
      case 11:
        final months = <int, double>{};
        for (final t in tx.where((e) => e['type'] == 'وارد')) {
          final d = DateTime.tryParse(t['date']?.toString() ?? '');
          if (d != null) months[d.month] = (months[d.month] ?? 0) + _num(t['amount']);
        }
        for (final e in months.entries) rows.add({'الشهر': e.key, 'المبيعات': e.value});
        summary = {'أفضل شهر': rows.isEmpty ? 'لا يوجد' : rows.reduce((a, b) => _num(a['المبيعات']) > _num(b['المبيعات']) ? a : b)['الشهر']};
        break;
      case 12:
        final p = _purchases();
        final byCode = <String, double>{};
        for (final x in p) {
          final its = x['items'];
          if (its is List) for (final i in its.whereType<Map>()) {
            final c = i['code']?.toString() ?? '';
            byCode[c] = (byCode[c] ?? 0) + _num(i['total']);
          }
        }
        final coding = _codingItems();
        for (final i in coding) {
          final c = i['code']?.toString() ?? '';
          final cost = _num(i['wholesale_price'] ?? i['wholesalePrice']);
          final sell = _num(i['selling_price'] ?? i['sellingPrice']);
          if (c.isNotEmpty && sell > 0) {
            rows.add({
              'الكود': c,
              'الصنف': i['name'],
              'سعر الجملة': cost,
              'سعر البيع': sell,
              'الهامش المستهدف': (sell - cost) / sell * 100,
              'حجم الشراء': byCode[c] ?? 0,
            });
          }
        }
        summary = {'عدد الأصناف': rows.length};
        break;
      case 13:
        rows.add({'الحالة': 'تحليل التجميع يحتاج حركات مبيعات تحتوي على أصناف كل إذن.', 'المتاح': 'يمكن تشغيل التحليل تلقائياً بعد ربط أصناف المبيعات بكود الصنف.'});
        summary = {'الحالة': 'بانتظار بيانات Basket تفصيلية'};
        break;
    }
    _rows = rows;
    _summary = summary;
  }

  @override
  void initState() {
    super.initState();
    _fromDate = widget.fromDate;
    _toDate = widget.toDate;
    _buildReport();
    _loading = false;
  }

  // دوال اختيار التاريخ
  Future<void> _selectDate(BuildContext context, bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _fromDate : _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Colors.blueAccent,
            onPrimary: Colors.white,
            surface: Color.fromARGB(255, 30, 30, 30),
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
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
      _buildReport(); // إعادة بناء التقرير عند تغيير التاريخ
    }
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

  // دوال التصدير
  Future<void> _exportExcel() async {
    await ExportService.exportToExcel(
      _rows,
      _title,
      _rows.isEmpty ? [] : _rows.first.keys.toList(),
      _rows.isEmpty ? [] : _rows.first.keys.toList(),
      branchName: widget.selectedBranchCode ?? 'كل الفروع',
      period: '${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}',
      summary: _summary,
    );
  }

  Future<void> _exportPdf() async {
    await ExportService.exportToPDF(
      data: _rows,
      title: _title,
      headers: _rows.isEmpty ? [] : _rows.first.keys.toList(),
      keys: _rows.isEmpty ? [] : _rows.first.keys.toList(),
      branchName: widget.selectedBranchCode ?? 'كل الفروع',
      period: '${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}',
      summary: _summary,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (PermissionsService().canShareReports)
            PopupMenuButton<String>(
              icon: const Icon(Icons.share, color: Colors.cyanAccent),
              onSelected: (value) {
                if (value == 'excel') _exportExcel();
                if (value == 'pdf') _exportPdf();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'excel',
                  child: Row(
                    children: [
                      Icon(Icons.table_chart, color: Colors.greenAccent),
                      SizedBox(width: 8),
                      Text('Excel'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'pdf',
                  child: Row(
                    children: [
                      Icon(Icons.picture_as_pdf, color: Colors.redAccent),
                      SizedBox(width: 8),
                      Text('PDF'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Color(0xFF1A237E), Colors.black],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      // أزرار اختيار التاريخ
                      Row(
                        children: [
                          Expanded(child: _dateButton("من", _fromDate, () => _selectDate(context, true))),
                          const SizedBox(width: 10),
                          Expanded(child: _dateButton("إلى", _toDate, () => _selectDate(context, false))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // معلومات الفرع والفترة
                      GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'من ${DateFormat('yyyy-MM-dd').format(_fromDate)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate)}',
                                  style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
                                ),
                              ),
                              Text(
                                widget.selectedBranchCode == null || widget.selectedBranchCode == 'all'
                                    ? 'كل الفروع'
                                    : 'الفرع: ${widget.selectedBranchCode}',
                                style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // جدول التقرير
                      Expanded(
                        child: GlassCard(
                          child: _rows.isEmpty
                              ? const Center(
                                  child: Text(
                                    'لا توجد بيانات كافية للفترة المحددة',
                                    style: TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
                                  ),
                                )
                              : SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SingleChildScrollView(
                                    child: DataTable(
                                      headingRowColor: MaterialStateProperty.all(Colors.white10),
                                      columns: _rows.first.keys
                                          .map((k) => DataColumn(
                                                label: Text(
                                                  k,
                                                  style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo'),
                                                ),
                                              ))
                                          .toList(),
                                      rows: _rows
                                          .map(
                                            (r) => DataRow(
                                              cells: r.values
                                                  .map(
                                                    (v) => DataCell(
                                                      Text(
                                                        v is num ? v.toStringAsFixed(2) : v.toString(),
                                                        style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
                                                      ),
                                                    ),
                                                  )
                                                  .toList(),
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      if (_summary.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _summary.entries
                                .map(
                                  (e) => Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(.06),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '${e.key}: ${e.value is num ? e.value.toStringAsFixed(2) : e.value}',
                                      style: const TextStyle(color: Colors.amber, fontFamily: 'Cairo'),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}