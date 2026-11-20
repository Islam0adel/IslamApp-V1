import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../core/theme.dart';
import '../../../services/commercial_service.dart';
import '../../../services/permissions_service.dart';
import '../../../services/stock_balance_service.dart';
import 'commercial_shared.dart';

class SalesPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? userName;
  final JMap? editItem;
  const SalesPage({super.key, required this.companyCode, this.selectedBranchCode, this.userName, this.editItem});
  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  static const double _wideBreakpoint = 760;

  final _service = CommercialService();
  final _discount = TextEditingController(text: '0');
  final _discountPct = TextEditingController(text: '0');
  final _lines = <SaleLine>[];
  final _payments = <PayLine>[];
  final _form = GlobalKey<FormState>();
  List<JMap> _branches = [], _stores = [], _customers = [], _products = [], _methods = [], _safes = [], _people = [];
  String? _branch, _store, _customer;
  String _cashier = '', _seller = '';
  bool _busy = false, _loading = true;

  /// فاتورة آجل؟ الافتراضي: لا (الفاتورة نقدية).
  bool _credit = false;

  /// آخر حقل عدّله المستخدم في الخصم: true = النسبة، false = المبلغ.
  bool _discountByPct = false;

  // ───────────────────────── الحسابات ─────────────────────────
  List<SaleLine> get _validSaleLines => _lines.where((line) =>
      (line.product['code']?.toString().isNotEmpty ?? false) && n(line.qty.text) > 0).toList();
  double get _subtotal => _validSaleLines.fold<double>(0.0, (s, e) => s + e.amount);

  /// مبلغ الخصم الفعلي (لا يقل عن صفر ولا يزيد عن مجموع الأصناف).
  double get _discountValue {
    final v = n(_discount.text);
    final sub = _subtotal;
    if (v < 0) return 0;
    return v > sub ? sub : v;
  }

  double get _total => _subtotal - _discountValue;

  /// مجموع المبالغ المكتوبة في سطور الدفع.
  double get _enteredTotal => _payments.fold<double>(0.0, (s, e) => s + n(e.amount.text));
  bool get _hasEnteredAmount => _enteredTotal > 0.0001;

  /// المستلم فعليًا من العميل. نقدًا: لو لم يُكتب مبلغ يُعتبر الدفع كاملًا.
  double get _received => (!_credit && !_hasEnteredAmount) ? _total : _enteredTotal;

  /// نقدًا وكُتب مبلغ أقل من الإجمالي → غير مسموح إلا بتفعيل الآجل.
  bool get _cashShortfall => !_credit && _hasEnteredAmount && _received < _total - 0.01;

  /// الصافي الذي يدخل الدرج ويُحفظ كمدفوع (لا يزيد عن الإجمالي أبدًا).
  double get _paid {
    if (_received >= _total) return _total;
    if (!_credit && !_cashShortfall) return _total; // فرق تقريب بسيط
    return _received;
  }

  /// الباقي الذي يُرد للعميل من الدرج.
  double get _change => _received > _total + 0.005 ? _received - _total : 0.0;

  /// المتبقي على العميل (للآجل فقط).
  double get _due => _credit ? (_total - _paid).clamp(0, double.infinity).toDouble() : 0.0;

  String get _drawerName {
    final entered = _payments.where((p) => n(p.amount.text) > 0);
    final p = entered.isNotEmpty ? entered.first : (_payments.isNotEmpty ? _payments.first : null);
    return p?.treasury ?? '';
  }

  /// سطور الدفع الصافية: المستلم ناقص الباقي المردود من الدرج (أول خزينة).
  List<JMap> _netPayments() {
    final paid = _paid;
    if (paid <= 0.0001) return [];
    final entered = _payments
        .where((p) => n(p.amount.text) > 0)
        .map<JMap>((p) => {'method': p.method, 'treasury': p.treasury, 'amount': n(p.amount.text)})
        .toList();
    if (entered.isEmpty) {
      final first = _payments.isNotEmpty ? _payments.first : null;
      return [{'method': first?.method ?? '', 'treasury': first?.treasury ?? '', 'amount': paid}];
    }
    var change = _change;
    if (change > 0.0001) {
      final drawer = '${entered.first['treasury']}';
      final order = <int>[
        for (var i = 0; i < entered.length; i++) if ('${entered[i]['treasury']}' == drawer) i,
        for (var i = entered.length - 1; i >= 0; i--) if ('${entered[i]['treasury']}' != drawer) i,
      ];
      for (final i in order) {
        if (change <= 0.0001) break;
        final amount = entered[i]['amount'] as double;
        final cut = amount < change ? amount : change;
        entered[i]['amount'] = amount - cut;
        change -= cut;
      }
    }
    return entered.where((e) => (e['amount'] as double) > 0.0001).toList();
  }

  // ───────────────────────── الخصم (مبلغ ⇄ نسبة) ─────────────────────────
  String _fmt2(double v) {
    var s = v.toStringAsFixed(2);
    if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s;
  }

  void _setText(TextEditingController c, String t) {
    if (c.text != t) c.text = t;
  }

  void _setDiscountPctFromAmount() {
    final sub = _subtotal;
    final pct = sub <= 0 ? 0.0 : _discountValue / sub * 100;
    _setText(_discountPct, _fmt2(pct));
  }

  void _setDiscountAmountFromPct() {
    final pct = n(_discountPct.text).clamp(0, 100).toDouble();
    final amount = ((_subtotal * pct / 100) * 100).round() / 100;
    _setText(_discount, _fmt2(amount));
  }

  /// عند تغيّر مجموع الأصناف: نُبقي الحقل الذي عدّله المستخدم ثابتًا ونحدّث الآخر.
  void _resyncDiscount() {
    if (_discountByPct) {
      _setDiscountAmountFromPct();
    } else {
      _setDiscountPctFromAmount();
    }
  }

  // ───────────────────────── دورة الحياة ─────────────────────────
  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _discount.dispose(); _discountPct.dispose(); for (final x in _lines) { x.dispose(); } for (final p in _payments) { p.dispose(); } super.dispose(); }
  void _refresh() { if (!mounted) return; _resyncDiscount(); setState(() {}); }

  SaleLine _newSaleLine(JMap product, double quantity, double price) {
    final line = SaleLine(product, quantity, price);
    line.qty.addListener(_refresh);
    line.price.addListener(_refresh);
    return line;
  }

  Future<void> _load() async {
    final company = widget.companyCode;
    _branches = catalog(company, 'branches');
    _customers = catalog(company, 'customers'); _products = catalog(company, 'items');
    _methods = catalog(company, 'payment_methods'); _safes = catalog(company, 'safes');
    final users = Hive.box('users_box').get('company_$company', defaultValue: []);
    if (users is List) _people = users.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final employees = Hive.box('coding_box').get('${company}_employees', defaultValue: []);
    if (employees is List) {
      for (final raw in employees.whereType<Map>()) {
        final employee = Map<String, dynamic>.from(raw);
        if (employee['is_deleted'] == true || employee['status']?.toString() == 'inactive') continue;
        if (!_people.any((u) => (u['name'] ?? u['user_name'] ?? u['email'])?.toString() == employee['name']?.toString())) {
          _people.add({'name': employee['name']?.toString() ?? '', 'status': employee['status'] ?? 'active'});
        }
      }
    }
    final allowed = _branches.where((b) => PermissionsService().canAccessBranch('${b['code']}')).toList();
    _branches = allowed;
    _branch = widget.editItem?['branch_code']?.toString() ?? (allowed.any((b) => '${b['code']}' == widget.selectedBranchCode) ? widget.selectedBranchCode : allowed.firstOrNull?['code']?.toString());
    _stores = storesForBranch(company, _branch);
    _store = widget.editItem?['store_code']?.toString() ?? _stores.firstOrNull?['code']?.toString();
    _customer = widget.editItem?['customer_code']?.toString() ?? _customers.firstOrNull?['code']?.toString();
    _cashier = widget.editItem?['cashier']?.toString() ?? widget.userName ?? '';
    _seller = widget.editItem?['seller']?.toString() ?? '';
    if (_cashier.isNotEmpty && !_people.any((u) => (u['name'] ?? u['user_name'] ?? u['email'])?.toString() == _cashier)) _people.add({'name': _cashier});
    if (_seller.isNotEmpty && !_people.any((u) => (u['name'] ?? u['user_name'] ?? u['email'])?.toString() == _seller)) _people.add({'name': _seller});
    if (_methods.isEmpty) _methods = [{'name': 'نقدي'}];
    if (_safes.isEmpty) _safes = [{'name': 'نقدي'}];
    if (_methods.isNotEmpty && _safes.isNotEmpty) _payments.add(PayLine(method: '${_methods.first['name']}', treasury: '${_safes.first['name']}'));
    if (widget.editItem != null) {
      final d = widget.editItem!;
      _credit = n(d['due']) > 0.009;
      _discount.text = '${d['discount'] ?? 0}';
      if (d['items'] is List) for (final item in d['items']) { if (item is Map) { final p = _products.firstWhere((x) => '${x['code']}' == '${item['code']}', orElse: () => Map<String, dynamic>.from(item)); _lines.add(_newSaleLine(p, n(item['quantity']), n(item['price']))); } }
      if (d['payments'] is List && (d['payments'] as List).isNotEmpty) {
        for (final payment in _payments) {
          payment.dispose();
        }
        _payments.clear();
        for (final p in d['payments']) { if (p is Map) _payments.add(PayLine(method: '${p['method'] ?? ''}', treasury: '${p['treasury'] ?? ''}', value: n(p['amount']))); }
      }
    }
    _ensureEntryRow();
    _discountByPct = false;
    _setDiscountPctFromAmount();
    if (mounted) setState(() => _loading = false);
  }

  // ───────────────────────── سطور الأصناف ─────────────────────────
  // الصف الأول (index 0) هو دائمًا «صف الإدخال» الجاهز. عند Enter أو إضافة صنف
  // يبقى صف الإدخال مكانه في الأعلى وينزل الصنف المُدخل تحته.

  void _ensureEntryRow() {
    if (_lines.isEmpty || !_lines.first.isEmpty) {
      _lines.insert(0, _newSaleLine({}, 0, 0));
    }
  }

  void _focusEntryRow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _lines.isNotEmpty) _lines.first.codeFocus.requestFocus();
    });
  }

  void _startNewEntry() {
    setState(_ensureEntryRow);
    _focusEntryRow();
  }

  /// إنهاء السطر (Enter في الكمية/السعر أو زر ✓): ينزل السطر ويظهر صف إدخال جديد أعلاه.
  void _finishLine(SaleLine line) {
    final hasProduct = line.product['code']?.toString().isNotEmpty ?? false;
    if (!hasProduct) { line.codeFocus.requestFocus(); return; }
    if (n(line.qty.text) <= 0) { line.qtyFocus.requestFocus(); return; }
    _startNewEntry();
  }

  void _removeLine(SaleLine line) {
    setState(() {
      _lines.remove(line);
      _ensureEntryRow();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => line.dispose());
  }

  void _selectSaleProduct(SaleLine line, JMap product, {double? quantity, bool focusQty = true}) {
    final sameProduct = line.product['code']?.toString() == product['code']?.toString();
    final oldPrice = line.price.text.trim();
    line.product = product;
    line.code.text = '${product['code'] ?? ''}';
    line.name.text = '${product['name'] ?? ''}';
    if (quantity != null) line.qty.text = plain(quantity);
    if (!sameProduct || oldPrice.isEmpty) {
      line.price.text = plain(n(product['selling_price'] ?? product['sellingPrice']));
    }
    if (mounted) setState(() {});
    if (focusQty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) line.qtyFocus.requestFocus();
      });
    }
  }

  void _submitSaleCode(SaleLine line) {
    final value = line.code.text.trim();
    final product = value.isEmpty ? null : _products.where((item) =>
      item['code']?.toString() == value || item['barcode']?.toString() == value,
    ).firstOrNull;
    if (product == null) {
      line.nameFocus.requestFocus();
      return;
    }
    _selectSaleProduct(line, product, quantity: n(line.qty.text) == 0 ? 1.0 : null);
  }

  /// إضافة صنف من مسح الكاميرا: لو موجود تزيد كميته، وإلا يُدخل في صف الإدخال وينزل تحته.
  void _addProduct(JMap p) {
    final existing = _lines.where((x) => '${x.product['code']}' == '${p['code']}').firstOrNull;
    if (existing != null) {
      existing.qty.text = plain(n(existing.qty.text) + 1);
      _message('زادت كمية ${p['name']} إلى ${existing.qty.text}');
      return;
    }
    setState(_ensureEntryRow);
    _selectSaleProduct(_lines.first, p, quantity: 1.0, focusQty: false);
    setState(_ensureEntryRow);
    _message('تمت إضافة ${p['name']}');
  }

  Future<void> _scan() async {
    final side = (MediaQuery.of(context).size.shortestSide - 48).clamp(240.0, 450.0).toDouble();
    var handled = false;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: side,
          height: side,
          child: Stack(fit: StackFit.expand, children: [
            MobileScanner(onDetect: (capture) {
              if (handled || capture.barcodes.isEmpty) return;
              final raw = capture.barcodes.first.rawValue;
              if (raw == null || raw.isEmpty) return;
              handled = true;
              Navigator.pop(dialogContext, raw);
            }),
            PositionedDirectional(
              top: 4,
              end: 4,
              child: IconButton(
                tooltip: 'إغلاق',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(dialogContext),
              ),
            ),
          ]),
        ),
      ),
    );
    if (value == null || !mounted) return;
    final p = _products.where((e) => e['barcode']?.toString() == value || e['code']?.toString() == value).firstOrNull;
    if (p != null) { _addProduct(p); } else { _message('الكود غير موجود في التكويد'); }
  }

  void _message(String text) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo'))));
  }

  // ───────────────────────── عناصر الواجهة المشتركة ─────────────────────────
  InputDecoration _fieldDecoration(String label, {String? hint, String? suffixText, String? errorText, Widget? suffixIcon, bool alwaysFloat = false}) => InputDecoration(
    labelText: label, hintText: hint, suffixText: suffixText, errorText: errorText, suffixIcon: suffixIcon,
    floatingLabelBehavior: alwaysFloat ? FloatingLabelBehavior.always : null,
    isDense: true, border: const OutlineInputBorder(),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12));

  /// يوزّع الحقول في أعمدة حسب عرض الشاشة (1 / 2 / 3 / 6 أعمدة).
  Widget _responsiveFields(List<Widget> children, {double spacing = 10}) => LayoutBuilder(builder: (context, c) {
    final w = c.maxWidth;
    final cols = w >= 1000 ? 6 : w >= 720 ? 3 : w >= 380 ? 2 : 1;
    final itemW = ((w - spacing * (cols - 1)) / cols).floorToDouble();
    return Wrap(spacing: spacing, runSpacing: spacing, children: [for (final child in children) SizedBox(width: itemW, child: child)]);
  });

  /// بطاقات أرقام (إجمالي/مستلم/باقي...) تتوزع على عمودين في الهاتف وصف واحد في الشاشات الكبيرة.
  Widget _tileWrap(List<Widget> tiles, {double spacing = 8}) => LayoutBuilder(builder: (context, c) {
    final n = tiles.length;
    if (n == 0) return const SizedBox.shrink();
    final w = c.maxWidth;
    final cols = w >= 640 ? (n > 4 ? 4 : n) : (n == 1 ? 1 : 2);
    final itemW = ((w - spacing * (cols - 1)) / cols).floorToDouble();
    return Wrap(spacing: spacing, runSpacing: spacing, children: [for (final t in tiles) SizedBox(width: itemW, child: t)]);
  });

  Widget _statTile(String label, String value, {Color? color, bool big = false}) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.withAlpha(26), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.withAlpha(110))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: TextStyle(fontSize: 12, fontFamily: 'Cairo', color: c)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(value, style: TextStyle(fontSize: big ? 22 : 17, fontWeight: FontWeight.bold, fontFamily: 'Cairo', color: c)),
        ),
      ]),
    );
  }

  Widget _sectionTitle(String text, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [
      Icon(icon, size: 20, color: AppTheme.accentFor(context)),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textMainFor(context))),
    ]),
  );

  Widget _drop(String label, String? value, List<JMap> list, ValueChanged<String?> onChanged) => DropdownButtonFormField<String>(
    isExpanded: true,
    initialValue: list.any((e) => '${e['code']}' == value) ? value : null,
    decoration: _fieldDecoration(label),
    items: list.map((e) => DropdownMenuItem(value: '${e['code']}', child: Text('${e['name']}', overflow: TextOverflow.ellipsis))).toList(),
    onChanged: onChanged);

  Widget _peopleDrop(String label, String current, ValueChanged<String?> onChanged) {
    final names = _people.map((u) => (u['name'] ?? u['user_name'] ?? u['email'] ?? '').toString()).where((n) => n.isNotEmpty).toSet().toList();
    return DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: names.contains(current) ? current : null,
      decoration: _fieldDecoration(label),
      items: names.map((n) => DropdownMenuItem(value: n, child: Text(n, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: onChanged);
  }

  Widget _scanButton() => SizedBox(
    height: 48,
    child: FilledButton.tonalIcon(
      onPressed: _scan,
      icon: const Icon(Icons.qr_code_scanner),
      label: const FittedBox(fit: BoxFit.scaleDown, child: Text('مسح بالكاميرا')),
    ),
  );

  // ───────────────────────── جدول الأصناف ─────────────────────────
  Widget _saleCell({required String label, required bool compact,
    required TextEditingController controller, required FocusNode focusNode,
    TextInputType keyboard = TextInputType.text,
    TextInputAction action = TextInputAction.next,
    bool enabled = true, ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted}) => TextField(
    controller: controller, focusNode: focusNode, enabled: enabled,
    keyboardType: keyboard, textInputAction: action, textAlign: TextAlign.center,
    onChanged: onChanged, onSubmitted: onSubmitted,
    style: const TextStyle(fontSize: 14, fontFamily: 'Cairo'),
    decoration: InputDecoration(
      hintText: compact ? null : label, labelText: compact ? label : null, isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 12 : 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
  );

  Widget _codeField(SaleLine line, {required bool compact}) => _saleCell(
    label: 'الكود', compact: compact, controller: line.code, focusNode: line.codeFocus,
    onChanged: (value) {
      if (line.product['code']?.toString() != value.trim()) {
        line.product = {};
        line.name.clear();
        line.price.text = '';
        setState(() {});
      }
    },
    onSubmitted: (_) => _submitSaleCode(line));

  Widget _nameField(SaleLine line, {required bool compact}) => LayoutBuilder(builder: (context, c) {
    final fieldWidth = c.maxWidth;
    final optionsWidth = fieldWidth < 260 ? 260.0 : fieldWidth;
    return RawAutocomplete<JMap>(
      textEditingController: line.name, focusNode: line.nameFocus,
      displayStringForOption: (item) => '${item['name'] ?? ''}',
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return const Iterable<JMap>.empty();
        return _products.where((item) =>
          '${item['code']} ${item['name']} ${item['barcode']}'.toLowerCase().contains(query)).take(30);
      },
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: optionsWidth,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
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
        ),
      ),
      onSelected: (item) => _selectSaleProduct(line, item,
        quantity: n(line.qty.text) == 0 ? 1.0 : null),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) =>
        _saleCell(label: 'الصنف', compact: compact, controller: controller,
          focusNode: focusNode, onChanged: (value) {
            if (line.product['name']?.toString().toLowerCase() != value.trim().toLowerCase()) {
              line.product = {};
              line.code.clear();
              line.price.text = '';
            }
            setState(() {});
          },
          onSubmitted: (value) {
            final item = _products.where((p) =>
              p['name']?.toString().toLowerCase() == value.trim().toLowerCase() ||
              p['code']?.toString() == value.trim()).firstOrNull;
            if (item == null) {
              _message('اختر الصنف من قائمة الاقتراحات');
            } else {
              _selectSaleProduct(line, item,
                quantity: n(line.qty.text) == 0 ? 1.0 : null);
            }
          }),
    );
  });

  Widget _qtyField(SaleLine line, {required bool compact}) => _saleCell(
    label: 'الكمية', compact: compact, controller: line.qty, focusNode: line.qtyFocus,
    keyboard: const TextInputType.numberWithOptions(decimal: true),
    action: PermissionsService().canChangeSellingPrice ? TextInputAction.next : TextInputAction.done,
    onChanged: (_) => setState(() {}),
    onSubmitted: (_) => PermissionsService().canChangeSellingPrice
        ? line.priceFocus.requestFocus()
        : _finishLine(line));

  Widget _priceField(SaleLine line, {required bool compact}) => _saleCell(
    label: 'سعر البيع', compact: compact, controller: line.price, focusNode: line.priceFocus,
    keyboard: const TextInputType.numberWithOptions(decimal: true),
    enabled: PermissionsService().canChangeSellingPrice,
    action: TextInputAction.done,
    onChanged: (_) => setState(() {}),
    onSubmitted: (_) => _finishLine(line));

  Widget _totalBox(SaleLine line) => InputDecorator(
    decoration: InputDecoration(
      labelText: 'الإجمالي', isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
    child: SizedBox(
      width: double.infinity,
      child: Text(money(line.amount), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
    ),
  );

  /// صف الإدخال (الأول): زر ✓ لإنزال الصنف. باقي الصفوف: زر حذف.
  Widget _rowAction(SaleLine line, int index) {
    if (index == 0) {
      final ready = (line.product['code']?.toString().isNotEmpty ?? false) && n(line.qty.text) > 0;
      return IconButton(
        tooltip: 'إضافة الصنف وإدخال صنف جديد',
        icon: const Icon(Icons.check_circle_outline),
        color: AppTheme.accentFor(context),
        onPressed: ready ? () => _finishLine(line) : null,
      );
    }
    return IconButton(
      tooltip: 'حذف الصنف',
      icon: const Icon(Icons.delete_outline, size: 22),
      onPressed: () => _removeLine(line),
    );
  }

  BoxDecoration _rowDecoration(bool isEntry) {
    final accent = AppTheme.accentFor(context);
    final card = Theme.of(context).cardColor;
    return BoxDecoration(
      color: isEntry ? Color.alphaBlend(accent.withAlpha(28), card) : card,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: isEntry ? accent : Theme.of(context).dividerColor.withAlpha(90), width: 1.5),
    );
  }

  Widget _headerCell(String label, int flex) => Expanded(
    flex: flex,
    child: Text(label, textAlign: TextAlign.center,
      style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.accentFor(context))),
  );

  Widget _tableHeader() {
    final showWholesale = PermissionsService().canViewWholesaleInSale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(7.5, 0, 7.5, 2),
      child: Row(children: [
        _headerCell('الكود', 2), const SizedBox(width: 6),
        _headerCell('الصنف', 5), const SizedBox(width: 6),
        _headerCell('الكمية', 2), const SizedBox(width: 6),
        _headerCell('سعر البيع', 2),
        if (showWholesale) ...[const SizedBox(width: 6), _headerCell('الجملة', 2)],
        const SizedBox(width: 6), _headerCell('الإجمالي', 2),
        const SizedBox(width: 48),
      ]),
    );
  }

  /// صف للشاشات العريضة (لاب توب/تابلت): كل الحقول في سطر واحد وبعرض مرن بدون سكرول أفقي.
  Widget _buildWideRow(int index) {
    final line = _lines[index];
    final showWholesale = PermissionsService().canViewWholesaleInSale;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: _rowDecoration(index == 0),
      child: Row(children: [
        Expanded(flex: 2, child: _codeField(line, compact: false)),
        const SizedBox(width: 6),
        Expanded(flex: 5, child: _nameField(line, compact: false)),
        const SizedBox(width: 6),
        Expanded(flex: 2, child: _qtyField(line, compact: false)),
        const SizedBox(width: 6),
        Expanded(flex: 2, child: _priceField(line, compact: false)),
        if (showWholesale) ...[
          const SizedBox(width: 6),
          Expanded(flex: 2, child: Text(
            money(n(line.product['wholesale_price'] ?? line.product['wholesalePrice'])),
            textAlign: TextAlign.center)),
        ],
        const SizedBox(width: 6),
        Expanded(flex: 2, child: Text(money(line.amount), textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold))),
        SizedBox(width: 42, child: _rowAction(line, index)),
      ]),
    );
  }

  /// بطاقة للهاتف: الكود والصنف في سطر، والكمية والسعر والإجمالي في سطر.
  Widget _buildCompactRow(int index) {
    final line = _lines[index];
    final showWholesale = PermissionsService().canViewWholesaleInSale;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      decoration: _rowDecoration(index == 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: _codeField(line, compact: true)),
          const SizedBox(width: 6),
          Expanded(flex: 4, child: _nameField(line, compact: true)),
          SizedBox(width: 44, child: _rowAction(line, index)),
        ]),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _qtyField(line, compact: true)),
            const SizedBox(width: 6),
            Expanded(child: _priceField(line, compact: true)),
            const SizedBox(width: 6),
            Expanded(child: _totalBox(line)),
          ]),
        ),
        if (showWholesale) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('سعر الجملة: ${money(n(line.product['wholesale_price'] ?? line.product['wholesalePrice']))}',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        ),
      ]),
    );
  }

  Widget _buildSalesItems() => LayoutBuilder(builder: (context, c) {
    final wide = c.maxWidth >= _wideBreakpoint;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (wide) _tableHeader(),
      for (var i = 0; i < _lines.length; i++)
        KeyedSubtree(key: ObjectKey(_lines[i]), child: wide ? _buildWideRow(i) : _buildCompactRow(i)),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(onPressed: _startNewEntry, icon: const Icon(Icons.add), label: const Text('إضافة صنف')),
      ),
    ]);
  });

  // ───────────────────────── الخصم والإجمالي ─────────────────────────
  Widget _buildDiscountAndTotals() => LayoutBuilder(builder: (context, c) {
    final wide = c.maxWidth >= 600;
    final amountField = TextField(
      controller: _discount,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _fieldDecoration('الخصم (مبلغ)'),
      onChanged: (_) { _discountByPct = false; _setDiscountPctFromAmount(); setState(() {}); },
    );
    final pctField = TextField(
      controller: _discountPct,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _fieldDecoration('نسبة الخصم', suffixText: '%', errorText: n(_discountPct.text) > 100 ? 'الحد الأقصى 100%' : null),
      onChanged: (_) { _discountByPct = true; _setDiscountAmountFromPct(); setState(() {}); },
    );
    final fields = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: amountField),
      const SizedBox(width: 10),
      Expanded(child: pctField),
    ]);
    final tiles = _tileWrap([
      _statTile('المجموع قبل الخصم', money(_subtotal)),
      _statTile('قيمة الخصم', money(_discountValue), color: Colors.red.shade600),
    ]);
    if (wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: fields),
        const SizedBox(width: 12),
        Expanded(child: tiles),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [fields, const SizedBox(height: 10), tiles]);
  });

  // ───────────────────────── الدفع ─────────────────────────
  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
  );

  Widget _creditSwitch() {
    final color = _credit ? Colors.orange.shade700 : Colors.green.shade600;
    return Material(
      color: color.withAlpha(28),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color.withAlpha(160)),
      ),
      child: SwitchListTile(
        value: _credit,
        onChanged: _busy ? null : (v) => setState(() => _credit = v),
        secondary: Icon(_credit ? Icons.schedule : Icons.payments_outlined, color: color),
        title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('فاتورة آجل', style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          _badge(_credit ? 'مفعّل' : 'متوقف', color),
        ]),
        subtitle: Text(
          _credit
              ? 'المتبقي بعد المدفوع يُسجَّل على العميل: ${nameOf(_customers, _customer ?? '')}'
              : 'فاتورة نقدية: تُحصَّل كاملة، واترك المبلغ فارغًا للدفع الكامل.',
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
        ),
      ),
    );
  }

  void _fillPayment(int index) {
    var others = 0.0;
    for (var i = 0; i < _payments.length; i++) {
      if (i != index) others += n(_payments[i].amount.text);
    }
    final remaining = _total - others;
    _payments[index].amount.text = remaining > 0 ? _fmt2(remaining) : '';
    setState(() {});
  }

  Widget _payRow(int index) {
    final payment = _payments[index];
    final methodField = DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: _methods.any((item) => '${item['name']}' == payment.method)
          ? payment.method
          : null,
      decoration: _fieldDecoration('طريقة الدفع'),
      items: _methods.map((item) => DropdownMenuItem(
        value: '${item['name']}',
        child: Text('${item['name']}', overflow: TextOverflow.ellipsis),
      )).toList(),
      onChanged: (value) => setState(() => payment.method = value ?? ''),
    );
    final safeField = DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: _safes.any((item) => '${item['name']}' == payment.treasury)
          ? payment.treasury
          : null,
      decoration: _fieldDecoration('الخزينة'),
      items: _safes.map((item) => DropdownMenuItem(
        value: '${item['name']}',
        child: Text('${item['name']}', overflow: TextOverflow.ellipsis),
      )).toList(),
      onChanged: (value) => setState(() => payment.treasury = value ?? ''),
    );
    final amountField = TextField(
      controller: payment.amount,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _fieldDecoration('المبلغ',
        hint: (index == 0 && !_credit) ? money(_total) : '0',
        alwaysFloat: true,
        suffixIcon: IconButton(
          tooltip: 'تعبئة المتبقي',
          icon: const Icon(Icons.done_all, size: 18),
          onPressed: () => _fillPayment(index),
        )),
      onChanged: (_) => setState(() {}),
    );
    final removeButton = IconButton(
      tooltip: 'حذف طريقة الدفع',
      onPressed: _payments.length == 1
          ? null
          : () {
              final removed = _payments[index];
              setState(() => _payments.removeAt(index));
              WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
            },
      icon: const Icon(Icons.remove_circle_outline),
    );

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 560) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            Row(children: [
              Expanded(child: methodField),
              const SizedBox(width: 8),
              Expanded(child: safeField),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: amountField),
              removeButton,
            ]),
          ]),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: methodField),
          const SizedBox(width: 8),
          Expanded(child: safeField),
          const SizedBox(width: 8),
          SizedBox(width: 150, child: amountField),
          removeButton,
        ]),
      );
    });
  }

  Widget _warningBox(String text) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.red.shade600.withAlpha(26),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.red.shade600.withAlpha(140)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.warning_amber_rounded, color: Colors.red.shade600, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.red.shade600))),
    ]),
  );

  Widget _paymentStatus() {
    final tiles = <Widget>[
      _statTile('الإجمالي المطلوب', money(_total), big: true),
      _statTile(_credit ? 'المدفوع الآن' : 'المستلم', money(_received), color: Colors.blue.shade600),
      if (_change > 0.005) _statTile('الباقي للعميل', money(_change), color: Colors.green.shade600),
      if (_credit) _statTile('المتبقي على العميل', money(_due), color: _due > 0.005 ? Colors.orange.shade700 : Colors.green.shade600),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _tileWrap(tiles),
      if (_change > 0.005) Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('يُسلَّم الباقي للعميل من الدرج${_drawerName.isEmpty ? '' : ' ($_drawerName)'} ولا يُحسب ضمن المدفوع.',
          style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Theme.of(context).hintColor)),
      ),
      if (_cashShortfall) _warningBox(
        'المبلغ المستلم أقل من الإجمالي بمقدار ${money(_total - _received)}. أكمل المبلغ أو امسحه ليُعتبر الدفع كاملًا، أو فعّل «فاتورة آجل» لتسجيل المتبقي على العميل.'),
    ]);
  }

  Widget _buildPaymentSection() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _creditSwitch(),
    const SizedBox(height: 12),
    Text(_credit ? 'المبلغ المدفوع الآن (اختياري)' : 'المبلغ المستلم من العميل',
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
    const SizedBox(height: 2),
    Text(
      _credit
          ? 'اتركه فارغًا لتسجيل كامل الفاتورة آجل.'
          : 'اتركه فارغًا للدفع الكامل، أو اكتب المبلغ المستلم ليُحسب الباقي للعميل.',
      style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Theme.of(context).hintColor)),
    const SizedBox(height: 6),
    ..._payments.asMap().entries.map((e) => _payRow(e.key)),
    Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: () => setState(() => _payments.add(PayLine(method: '${_methods.first['name']}', treasury: '${_safes.first['name']}'))),
        icon: const Icon(Icons.add), label: const Text('إضافة طريقة دفع')),
    ),
    const SizedBox(height: 6),
    _paymentStatus(),
  ]);

  // ───────────────────────── الحفظ والطباعة ─────────────────────────
  Future<void> _save({bool printAfter = false, bool shareAfter = false}) async {
    if (_branch == null || _store == null || _validSaleLines.isEmpty) { _message('اختر الفرع والمخزن وأضف صنفًا واحدًا على الأقل'); return; }
    if (_lines.any((line) => !line.isEmpty && line.product['code'] == null)) {
      _message('أكمل اختيار الصنف في كل سطر بدأته');
      return;
    }
    if (_credit && (_customer == null || _customer!.isEmpty)) { _message('اختر العميل لتسجيل فاتورة الآجل'); return; }
    if (_cashShortfall) {
      _message('المبلغ المستلم أقل من الإجمالي. أكمله أو امسحه، أو فعّل «فاتورة آجل».');
      return;
    }
    final payments = _netPayments();
    if (payments.any((p) => '${p['method']}'.isEmpty || '${p['treasury']}'.isEmpty)) { _message('حدد طريقة الدفع والخزينة لكل مبلغ مدفوع'); return; }
    setState(() => _busy = true);
    try {
      // لقطة من القيم قبل أي انتظار حتى لا تتغير أثناء الحفظ.
      final now = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final customer = _customers.firstWhere((e) => '${e['code']}' == _customer, orElse: () => {'name': 'عميل نقدي'});
      final received = _received, change = _change;
      final data = <String, dynamic>{
        'id': widget.editItem?['id']?.toString() ?? _service.newId(), 'company_code': widget.companyCode, 'branch_code': _branch, 'store_code': _store,
        if (widget.editItem != null) 'base_updated_at': widget.editItem!['updated_at'],
        'serial': widget.editItem?['serial'] ?? 0, 'date': widget.editItem?['date'] ?? now, 'customer_code': _customer ?? '', 'customer_name': customer['name'] ?? 'عميل نقدي',
        'cashier': _cashier, 'seller': _seller, 'items': _validSaleLines.map((l) => {'code': l.product['code'], 'name': l.product['name'], 'quantity': n(l.qty.text), 'price': n(l.price.text), 'total': l.amount}).toList(),
        'subtotal': _subtotal, 'discount': _discountValue, 'total': _total, 'paid': _paid, 'due': _due,
        'payments': payments, 'employee': widget.userName ?? '',
      };
      final stock = await StockBalanceService.calculateBalances(companyCode: widget.companyCode, branchCode: _branch!, storeCode: _store!, toDate: DateTime.now());
      final available = {for (final row in stock) '${row['code']}': n(row['quantity'])};
      if (widget.editItem != null &&
          widget.editItem!['branch_code']?.toString() == _branch &&
          widget.editItem!['store_code']?.toString() == _store &&
          widget.editItem!['items'] is List) {
        for (final old in (widget.editItem!['items'] as List).whereType<Map>()) {
          final code = '${old['code']}';
          available[code] = (available[code] ?? 0) + n(old['quantity']);
        }
      }
      final grouped = <String, double>{};
      for (final line in _validSaleLines) { grouped['${line.product['code']}'] = (grouped['${line.product['code']}'] ?? 0) + n(line.qty.text); }
      final shortage = grouped.entries.where((e) => e.value > (available[e.key] ?? 0) + .0001).firstOrNull;
      if (shortage != null) { _message('الكمية المطلوبة أكبر من رصيد الصنف ${shortage.key}'); return; }
      final saved = await _service.save('sales', data);
      if (printAfter || shareAfter) {
        // المستلم والباقي للعميل للطباعة فقط ولا يُرسلان مع الحفظ.
        await _outputInvoice({...data, 'serial': saved['serial'] ?? data['serial'], 'tendered': received, 'change': change}, share: shareAfter);
      }
      if (mounted) _message(saved['pending_sync'] == true
          ? 'تم حفظ الفاتورة على الجهاز، وجارٍ مزامنتها في الخلفية · رقم محلي ${saved['serial']}'
          : 'تم حفظ الفاتورة رقم ${saved['serial']}');
      if (widget.editItem == null && mounted) {
        final defaultMethod = _methods.isNotEmpty ? '${_methods.first['name'] ?? 'نقدي'}' : 'نقدي';
        final defaultSafe = _safes.isNotEmpty ? '${_safes.first['name'] ?? 'نقدي'}' : 'نقدي';
        final oldLines = List<SaleLine>.from(_lines);
        final oldPayments = List<PayLine>.from(_payments);
        _lines.clear();
        _payments..clear()..add(PayLine(method: defaultMethod, treasury: defaultSafe));
        _ensureEntryRow();
        _discount.text = '0';
        _discountPct.text = '0';
        _discountByPct = false;
        _credit = false;
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final line in oldLines) { line.dispose(); }
          for (final payment in oldPayments) { payment.dispose(); }
        });
        _focusEntryRow();
      }
    } catch (e) { _message('$e'); } finally { if (mounted) setState(() => _busy = false); }
  }

  JMap _draftPrintData() => {
    'serial': widget.editItem?['serial'] ?? 'مسودة', 'date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
    'customer_name': nameOf(_customers, _customer ?? ''), 'branch_code': _branch, 'store_code': _store,
    'items': _validSaleLines.map((l) => {'name': l.product['name'], 'quantity': n(l.qty.text), 'price': n(l.price.text), 'total': l.amount}).toList(),
    'subtotal': _subtotal, 'discount': _discountValue, 'total': _total, 'paid': _paid, 'due': _due,
    'tendered': _received, 'change': _change,
  };

  Future<Uint8List> _invoicePdf(JMap data) async {
    final doc = pw.Document();
    final font = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final isCredit = n(data['due']) > 0.005;
    final hasChange = data['tendered'] != null && n(data['change']) > 0.005;
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a5, theme: pw.ThemeData.withFont(base: font), build: (ctx) => pw.Directionality(textDirection: pw.TextDirection.rtl, child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Center(child: pw.Text('فاتورة مبيعات رقم ${data['serial'] ?? ''}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
      pw.SizedBox(height: 8), pw.Text('التاريخ: ${data['date']}     العميل: ${data['customer_name']}'), pw.Text('الفرع: ${nameOf(_branches, '${data['branch_code']}')}     المخزن: ${nameOf(_stores, '${data['store_code']}')}'),
      pw.Text('نوع الفاتورة: ${isCredit ? 'آجل' : 'نقدي'}'),
      pw.SizedBox(height: 10), pw.Table.fromTextArray(headers: ['الصنف', 'الكمية', 'السعر', 'الإجمالي'], data: (data['items'] as List).map((e) => ['${e['name']}', '${e['quantity']}', money(n(e['price'])), money(n(e['total']))]).toList()),
      pw.SizedBox(height: 10), pw.Text('الإجمالي قبل الخصم: ${money(n(data['subtotal']))}'), pw.Text('الخصم: ${money(n(data['discount']))}'), pw.Text('الإجمالي: ${money(n(data['total']))}'),
      if (hasChange) pw.Text('المستلم من العميل: ${money(n(data['tendered']))}'),
      if (hasChange) pw.Text('الباقي للعميل: ${money(n(data['change']))}'),
      pw.Text('المدفوع: ${money(n(data['paid']))}'),
      if (isCredit) pw.Text('المتبقي على العميل: ${money(n(data['due']))}'),
    ]))));
    return doc.save();
  }
  Future<void> _outputInvoice(JMap data, {required bool share}) async { final bytes = await _invoicePdf(data); if (share) { await Printing.sharePdf(bytes: bytes, filename: 'sale-${data['serial']}.pdf'); } else { await Printing.layoutPdf(onLayout: (_) async => bytes); } }

  Widget _buildActions() {
    final canPrint = PermissionsService().hasPermission('المبيعات', 'طباعة');
    final canShare = PermissionsService().hasPermission('المبيعات', 'مشاركة');
    final buttons = <Widget>[
      FilledButton.icon(onPressed: _busy ? null : () => _save(), icon: const Icon(Icons.save), label: const Text('حفظ')),
      if (canPrint) ...[
        OutlinedButton.icon(onPressed: _busy ? null : () => _save(printAfter: true), icon: const Icon(Icons.print), label: const Text('حفظ وطباعة')),
        OutlinedButton.icon(onPressed: _busy ? null : () => _outputInvoice(_draftPrintData(), share: false), icon: const Icon(Icons.print_outlined), label: const Text('طباعة بدون حفظ')),
      ],
      if (canShare) OutlinedButton.icon(onPressed: _busy ? null : () => _save(shareAfter: true), icon: const Icon(Icons.share), label: const Text('حفظ ومشاركة PDF')),
    ];
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 560) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final b in buttons) Padding(padding: const EdgeInsets.only(bottom: 8), child: SizedBox(height: 48, child: b)),
        ]);
      }
      return Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: buttons);
    });
  }

  // ───────────────────────── البناء ─────────────────────────
  @override
  Widget build(BuildContext context) => CommercialPageFrame(
    title: widget.editItem == null ? 'فاتورة مبيعات' : 'تعديل فاتورة مبيعات',
    child: _loading
        ? const Center(child: CircularProgressIndicator())
        : Form(key: _form, child: LayoutBuilder(builder: (context, c) {
            final pad = c.maxWidth < 600 ? 10.0 : 16.0;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: ListView(padding: EdgeInsets.all(pad), children: [
                  _responsiveFields([
                    _drop('الفرع', _branch, _branches, (v) { setState(() { _branch = v; _stores = storesForBranch(widget.companyCode, v); if (!_stores.any((e) => '${e['code']}' == _store)) _store = _stores.firstOrNull?['code']?.toString(); }); }),
                    _drop('المخزن', _store, _stores, (v) => setState(() => _store = v)),
                    _drop('العميل', _customer, _customers, (v) => setState(() => _customer = v)),
                    _peopleDrop('الكاشير', _cashier, (v) => setState(() => _cashier = v ?? '')),
                    _peopleDrop('البائع', _seller, (v) => setState(() => _seller = v ?? '')),
                    _scanButton(),
                  ]),
                  const SizedBox(height: 14),
                  _sectionTitle('الأصناف (${_validSaleLines.length})', Icons.shopping_cart_outlined),
                  _buildSalesItems(),
                  const SizedBox(height: 12),
                  Card(child: Padding(padding: const EdgeInsets.all(12), child: _buildDiscountAndTotals())),
                  const SizedBox(height: 8),
                  Card(child: Padding(padding: const EdgeInsets.all(12), child: _buildPaymentSection())),
                  const SizedBox(height: 14),
                  _buildActions(),
                  if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                ]),
              ),
            );
          })),
  );
}
