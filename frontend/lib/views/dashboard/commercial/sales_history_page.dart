// frontend/lib/views/dashboard/commercial/sales_history_page.dart
import '../../../services/cache_partitions.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../services/commercial_service.dart';
import '../../../services/permissions_service.dart';
import 'commercial_shared.dart';
import 'sales_page.dart';

// صفحة معاينة المبيعات
class SalesHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? branchCode;
  final String? userName;
  const SalesHistoryPage(
      {super.key, required this.companyCode, this.branchCode, this.userName});
  // ينشئ كائن الحالة المرتبط بهذه الصفحة
  @override
  State<SalesHistoryPage> createState() => _SalesHistoryPageState();
}

// حالة الويدجت SalesHistoryPage: تدير بيانات الشاشة وتفاعلاتها
class _SalesHistoryPageState extends State<SalesHistoryPage> {
  final _service = CommercialService();
  List<JMap> _records = [];
  bool _busy = true;
  StreamSubscription<BoxEvent>? _salesSubscription;

  /// تجميع أحداث المزامنة المتتابعة في تحميل واحد.
  Timer? _watchDebounce;
  // يهيّئ الحالة ويشترك في تغيّرات التخزين المحلي
  @override
  void initState() {
    super.initState();
    _salesSubscription = CachePartitions.box('sales_box').watch().listen((_) {
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
    _salesSubscription?.cancel();
    super.dispose();
  }

  // يحمّل بيانات الشاشة
  Future<void> _load() async {
    return CachePartitions.run(() async {
      try {
        _records = await _service.fetch('sales', widget.companyCode,
            branchCode: widget.branchCode);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    });
  }

  // يحدّث البيانات من الخادم
  Future<void> _refreshFromServer() async {
    return CachePartitions.run(() async {
      await _service.fetch('sales', widget.companyCode,
          branchCode: widget.branchCode, forceRefresh: true);
      await _load();
    });
  }

  // يحذف فاتورة بعد التحقق من الصلاحية
  Future<void> _delete(JMap r) async {
    return CachePartitions.run(() async {
      try {
        await _service.delete('sales', widget.companyCode, '${r['id']}');
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
      title: 'معاينة المبيعات',
      child: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshFromServer,
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: _records
                    .map<Widget>((r) => Card(
                          child: ListTile(
                            title: Text(
                                'فاتورة ${r['serial']} · ${r['customer_name']}'),
                            subtitle: Text(
                              '${r['date']} · الإجمالي ${money(n(r['total']))} · الباقي ${money(n(r['due']))}'
                              '${r['sync_status'] == 'pending' ? ' · بانتظار المزامنة' : ''}'
                              '${r['sync_status'] == 'error' ? ' · تعذرت المزامنة، تحقق من الاتصال والصلاحية' : ''}'
                              '${r['sync_status'] == 'conflict' ? ' · تغيّرت على جهاز آخر؛ حدّث القائمة ثم أعد تطبيق تعديلك' : ''}',
                            ),
                            trailing: Wrap(
                              children: [
                                if (PermissionsService()
                                    .hasPermission('المبيعات', 'تعديل'))
                                  IconButton(
                                    icon: const Icon(Icons.edit),
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => SalesPage(
                                          companyCode: widget.companyCode,
                                          selectedBranchCode: widget.branchCode,
                                          userName: widget.userName,
                                          editItem: r,
                                        ),
                                      ),
                                    ).then((_) => _load()),
                                  ),
                                if (PermissionsService()
                                    .hasPermission('المبيعات', 'حذف'))
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _delete(r),
                                  ),
                              ],
                            ),
                          ),
                        ))
                    .toList(),
              )));
}
