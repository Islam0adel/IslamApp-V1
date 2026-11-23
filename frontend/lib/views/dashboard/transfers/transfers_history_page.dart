import '../../../services/cache_partitions.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/permissions_service.dart';
import '../../../services/transfers_service.dart';
import '../commercial/commercial_shared.dart';
import 'stock_transfers_page.dart';

/// ⭐ معاينة التحويلات المخزنية — صفحة مستقلة ضمن وحدة التحويلات
/// (الموردين والمشتريات)، بدل مشاركة صفحة السجل مع المبيعات.
class TransfersHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? branchCode;
  final String? userName;
  const TransfersHistoryPage({super.key, required this.companyCode, this.branchCode, this.userName});
  @override
  State<TransfersHistoryPage> createState() => _TransfersHistoryPageState();
}

class _TransfersHistoryPageState extends State<TransfersHistoryPage> {
  final _service = TransfersService();
  List<JMap> _rows = [];
  bool _busy = true;
  StreamSubscription<BoxEvent>? _recordsSubscription;
  /// تجميع أحداث المزامنة المتتابعة في تحميل واحد.
  Timer? _watchDebounce;

  @override
  void initState() {
    super.initState();
    _recordsSubscription = CachePartitions.box('stock_transfers_box').watch().listen((_) {
      _watchDebounce?.cancel();
      _watchDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _load();
      });
    });
    _load();
  }

  @override
  void dispose() {
    _watchDebounce?.cancel();
    _recordsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
return CachePartitions.run(() async {

    try {
      _rows = await _service.fetch(widget.companyCode, branchCode: widget.branchCode);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
});
}

  Future<void> _refreshFromServer() async {
return CachePartitions.run(() async {

    await _service.fetch(widget.companyCode, branchCode: widget.branchCode, forceRefresh: true);
    await _load();
});
}

  Future<void> _delete(JMap r) async {
return CachePartitions.run(() async {

    try {
      await _service.delete(widget.companyCode, '${r['id']}');
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
});
}

  @override
  Widget build(BuildContext context) => CommercialPageFrame(
        title: 'معاينة التحويلات المخزنية',
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _refreshFromServer,
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: _rows.map((r) {
                    final title = 'تحويل ${r['serial']} · ${r['from_branch_code']}/${r['from_store_code']} ← ${r['to_branch_code']}/${r['to_store_code']}';
                    final amount = n(r['total'] ?? r['amount'] ?? ((r['items'] is List) ? (r['items'] as List).whereType<Map>().fold<double>(0, (sum, item) => sum + n(item['quantity']) * n(item['price'])) : 0));
                    return Card(
                      child: ListTile(
                        title: Text(title),
                        subtitle: Text(
                          '${r['date']} · ${money(amount)}'
                          '${r['sync_status'] == 'pending' ? ' · بانتظار المزامنة' : ''}'
                          '${r['sync_status'] == 'error' ? ' · تعذرت المزامنة' : ''}'
                          '${r['sync_status'] == 'conflict' ? ' · تغيّر على جهاز آخر؛ حدّث القائمة' : ''}',
                        ),
                        trailing: Wrap(children: [
                          if (PermissionsService().canEditStockTransfer)
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => StockTransfersPage(
                                    companyCode: widget.companyCode,
                                    branchCode: widget.branchCode,
                                    userName: widget.userName,
                                    editItem: r,
                                  ),
                                ),
                              ).then((_) => _load()),
                            ),
                          if (PermissionsService().hasPermission('التحويلات المخزنية', 'حذف'))
                            IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
                        ]),
                      ),
                    );
                  }).toList(),
                ),
              ),
      );
}
