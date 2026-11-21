import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../../services/permissions_service.dart';
import '../../../services/stock_balance_service.dart';
import '../../../services/transfers_service.dart';
import '../commercial/commercial_shared.dart';

class StockTransfersPage extends StatefulWidget {
  final String companyCode; final String? branchCode; final String? userName; final JMap? editItem;
  const StockTransfersPage({super.key, required this.companyCode, this.branchCode, this.userName, this.editItem});
  @override State<StockTransfersPage> createState() => _StockTransfersPageState();
}
class _StockTransfersPageState extends State<StockTransfersPage> {
  final _service = TransfersService();
  List<JMap> _branches = [], _products = [];

  /// فهرس بحث/كود مجهز مرة ويُعاد بناؤه عند تغيّر كتالوج الأصناف فقط.
  ProductIndex _productIndex = ProductIndex(const [], searchBarcode: false);

  StreamSubscription<BoxEvent>? _catalogSubscription;
  Timer? _catalogDebounce;
  final _items = <SaleLine>[];

  String? _fromBranch, _toBranch, _fromStore, _toStore;
  bool _busy = false;

  @override
  void dispose() {
    _catalogSubscription?.cancel();
    _catalogDebounce?.cancel();
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  List<JMap> get _fromStores =>
      storesForBranch(widget.companyCode, _fromBranch);

  List<JMap> get _toStores =>
      storesForBranch(widget.companyCode, _toBranch);

  @override
  void initState() {
    super.initState();

    _branches = catalog(widget.companyCode, 'branches')
        .where((b) => PermissionsService().canAccessBranch('${b['code']}'))
        .toList();
    _products = catalog(widget.companyCode, 'items');
    _productIndex = ProductIndex(_products, searchBarcode: false);
    _catalogSubscription =
        Hive.box('coding_box').watch().listen((_) => _onCatalogChanged());

    _fromBranch = widget.editItem?['from_branch_code']?.toString() ??
        widget.branchCode ??
        _branches.firstOrNull?['code']?.toString();

    _toBranch = widget.editItem?['to_branch_code']?.toString() ??
        _branches
            .where((e) => '${e['code']}' != _fromBranch)
            .firstOrNull?['code']
            ?.toString();

    _fromStore = widget.editItem?['from_store_code']?.toString() ??
        _fromStores.firstOrNull?['code']?.toString();

    _toStore = widget.editItem?['to_store_code']?.toString() ??
        _toStores.firstOrNull?['code']?.toString();

    if (widget.editItem?['items'] is List) {
      for (final item in widget.editItem!['items']) {
        if (item is Map) {
          final product = _productIndex.byCode('${item['code']}') ??
              Map<String, dynamic>.from(item);
          _items.add(
            SaleLine(
              product,
              n(item['quantity']),
              n(item['price']),
            ),
          );
        }
      }
    }
  }

  /// تحديث قوائم الفروع والأصناف عند مزامنة الكتالوج دون لمس الأصناف المضافة
  /// أو الاختيارات الحالية. الفروع تُرشَّح بنفس صلاحيات الوصول.
  void _onCatalogChanged() {
    _catalogDebounce?.cancel();
    _catalogDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _branches = catalog(widget.companyCode, 'branches')
            .where((b) => PermissionsService().canAccessBranch('${b['code']}'))
            .toList();
        _products = catalog(widget.companyCode, 'items');
        _productIndex = ProductIndex(_products, searchBarcode: false);
      });
    });
  }

  Future<void> _save() async {
    if (_fromBranch == null ||
        _toBranch == null ||
        _fromStore == null ||
        _toStore == null ||
        _items.isEmpty) {
      return;
    }

    setState(() => _busy = true);

    try {
      final stock = await StockBalanceService.calculateBalances(
        companyCode: widget.companyCode,
        branchCode: _fromBranch!,
        storeCode: _fromStore!,
        toDate: DateTime.now(),
      );

      final balances = {
        for (final s in stock) '${s['code']}': n(s['quantity']),
      };

      if (widget.editItem != null &&
          widget.editItem!['from_branch_code']?.toString() == _fromBranch &&
          widget.editItem!['from_store_code']?.toString() == _fromStore &&
          widget.editItem!['items'] is List) {
        for (final old
            in (widget.editItem!['items'] as List).whereType<Map>()) {
          final code = '${old['code']}';
          balances[code] = (balances[code] ?? 0) + n(old['quantity']);
        }
      }

      for (final item in _items) {
        if (n(item.qty.text) >
            (balances['${item.product['code']}'] ?? 0)) {
          throw Exception(
            'الكمية غير متاحة في المخزن المصدر للصنف '
            '${item.product['name']}',
          );
        }
      }

      await _service.save({
        'id': widget.editItem?['id']?.toString() ?? _service.newId(),
        'company_code': widget.companyCode,
        if (widget.editItem != null) 'base_updated_at': widget.editItem!['updated_at'],
        'from_branch_code': _fromBranch,
        'from_store_code': _fromStore,
        'to_branch_code': _toBranch,
        'to_store_code': _toStore,
        'serial': widget.editItem?['serial'] ?? 0,
        'date': widget.editItem?['date'] ??
            DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'items': _items
            .map((item) => {
                  'code': item.product['code'],
                  'name': item.product['name'],
                  'quantity': n(item.qty.text),
                  'price': n(item.price.text),
                })
            .toList(),
        'statement': widget.editItem?['statement'] ?? '',
        'employee': widget.userName ?? '',
      });

      if (widget.editItem == null) {
        for (final item in _items) {
          item.dispose();
        }
        _items.clear();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ التحويل')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _dd(
    String title,
    String? value,
    List<JMap> list,
    ValueChanged<String?> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: list.any((e) => '${e['code']}' == value) ? value : null,
      decoration: InputDecoration(labelText: title),
      items: list
          .map(
            (e) => DropdownMenuItem(
              value: '${e['code']}',
              child: Text('${e['name']}'),
            ),
          )
          .toList(),
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommercialPageFrame(
      title: widget.editItem == null
          ? 'تحويل مخزني'
          : 'تعديل تحويل مخزني',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 220,
                child: _dd('من فرع', _fromBranch, _branches, (value) {
                  setState(() {
                    _fromBranch = value;
                    if (!_fromStores.any(
                      (e) => '${e['code']}' == _fromStore,
                    )) {
                      _fromStore =
                          _fromStores.firstOrNull?['code']?.toString();
                    }
                  });
                }),
              ),
              SizedBox(
                width: 220,
                child: _dd(
                  'من مخزن',
                  _fromStore,
                  _fromStores,
                  (value) => setState(() => _fromStore = value),
                ),
              ),
              SizedBox(
                width: 220,
                child: _dd('إلى فرع', _toBranch, _branches, (value) {
                  setState(() {
                    _toBranch = value;
                    if (!_toStores.any(
                      (e) => '${e['code']}' == _toStore,
                    )) {
                      _toStore = _toStores.firstOrNull?['code']?.toString();
                    }
                  });
                }),
              ),
              SizedBox(
                width: 220,
                child: _dd(
                  'إلى مخزن',
                  _toStore,
                  _toStores,
                  (value) => setState(() => _toStore = value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Autocomplete<JMap>(
            displayStringForOption: (e) => '${e['code']} — ${e['name']}',
            optionsBuilder: (value) => _productIndex.search(
              value.text,
              limit: null,
              trimQuery: false,
              emptyReturnsAll: true,
            ),
            onSelected: (product) {
              if (!_items.any(
                (item) => '${item.product['code']}' == '${product['code']}',
              )) {
                setState(() => _items.add(SaleLine(product, 1, 0)));
              }
            },
            fieldViewBuilder: (context, controller, focusNode, onSubmit) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: const InputDecoration(
                  labelText: 'ابحث عن صنف لإضافته',
                ),
              );
            },
          ),
          ..._items.map(
            (item) => ListTile(
              title: Text('${item.product['name']}'),
              trailing: SizedBox(
                width: 90,
                child: TextField(
                  controller: item.qty,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الكمية'),
                ),
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save),
            label: Text(
              widget.editItem == null ? 'حفظ التحويل' : 'حفظ التعديل',
            ),
          ),
        ],
      ),
    );
  }
}
