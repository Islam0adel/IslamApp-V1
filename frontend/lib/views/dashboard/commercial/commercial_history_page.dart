import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/commercial_service.dart';
import '../../../services/permissions_service.dart';
import 'commercial_shared.dart';
import 'customer_payments_page.dart';
import 'sale_return_page.dart';

class CommercialHistoryPage extends StatefulWidget {
  final String companyCode; final String kind; final String title; final String? branchCode;
  const CommercialHistoryPage({super.key, required this.companyCode, required this.kind, required this.title, this.branchCode});
  @override State<CommercialHistoryPage> createState() => _CommercialHistoryPageState();
}
class _CommercialHistoryPageState extends State<CommercialHistoryPage> {
  final _service = CommercialService(); List<JMap> _rows = []; bool _busy = true;
  StreamSubscription<BoxEvent>? _recordsSubscription;
  String get _boxName => widget.kind == 'returns' ? 'sales_returns_box' : 'customer_payments_box';
  @override void initState() { super.initState(); _recordsSubscription = Hive.box(_boxName).watch().listen((_) => _load()); _load(); }
  @override void dispose() { _recordsSubscription?.cancel(); super.dispose(); }
  Future<void> _load() async { try { _rows = await _service.fetch(widget.kind, widget.companyCode, branchCode: widget.branchCode); } catch (_) {} if (mounted) setState(() => _busy = false); }
  Future<void> _refreshFromServer() async { await _service.fetch(widget.kind, widget.companyCode, branchCode: widget.branchCode, forceRefresh: true); await _load(); }
  String get _category => widget.kind == 'returns' ? 'المرتجعات' : 'حسابات العملاء';
  Future<void> _delete(JMap r) async { try { await _service.delete(widget.kind, widget.companyCode, '${r['id']}'); await _load(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); } }
  @override Widget build(BuildContext context) => CommercialPageFrame(title: widget.title, child: _busy ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _refreshFromServer, child: ListView(padding: const EdgeInsets.all(14), children: _rows.map((r) { final title = 'إذن ${r['serial']} · ${r['customer_name'] ?? ''}'; final amount = n(r['total'] ?? r['amount'] ?? ((r['items'] is List) ? (r['items'] as List).whereType<Map>().fold<double>(0, (sum, item) => sum + n(item['quantity']) * n(item['price'])) : 0)); return Card(child: ListTile(title: Text(title), subtitle: Text('${r['date']} · ${money(amount)}${r['sync_status'] == 'pending' ? ' · بانتظار المزامنة' : ''}${r['sync_status'] == 'error' ? ' · تعذرت المزامنة' : ''}${r['sync_status'] == 'conflict' ? ' · تغيّر على جهاز آخر؛ حدّث القائمة' : ''}'), trailing: Wrap(children: [if (widget.kind == 'customer-payments' && PermissionsService().hasPermission(_category, 'تعديل تحصيل')) IconButton(icon: const Icon(Icons.edit), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPaymentsPage(companyCode: widget.companyCode, branchCode: widget.branchCode, editItem: r))).then((_) => _load())), if (widget.kind == 'returns' && PermissionsService().canEditSaleReturn) IconButton(icon: const Icon(Icons.edit), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SaleReturnPage(companyCode: widget.companyCode, selectedBranchCode: widget.branchCode, editItem: r))).then((_) => _load())), if (PermissionsService().hasPermission(_category, widget.kind == 'customer-payments' ? 'حذف تحصيل' : 'حذف')) IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r))]))); }).toList())));
}
