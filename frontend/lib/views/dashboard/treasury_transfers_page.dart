import '../../services/cache_partitions.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/permissions_service.dart';
import '../../services/treasury_transfer_service.dart';
import 'treasury_transfer_page.dart';

class TreasuryTransfersPage extends StatefulWidget {
  final String companyCode;
  final String? branchCode;
  final String? userName;
  const TreasuryTransfersPage(
      {super.key, required this.companyCode, this.branchCode, this.userName});
  @override
  State<TreasuryTransfersPage> createState() => _TreasuryTransfersPageState();
}

class _TreasuryTransfersPageState extends State<TreasuryTransfersPage> {
  final _service = TreasuryTransferService();
  StreamSubscription<BoxEvent>? _subscription;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (CachePartitions.isBoxOpen(TreasuryTransferService.recordsBox)) {
      _subscription =
          CachePartitions.box(TreasuryTransferService.recordsBox).watch().listen((_) {
        if (mounted) setState(() {});
      });
    }
    if (!_service.hasSnapshot(TreasuryTransferService.recordsBox, widget.companyCode)) {
      _refresh(force: false);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool force = true}) async {
return CachePartitions.run(() async {

    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (force) {
        await _service.sync(widget.companyCode);
      } else {
        await _service.ensureCached(widget.companyCode);
      }
    } catch (_) {
      if (mounted)
        _error = 'تعذر التحديث. المعروض آخر بيانات محفوظة، أعد المحاولة.';
    }
    if (mounted) setState(() => _busy = false);
});
}

  Future<void> _open([Map<String, dynamic>? record]) async {
return CachePartitions.run(() async {

    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => TreasuryTransferPage(
                companyCode: widget.companyCode,
                selectedBranchCode:
                    record?['branch_code']?.toString() ?? widget.branchCode,
                userName: widget.userName,
                editItem: record)));
    if (mounted) setState(() {});
});
}

  Future<void> _delete(Map<String, dynamic> record) async {
return CachePartitions.run(() async {

    final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('حذف التحويل؟'),
                content: Text(
                    'تحويل ${record['serial']} بقيمة ${record['amount']} من ${record['from_treasury']} إلى ${record['to_treasury']}. سيتم عكس أثره على الخزينتين.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('إلغاء')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('حذف'))
                ]));
    if (agreed != true ||
        !mounted ||
        !PermissionsService().canDeleteTreasuryTransfer) return;
    setState(() => _busy = true);
    try {
      final result = await _service.delete(record);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['refresh_pending'] == true
                ? 'تم الحذف، لكن تحديث الأرصدة لم يكتمل. اضغط تحديث.'
                : 'تم حذف التحويل وعكس أثره.')));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('لم يتم تأكيد الحذف. حدّث البيانات قبل إعادة المحاولة.')));
    }
    if (mounted) {
      setState(() => _busy = false);
    }
});
}

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: PermissionsService(),
      builder: (context, _) {
        final p = PermissionsService();
        final records = _service.localRecords(widget.companyCode,
            branchCode: widget.branchCode);
        return Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              appBar: AppBar(title: const Text('تحويلات الخزائن'), actions: [
                IconButton(
                    tooltip: 'تحديث',
                    onPressed: _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh)),
                if (p.canAddTreasuryTransfer)
                  IconButton(
                      tooltip: 'تحويل جديد',
                      onPressed: _busy ? null : () => _open(),
                      icon: const Icon(Icons.add)),
              ]),
              body: Column(children: [
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                        'التحويل يغيّر رصيد الخزينتين، ولا يدخل في إجمالي الوارد والصادر. قسم مستقل عن اليومية وخزائن المبيعات.')),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                Expanded(
                    child: !p.canViewTreasuryTransfers
                        ? Center(
                            child: Text(p.canAddTreasuryTransfer
                                ? 'يمكنك إضافة تحويل جديد من زر +. معاينة السجل تحتاج صلاحية مستقلة.'
                                : 'ليس لديك صلاحية معاينة تحويلات الخزائن.'))
                        : records.isEmpty
                            ? const Center(
                                child: Text(
                                    'لا توجد تحويلات جديدة محفوظة لهذا الفرع.'))
                            : RefreshIndicator(
                                onRefresh: _refresh,
                                child: ListView.builder(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.all(12),
                                    itemCount: records.length,
                                    itemBuilder: (context, index) {
                                      final row = records[index];
                                      return Card(
                                          child: Padding(
                                              padding: const EdgeInsets.all(12),
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    Text(
                                                        'تحويل ${row['serial']} · ${row['date']}',
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .titleMedium),
                                                    Text(
                                                        'من ${row['from_treasury']} إلى ${row['to_treasury']}'),
                                                    Text(
                                                        '${row['amount']} · الفرع ${row['branch_code']}'),
                                                    if ((row['statement']
                                                                ?.toString() ??
                                                            '')
                                                        .isNotEmpty)
                                                      Text(row['statement']
                                                          .toString()),
                                                    if (p.canEditTreasuryTransfer ||
                                                        p
                                                            .canDeleteTreasuryTransfer)
                                                      Wrap(
                                                          alignment:
                                                              WrapAlignment.end,
                                                          children: [
                                                            if (p
                                                                .canEditTreasuryTransfer)
                                                              TextButton.icon(
                                                                  onPressed: _busy
                                                                      ? null
                                                                      : () =>
                                                                          _open(
                                                                              row),
                                                                  icon: const Icon(
                                                                      Icons
                                                                          .edit_outlined),
                                                                  label: const Text(
                                                                      'تعديل')),
                                                            if (p
                                                                .canDeleteTreasuryTransfer)
                                                              TextButton.icon(
                                                                  onPressed: _busy
                                                                      ? null
                                                                      : () =>
                                                                          _delete(
                                                                              row),
                                                                  icon: const Icon(
                                                                      Icons
                                                                          .delete_outline),
                                                                  label:
                                                                      const Text(
                                                                          'حذف')),
                                                          ]),
                                                  ])));
                                    }))),
              ]),
            ));
      });
}
