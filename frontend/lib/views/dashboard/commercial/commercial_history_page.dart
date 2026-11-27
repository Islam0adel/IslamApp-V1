// frontend/lib/views/dashboard/commercial/commercial_history_page.dart
import '../../../services/cache_partitions.dart';

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/commercial_service.dart';
import '../../../services/permissions_service.dart';
import 'commercial_shared.dart';
import 'customer_payments_page.dart';
import 'sale_return_page.dart';

// صفحة معاينة المرتجعات أو تحصيلات العملاء
class CommercialHistoryPage extends StatefulWidget {
  final String companyCode;
  final String kind;
  final String title;
  final String? branchCode;
  const CommercialHistoryPage(
      {super.key,
      required this.companyCode,
      required this.kind,
      required this.title,
      this.branchCode});
  // ينشئ كائن الحالة المرتبط بهذه الصفحة
  @override
  State<CommercialHistoryPage> createState() => _CommercialHistoryPageState();
}

// حالة الويدجت CommercialHistoryPage: تدير بيانات الشاشة وتفاعلاتها
class _CommercialHistoryPageState extends State<CommercialHistoryPage> {
  final _service = CommercialService();
  List<JMap> _rows = [];
  bool _busy = true;
  StreamSubscription<BoxEvent>? _recordsSubscription;

  // يعيد اسم صندوق السجلات حسب النوع
  String get _boxName =>
      widget.kind == 'returns' ? 'sales_returns_box' : 'customer_payments_box';

  /// تجميع أحداث المزامنة المتتابعة في تحميل واحد.
  Timer? _watchDebounce;
  // يهيّئ الحالة ويشترك في تغيّرات التخزين المحلي
  @override
  void initState() {
    super.initState();
    _recordsSubscription = CachePartitions.box(_boxName).watch().listen((_) {
      _watchDebounce?.cancel();
      _watchDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _load();
      });
    });
    _load();
  }

  // يحمّل بيانات الشاشة
  @override
  void dispose() {
    _watchDebounce?.cancel();
    _recordsSubscription?.cancel();
    super.dispose();
  }

  // يحمّل بيانات الشاشة
  Future<void> _load() async {
    return CachePartitions.run(() async {
      try {
        _rows = await _service.fetch(widget.kind, widget.companyCode,
            branchCode: widget.branchCode);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    });
  }

  // يحدّث البيانات من الخادم
  Future<void> _refreshFromServer() async {
    return CachePartitions.run(() async {
      await _service.fetch(widget.kind, widget.companyCode,
          branchCode: widget.branchCode, forceRefresh: true);
      await _load();
    });
  }

  // يعيد اسم فئة الصلاحية حسب النوع
  String get _category =>
      widget.kind == 'returns' ? 'المرتجعات' : 'حسابات العملاء';

  // يحذف سجلًا بعد التحقق من الصلاحية
  Future<void> _delete(JMap r) async {
    return CachePartitions.run(() async {
      try {
        await _service.delete(widget.kind, widget.companyCode, '${r['id']}');
        await _load();
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
      }
    });
  }

  // يبني واجهة الصفحة
  @override
  Widget build(BuildContext context) => CommercialPageFrame(
      title: widget.title,
      child: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshFromServer,
              child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: _rows.map((r) {
                    final title =
                        'إذن ${r['serial']} · ${r['customer_name'] ?? ''}';
                    final amount = n(r['total'] ??
                        r['amount'] ??
                        ((r['items'] is List)
                            ? (r['items'] as List)
                                .whereType<Map>()
                                .fold<double>(
                                    0,
                                    (sum, item) =>
                                        sum +
                                        n(item['quantity']) * n(item['price']))
                            : 0));
                    return Card(
                        child: ListTile(
                            title: Text(title),
                            subtitle: Text(
                                '${r['date']} · ${money(amount)}${r['sync_status'] == 'pending' ? ' · بانتظار المزامنة' : ''}${r['sync_status'] == 'error' ? ' · تعذرت المزامنة' : ''}${r['sync_status'] == 'conflict' ? ' · تغيّر على جهاز آخر؛ حدّث القائمة' : ''}'),
                            trailing: Wrap(children: [
                              if (widget.kind == 'customer-payments' &&
                                  PermissionsService()
                                      .hasPermission(_category, 'تعديل تحصيل'))
                                IconButton(
                                    icon: const Icon(Icons.edit),
                                    onPressed: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    CustomerPaymentsPage(
                                                        companyCode:
                                                            widget.companyCode,
                                                        branchCode:
                                                            widget.branchCode,
                                                        editItem: r)))
                                        .then((_) => _load())),
                              if (widget.kind == 'returns' &&
                                  PermissionsService().canEditSaleReturn)
                                IconButton(
                                    icon: const Icon(Icons.edit),
                                    onPressed: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => SaleReturnPage(
                                                companyCode: widget.companyCode,
                                                selectedBranchCode:
                                                    widget.branchCode,
                                                editItem:
                                                    r))).then((_) => _load())),
                              if (PermissionsService().hasPermission(
                                  _category,
                                  widget.kind == 'customer-payments'
                                      ? 'حذف تحصيل'
                                      : 'حذف'))
                                IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _delete(r))
                            ])));
                  }).toList())));
}
