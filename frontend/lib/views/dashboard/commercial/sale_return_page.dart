import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/commercial_service.dart';
import 'commercial_shared.dart';

class SaleReturnPage extends StatefulWidget {
  final String companyCode; final String? selectedBranchCode; final String? userName; final JMap? editItem;
  const SaleReturnPage({super.key, required this.companyCode, this.selectedBranchCode, this.userName, this.editItem});
  @override State<SaleReturnPage> createState() => _SaleReturnPageState();
}
class _SaleReturnPageState extends State<SaleReturnPage> {
  final _service = CommercialService();
  List<JMap> _sales = [], _stores = [], _methods = [], _safes = [];
  final _lines = <ReturnLine>[];
  JMap? _sale;
  String? _store, _method, _safe;
  bool _busy = false;
  final List<StreamSubscription<BoxEvent>> _localSubscriptions = [];
  Timer? _catalogDebounce;
  Timer? _watchDebounce;

  /// نبضة تحديث مقصورة على ملخص المرتجع بدل إعادة بناء الصفحة كلها.
  final _totals = ValueNotifier<int>(0);
  double _customerBalance = 0;
  String _settlementMode = 'credit_first';
  final Map<String, double> _alreadyReturned = {};

  List<JMap> get _invoiceItems => (_sale?['items'] as List? ?? [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();

  double _availableQuantity(JMap item) =>
      (n(item['quantity']) - (_alreadyReturned['${item['code']}'] ?? 0))
          .clamp(0, double.infinity)
          .toDouble();

  List<JMap> _optionsFor(ReturnLine line) => _invoiceItems.where((item) {
    if (_availableQuantity(item) <= 0) return false;
    return !_lines.any((other) =>
      !identical(other, line) &&
      other.product?['code']?.toString() == item['code']?.toString());
  }).toList();

  bool get _hasAvailableReturnItem => !_lines.any((line) => line.product == null) && _invoiceItems.any((item) =>
    _availableQuantity(item) > 0 && !_lines.any((line) =>
      line.product?['code']?.toString() == item['code']?.toString()));

  double get _returnTotal => _lines.fold<double>(
    0,
    (sum, line) => sum + (line.product == null ? 0 : line.amount),
  );

  double get _creditAmount => _settlementMode == 'credit_first'
      ? (_returnTotal < _customerBalance ? _returnTotal : _customerBalance)
      : 0;
  double get _refundAmount => (_returnTotal - _creditAmount).clamp(0, double.infinity).toDouble();

  @override
  void initState() {
    super.initState();
    for (final name in ['sales_box', 'sales_returns_box', 'customer_payments_box']) {
      _localSubscriptions.add(Hive.box(name).watch().listen((_) {
        _watchDebounce?.cancel();
        _watchDebounce = Timer(const Duration(milliseconds: 300), () {
          if (mounted) _refreshSelectedSaleContext();
        });
      }));
    }
    _localSubscriptions.add(Hive.box('coding_box').watch().listen((_) => _onCatalogChanged()));
    _load();
  }

  /// تحديث قوائم المخازن وطرق الدفع والخزائن عند مزامنة الكتالوج دون لمس
  /// سطور المرتجع أو الفاتورة المختارة.
  void _onCatalogChanged() {
    _catalogDebounce?.cancel();
    _catalogDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        final branch = widget.editItem?['branch_code']?.toString() ?? widget.selectedBranchCode;
        _stores = storesForBranch(widget.companyCode, branch);
        _methods = catalog(widget.companyCode, 'payment_methods');
        _safes = catalog(widget.companyCode, 'safes');
      });
    });
  }

  @override
  void dispose() {
    _catalogDebounce?.cancel();
    _watchDebounce?.cancel();
    _totals.dispose();
    for (final subscription in _localSubscriptions) {
      subscription.cancel();
    }
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshSelectedSaleContext() async {
    final selectedId = _sale?['id']?.toString();
    try {
      _sales = await _service.fetch('sales', widget.companyCode,
          branchCode: widget.editItem?['branch_code']?.toString() ?? widget.selectedBranchCode);
      if (selectedId == null) {
        if (mounted) setState(() {});
        return;
      }
      final refreshedSale = _sales.where((row) => row['id']?.toString() == selectedId).firstOrNull;
      if (refreshedSale == null) return;
      final state = await _service.returnableSale(widget.companyCode, selectedId,
          toDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
          excludeReturnId: widget.editItem?['id']?.toString());
      final remaining = state['remaining_quantities'] is Map
          ? Map<String, dynamic>.from(state['remaining_quantities'] as Map)
          : <String, dynamic>{};
      _alreadyReturned.clear();
      for (final item in (refreshedSale['items'] as List? ?? []).whereType<Map>()) {
        final code = '${item['code']}';
        _alreadyReturned[code] = (n(item['quantity']) - n(remaining[code]))
            .clamp(0, double.infinity).toDouble();
      }
      _sale = refreshedSale;
      _customerBalance = n(state['customer_balance']);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _load() async {
    final branch = widget.editItem?['branch_code']?.toString() ?? widget.selectedBranchCode;
    try {
      _sales = await _service.fetch('sales', widget.companyCode, branchCode: branch);
    } catch (_) {}
    _stores = storesForBranch(widget.companyCode, branch);
    _methods = catalog(widget.companyCode, 'payment_methods');
    _safes = catalog(widget.companyCode, 'safes');
    _method = _methods.firstOrNull?['name']?.toString();
    _safe = _safes.firstOrNull?['name']?.toString();
    if (widget.editItem != null) {
      _store = widget.editItem!['store_code']?.toString();
      _settlementMode = widget.editItem!['settlement_mode']?.toString() ?? 'credit_first';
      final payment = (widget.editItem!['payments'] as List?)?.firstOrNull;
      if (payment is Map) {
        _method = payment['method']?.toString();
        _safe = payment['treasury']?.toString();
      }
      final sale = _sales.where((row) => row['id']?.toString() ==
          widget.editItem!['sale_id']?.toString()).firstOrNull;
      if (sale != null) await _selectSale(sale);
    }
    if (mounted) setState(() {});
  }

  Future<void> _selectSale(JMap? value) async {
    for (final line in _lines) {
      line.dispose();
    }
    _lines.clear();
    _alreadyReturned.clear();
    _customerBalance = 0;
    _sale = value;
    if (value != null) {
      try {
        final state = await _service.returnableSale(
          widget.companyCode, '${value['id']}',
          toDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
          excludeReturnId: widget.editItem?['id']?.toString(),
        );
        final remaining = state['remaining_quantities'] is Map
            ? Map<String, dynamic>.from(state['remaining_quantities'] as Map)
            : <String, dynamic>{};
        for (final item in _invoiceItems) {
          final code = '${item['code']}';
          _alreadyReturned[code] = (n(item['quantity']) - n(remaining[code])).clamp(0, double.infinity).toDouble();
        }
        _customerBalance = n(state['customer_balance']);
      } catch (_) {}
      if (widget.editItem != null && widget.editItem!['sale_id']?.toString() == value['id']?.toString() && widget.editItem!['items'] is List) {
        for (final item in (widget.editItem!['items'] as List).whereType<Map>()) {
          final product = _invoiceItems.where((row) => row['code']?.toString() == item['code']?.toString()).firstOrNull;
          if (product != null) {
            _lines.add(ReturnLine(product: product, quantity: n(item['quantity'])));
          }
        }
      }
      if (_hasAvailableReturnItem) _lines.add(ReturnLine());
    }
    if (mounted) setState(() {});
  }

  void _addReturnLine() {
    if (_sale == null || !_hasAvailableReturnItem) return;
    final line = ReturnLine();
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) line.nameFocus.requestFocus();
    });
  }

  void _selectReturnProduct(ReturnLine line, JMap product) {
    if (_lines.any((other) => !identical(other, line) &&
        other.product?['code']?.toString() == product['code']?.toString())) {
      return;
    }
    line.product = product;
    line.code.text = '${product['code'] ?? ''}';
    line.name.text = '${product['name'] ?? ''}';
    if (n(line.qty.text) <= 0) line.qty.text = '1';
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) line.qtyFocus.requestFocus();
    });
  }

  void _submitReturnProduct(ReturnLine line, String value) {
    final query = value.trim().toLowerCase();
    final product = _optionsFor(line).where((item) =>
      item['code']?.toString().toLowerCase() == query ||
      item['name']?.toString().toLowerCase() == query).firstOrNull;
    if (product != null) {
      _selectReturnProduct(line, product);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('اختر صنفًا من أصناف فاتورة البيع'),
      ));
      line.qtyFocus.requestFocus();
    }
  }

  void _submitReturnQuantity(int index) {
    final line = _lines[index];
    final product = line.product;
    if (product != null && n(line.qty.text) > _availableQuantity(product) + .0001) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('الكمية أكبر من المتاح للصنف ${product['name']}'),
      ));
      return;
    }
    if (index == _lines.length - 1) {
      _addReturnLine();
    } else {
      final next = _lines[index + 1];
      if (next.product == null) {
        next.nameFocus.requestFocus();
      } else {
        next.qtyFocus.requestFocus();
      }
    }
  }

  Widget _returnHeader(String title, double width) => SizedBox(
    width: width,
    child: Text(title, textAlign: TextAlign.center,
      style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold,
        color: AppTheme.accentFor(context), fontSize: 12)),
  );

  Widget _buildReturnItemsTable() {
    if (_sale == null) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 760,
        child: Column(children: [
          Row(children: [
            _returnHeader('الكود', 100), const SizedBox(width: 5),
            _returnHeader('الصنف', 220), const SizedBox(width: 5),
            _returnHeader('المتاح', 80), const SizedBox(width: 5),
            _returnHeader('كمية المرتجع', 105), const SizedBox(width: 5),
            _returnHeader('السعر', 90), const SizedBox(width: 5),
            _returnHeader('الإجمالي', 100), const SizedBox(width: 40),
          ]),
          const SizedBox(height: 4),
          ...List.generate(_lines.length, (index) {
            final line = _lines[index];
            final options = _optionsFor(line);
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(
                color: AppTheme.textHintFor(context).withValues(alpha: .25),
              ))),
              child: Row(children: [
                SizedBox(width: 100, child: TextField(
                  controller: line.code, readOnly: true, textAlign: TextAlign.center,
                  decoration: const InputDecoration(hintText: 'الكود', isDense: true),
                )),
                const SizedBox(width: 5),
                SizedBox(width: 220, child: RawAutocomplete<JMap>(
                  textEditingController: line.name,
                  focusNode: line.nameFocus,
                  displayStringForOption: (item) => '${item['name'] ?? ''}',
                  optionsBuilder: (value) {
                    final query = value.text.trim().toLowerCase();
                    if (query.isEmpty) return options;
                    return options.where((item) =>
                      '${item['code']} ${item['name']}'.toLowerCase().contains(query));
                  },
                  optionsViewBuilder: (context, onSelected, options) => Material(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        children: options.map((item) => ListTile(
                          dense: true,
                          title: Text('${item['name']}'),
                          subtitle: Text('${item['code']}'),
                          onTap: () => onSelected(item),
                        )).toList(),
                      ),
                    ),
                  ),
                  onSelected: (item) => _selectReturnProduct(line, item),
                  fieldViewBuilder: (context, controller, focusNode, onSubmitted) => TextField(
                    controller: controller,
                    focusNode: focusNode,
                    textInputAction: TextInputAction.next,
                    onChanged: (value) {
                      if (line.product != null &&
                          line.product!['name']?.toString().toLowerCase() != value.trim().toLowerCase()) {
                        line.product = null;
                        line.code.clear();
                        line.qty.clear();
                        setState(() {});
                      }
                    },
                    onSubmitted: (value) => _submitReturnProduct(line, value),
                    decoration: const InputDecoration(hintText: 'الصنف', isDense: true),
                  ),
                )),
                const SizedBox(width: 5),
                SizedBox(width: 80, child: Text(
                  line.product == null ? '—' : money(_availableQuantity(line.product!)),
                  textAlign: TextAlign.center,
                )),
                const SizedBox(width: 5),
                SizedBox(width: 105, child: TextField(
                  controller: line.qty,
                  focusNode: line.qtyFocus,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: index == _lines.length - 1 ? TextInputAction.done : TextInputAction.next,
                  onChanged: (_) => _totals.value++,
                  onSubmitted: (_) => _submitReturnQuantity(index),
                  decoration: const InputDecoration(hintText: 'الكمية', isDense: true),
                )),
                const SizedBox(width: 5),
                SizedBox(width: 90, child: Text(
                  line.product == null ? '—' : money(n(line.product!['price'])),
                  textAlign: TextAlign.center,
                )),
                const SizedBox(width: 5),
                SizedBox(width: 100, child: ListenableBuilder(
                  listenable: line.qty,
                  builder: (context, _) => Text(money(line.amount), textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                )),
                SizedBox(width: 40, child: IconButton(
                  tooltip: 'حذف الصنف', icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () {
                    line.dispose();
                    setState(() => _lines.removeAt(index));
                  },
                )),
              ]),
            );
          }),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: !_hasAvailableReturnItem ? null : _addReturnLine,
              icon: const Icon(Icons.add),
              label: const Text('إضافة صنف من الفاتورة'),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    final selectedLines = _lines.where((line) => line.product != null && n(line.qty.text) > 0).toList();
    if (_sale == null || _store == null || _returnTotal <= 0 || selectedLines.isEmpty) return;
    if (_lines.any((line) => line.product == null && line.name.text.trim().isNotEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('أكمل اختيار الصنف من فاتورة البيع أو امسح السطر'),
      ));
      return;
    }
    if (_refundAmount > 0 && (_method == null || _safe == null)) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اختر طريقة الدفع والخزينة لرد المبلغ'))); return; }
    for (final line in selectedLines) {
      final item = line.product!;
      if (n(line.qty.text) > _availableQuantity(item) + .0001) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('الكمية المرتجعة للصنف ${item['name']} أكبر من المتاح')));
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final items = selectedLines.map((line) => {
        'code': line.product!['code'],
        'name': line.product!['name'],
        'quantity': n(line.qty.text),
        'price': n(line.product!['price']),
        'total': line.amount,
      }).toList();
      await _service.save('returns', {
        'id': widget.editItem?['id']?.toString() ?? _service.newId(), 'company_code': widget.companyCode, 'branch_code': _sale!['branch_code'], 'store_code': _store,
        if (widget.editItem != null) 'base_updated_at': widget.editItem!['updated_at'],
        'serial': widget.editItem?['serial'] ?? 0, 'date': widget.editItem?['date'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now()), 'sale_id': _sale!['id'], 'invoice_serial': _sale!['serial'],
        'customer_code': _sale!['customer_code'], 'customer_name': _sale!['customer_name'], 'items': items, 'total': _returnTotal,
        'settlement_mode': _settlementMode,
        'credit_amount': _creditAmount.clamp(0, _returnTotal), 'refund_amount': _refundAmount,
        'payments': _refundAmount > 0 ? [{'method': _method, 'treasury': _safe, 'amount': _refundAmount}] : [], 'employee': widget.userName ?? '',
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ المرتجع')));
      await _selectSale(null);
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => CommercialPageFrame(
    title: widget.editItem == null ? 'مرتجع مبيعات' : 'تعديل مرتجع مبيعات',
    child: ListView(padding: const EdgeInsets.all(16), children: [
      DropdownButtonFormField<JMap>(
        initialValue: _sale,
        decoration: const InputDecoration(labelText: 'فاتورة البيع'),
        items: _sales.map((sale) => DropdownMenuItem(
          value: sale,
          child: Text('فاتورة ${sale['serial']} · ${sale['customer_name']} · ${sale['date']}'),
        )).toList(),
        onChanged: _selectSale,
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        initialValue: _stores.any((store) => '${store['code']}' == _store) ? _store : null,
        decoration: const InputDecoration(labelText: 'المخزن الذي يستقبل المرتجع'),
        items: _stores.map((store) => DropdownMenuItem(
          value: '${store['code']}', child: Text('${store['name']}'),
        )).toList(),
        onChanged: (value) => setState(() => _store = value),
      ),
      const SizedBox(height: 12),
      _buildReturnItemsTable(),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: _settlementMode,
        decoration: const InputDecoration(labelText: 'طريقة تسوية قيمة المرتجع'),
        items: const [
          DropdownMenuItem(value: 'credit_first', child: Text('خصم من مديونية العميل أولًا ثم رد الزيادة')),
          DropdownMenuItem(value: 'cash_refund', child: Text('رد كامل قيمة المرتجع من الخزينة')),
        ],
        onChanged: (value) => setState(() => _settlementMode = value ?? 'credit_first'),
      ),
      const SizedBox(height: 8),
      ListenableBuilder(
        listenable: _totals,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('رصيد العميل الآجل: ${money(_customerBalance)} · قيمة المرتجع: ${money(_returnTotal)} · تخصم من المديونية: ${money(_creditAmount)} · المردود من الخزينة: ${money(_refundAmount)}'),
          if (_refundAmount > 0) ...[
        DropdownButtonFormField<String>(
          initialValue: _methods.any((method) => '${method['name']}' == _method) ? _method : null,
          decoration: const InputDecoration(labelText: 'طريقة رد المبلغ'),
          items: _methods.map((method) => DropdownMenuItem(
            value: '${method['name']}', child: Text('${method['name']}'),
          )).toList(),
          onChanged: (value) => setState(() => _method = value),
        ),
        DropdownButtonFormField<String>(
          initialValue: _safes.any((safe) => '${safe['name']}' == _safe) ? _safe : null,
          decoration: const InputDecoration(labelText: 'الخزينة التي سيخرج منها المبلغ'),
          items: _safes.map((safe) => DropdownMenuItem(
            value: '${safe['name']}', child: Text('${safe['name']}'),
          )).toList(),
          onChanged: (value) => setState(() => _safe = value),
        ),
          ],
        ]),
      ),
      FilledButton.icon(
        onPressed: _busy ? null : _save,
        icon: const Icon(Icons.save),
        label: Text(widget.editItem == null ? 'حفظ المرتجع' : 'حفظ التعديل'),
      ),
    ]),
  );
}
