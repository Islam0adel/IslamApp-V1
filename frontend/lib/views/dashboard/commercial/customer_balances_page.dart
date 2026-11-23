import '../../../services/cache_partitions.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/commercial_service.dart';
import 'commercial_shared.dart';

class CustomerBalancesPage extends StatefulWidget { final String companyCode; final String? branchCode; const CustomerBalancesPage({super.key, required this.companyCode, this.branchCode}); @override State<CustomerBalancesPage> createState() => _CustomerBalancesPageState(); }
class _CustomerBalancesPageState extends State<CustomerBalancesPage> {
  final _service = CommercialService(); List<JMap> _rows = []; bool _busy = true;
  final List<StreamSubscription<BoxEvent>> _subscriptions = [];
  /// تجميع أحداث المزامنة المتتابعة في تحميل واحد.
  Timer? _watchDebounce;
  @override void initState() { super.initState(); for (final name in ['sales_box', 'sales_returns_box', 'customer_payments_box']) { _subscriptions.add(CachePartitions.box(name).watch().listen((_) {
        _watchDebounce?.cancel();
        _watchDebounce = Timer(const Duration(milliseconds: 300), () {
          if (mounted) _load();
        });
      })); } _load(); }
  @override void dispose() { _watchDebounce?.cancel(); for (final subscription in _subscriptions) { subscription.cancel(); } super.dispose(); }
  Future<void> _load() async {
return CachePartitions.run(() async {
 try { final balances = await _service.customerBalances(widget.companyCode, branchCode: widget.branchCode); _rows = balances.map((r) => {'code': r['customer_code'], 'name': r['customer_name'], 'balance': n(r['balance'])}).toList(); } catch (_) {} if (mounted) setState(() => _busy = false);
});
}
  Future<void> _refreshFromServer() async {
return CachePartitions.run(() async {
 await _service.customerBalances(widget.companyCode, branchCode: widget.branchCode, forceRefresh: true); await _load();
});
}
  @override Widget build(BuildContext context) => CommercialPageFrame(title: 'أرصدة العملاء', child: _busy ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _refreshFromServer, child: ListView(padding: const EdgeInsets.all(14), children: _rows.map<Widget>((r) => Card(
  child: ListTile(
    title: Text('${r['name']}'),
    subtitle: Text('كود ${r['code']}'),
    trailing: Text(
      money(n(r['balance'])),
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
  ),
)).toList(),)));
}
