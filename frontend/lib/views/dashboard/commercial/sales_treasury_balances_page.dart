import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/commercial_service.dart';
import 'commercial_shared.dart';

class SalesTreasuryBalancesPage extends StatefulWidget { final String companyCode; final String? branchCode; const SalesTreasuryBalancesPage({super.key, required this.companyCode, this.branchCode}); @override State<SalesTreasuryBalancesPage> createState() => _SalesTreasuryBalancesPageState(); }
class _SalesTreasuryBalancesPageState extends State<SalesTreasuryBalancesPage> {
  final _service = CommercialService(); Map<String, double> _balances = {}; bool _busy = true;
  final List<StreamSubscription<BoxEvent>> _subscriptions = [];
  @override void initState() { super.initState(); for (final name in ['sales_box', 'sales_returns_box', 'customer_payments_box']) { _subscriptions.add(Hive.box(name).watch().listen((_) => _load())); } _load(); }
  @override void dispose() { for (final subscription in _subscriptions) { subscription.cancel(); } super.dispose(); }
  Future<void> _load() async { try { _balances = await _service.treasuryBalances(widget.companyCode, branchCode: widget.branchCode); } catch (_) {} if (mounted) setState(() => _busy = false); }
  Future<void> _refreshFromServer() async { await _service.treasuryBalances(widget.companyCode, branchCode: widget.branchCode, forceRefresh: true); await _load(); }
  @override Widget build(BuildContext context) => CommercialPageFrame(title: 'أرصدة خزائن المبيعات', child: _busy ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _refreshFromServer, child: ListView(padding: const EdgeInsets.all(14), children: _balances.entries.map<Widget>((e) => Card(child: ListTile(leading: const Icon(Icons.account_balance_wallet), title: Text(e.key), trailing: Text(money(e.value), style: const TextStyle(fontWeight: FontWeight.bold))))).toList())));
}
