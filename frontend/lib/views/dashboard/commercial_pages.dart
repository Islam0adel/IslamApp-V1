import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../core/theme.dart';
import '../../services/commercial_service.dart';
import '../../services/permissions_service.dart';
import '../../services/stock_balance_service.dart';

typedef JMap = Map<String, dynamic>;
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull { final iterator = this.iterator; return iterator.moveNext() ? iterator.current : null; }
}
double _n(dynamic x) => x is num ? x.toDouble() : double.tryParse(x?.toString() ?? '') ?? 0;
String _money(num x) => NumberFormat('#,##0.##', 'en').format(x);
String _plain(num x) => x.isFinite && x == x.roundToDouble() ? x.toInt().toString() : x.toString();

List<JMap> _catalog(String company, String category) {
  final raw = Hive.box('coding_box').get('${company}_$category', defaultValue: []);
  if (raw is! List) return [];
  return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).where((e) => e['is_deleted'] != true).toList();
}

List<JMap> _storesForBranch(String company, String? branchCode) =>
    _catalog(company, 'stores').where((store) {
      final assigned = store['branch_code']?.toString() ?? '';
      return assigned.isEmpty || assigned == branchCode;
    }).toList();

String _name(List<JMap> data, String code) => data.firstWhere((e) => '${e['code']}' == code, orElse: () => {'name': code})['name']?.toString() ?? code;

class CommercialPageFrame extends StatelessWidget {
  final String title;
  final Widget child;
  const CommercialPageFrame({super.key, required this.title, required this.child});
  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(title: Text(title, style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo', fontWeight: FontWeight.bold)), centerTitle: true, backgroundColor: AppTheme.appBarBg, elevation: 0),
    body: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: AppTheme.dashGradientDeep(context), begin: Alignment.topLeft, end: Alignment.bottomRight)), child: SafeArea(child: child)),
  );
}

class SalesPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? userName;
  final JMap? editItem;
  const SalesPage({super.key, required this.companyCode, this.selectedBranchCode, this.userName, this.editItem});
  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SaleLine {
  JMap product;
  final TextEditingController code;
  final TextEditingController name;
  final TextEditingController qty;
  final TextEditingController price;
  final FocusNode codeFocus = FocusNode();
  final FocusNode nameFocus = FocusNode();
  final FocusNode qtyFocus = FocusNode();
  final FocusNode priceFocus = FocusNode();
  _SaleLine(this.product, double quantity, double unitPrice)
      : code = TextEditingController(text: '${product['code'] ?? ''}'),
        name = TextEditingController(text: '${product['name'] ?? ''}'),
        qty = TextEditingController(text: quantity == 0 ? '' : _plain(quantity)),
        price = TextEditingController(text: (unitPrice == 0 && product.isEmpty) ? '' : _plain(unitPrice)) {
    // عند الدخول على الكمية/السعر يُحدَّد النص كله ليُستبدل مباشرة بما يُكتب.
    void selectAllOnFocus(FocusNode node, TextEditingController c) => node.addListener(() {
      if (node.hasFocus) c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    });
    selectAllOnFocus(qtyFocus, qty);
    selectAllOnFocus(priceFocus, price);
  }
  double get amount => _n(qty.text) * _n(price.text);
  bool get isEmpty => code.text.trim().isEmpty && name.text.trim().isEmpty;
  void dispose() {
    code.dispose();
    name.dispose();
    qty.dispose();
    price.dispose();
    codeFocus.dispose();
    nameFocus.dispose();
    qtyFocus.dispose();
    priceFocus.dispose();
  }
}

class _ReturnLine {
  JMap? product;
  final TextEditingController code;
  final TextEditingController name;
  final TextEditingController qty;
  final FocusNode nameFocus = FocusNode();
  final FocusNode qtyFocus = FocusNode();

  _ReturnLine({this.product, double quantity = 0})
      : code = TextEditingController(text: '${product?['code'] ?? ''}'),
        name = TextEditingController(text: '${product?['name'] ?? ''}'),
        qty = TextEditingController(text: quantity == 0 ? '' : '$quantity');

  double get amount => _n(qty.text) * _n(product?['price']);

  void dispose() {
    code.dispose();
    name.dispose();
    qty.dispose();
    nameFocus.dispose();
    qtyFocus.dispose();
  }
}

class _PayLine {
  String method;
  String treasury;
  final TextEditingController amount;
  _PayLine({this.method = '', this.treasury = '', double value = 0}) : amount = TextEditingController(text: value == 0 ? '' : '$value');
  void dispose() => amount.dispose();
}

class _SalesPageState extends State<SalesPage> {
  static const double _wideBreakpoint = 760;

  final _service = CommercialService();
  final _discount = TextEditingController(text: '0');
  final _discountPct = TextEditingController(text: '0');
  final _lines = <_SaleLine>[];
  final _payments = <_PayLine>[];
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
  List<_SaleLine> get _validSaleLines => _lines.where((line) =>
      (line.product['code']?.toString().isNotEmpty ?? false) && _n(line.qty.text) > 0).toList();
  double get _subtotal => _validSaleLines.fold<double>(0.0, (s, e) => s + e.amount);

  /// مبلغ الخصم الفعلي (لا يقل عن صفر ولا يزيد عن مجموع الأصناف).
  double get _discountValue {
    final v = _n(_discount.text);
    final sub = _subtotal;
    if (v < 0) return 0;
    return v > sub ? sub : v;
  }

  double get _total => _subtotal - _discountValue;

  /// مجموع المبالغ المكتوبة في سطور الدفع.
  double get _enteredTotal => _payments.fold<double>(0.0, (s, e) => s + _n(e.amount.text));
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
    final entered = _payments.where((p) => _n(p.amount.text) > 0);
    final p = entered.isNotEmpty ? entered.first : (_payments.isNotEmpty ? _payments.first : null);
    return p?.treasury ?? '';
  }

  /// سطور الدفع الصافية: المستلم ناقص الباقي المردود من الدرج (أول خزينة).
  List<JMap> _netPayments() {
    final paid = _paid;
    if (paid <= 0.0001) return [];
    final entered = _payments
        .where((p) => _n(p.amount.text) > 0)
        .map<JMap>((p) => {'method': p.method, 'treasury': p.treasury, 'amount': _n(p.amount.text)})
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
    final pct = _n(_discountPct.text).clamp(0, 100).toDouble();
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

  _SaleLine _newSaleLine(JMap product, double quantity, double price) {
    final line = _SaleLine(product, quantity, price);
    line.qty.addListener(_refresh);
    line.price.addListener(_refresh);
    return line;
  }

  Future<void> _load() async {
    final company = widget.companyCode;
    _branches = _catalog(company, 'branches');
    _customers = _catalog(company, 'customers'); _products = _catalog(company, 'items');
    _methods = _catalog(company, 'payment_methods'); _safes = _catalog(company, 'safes');
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
    _stores = _storesForBranch(company, _branch);
    _store = widget.editItem?['store_code']?.toString() ?? _stores.firstOrNull?['code']?.toString();
    _customer = widget.editItem?['customer_code']?.toString() ?? _customers.firstOrNull?['code']?.toString();
    _cashier = widget.editItem?['cashier']?.toString() ?? widget.userName ?? '';
    _seller = widget.editItem?['seller']?.toString() ?? '';
    if (_cashier.isNotEmpty && !_people.any((u) => (u['name'] ?? u['user_name'] ?? u['email'])?.toString() == _cashier)) _people.add({'name': _cashier});
    if (_seller.isNotEmpty && !_people.any((u) => (u['name'] ?? u['user_name'] ?? u['email'])?.toString() == _seller)) _people.add({'name': _seller});
    if (_methods.isEmpty) _methods = [{'name': 'نقدي'}];
    if (_safes.isEmpty) _safes = [{'name': 'نقدي'}];
    if (_methods.isNotEmpty && _safes.isNotEmpty) _payments.add(_PayLine(method: '${_methods.first['name']}', treasury: '${_safes.first['name']}'));
    if (widget.editItem != null) {
      final d = widget.editItem!;
      _credit = _n(d['due']) > 0.009;
      _discount.text = '${d['discount'] ?? 0}';
      if (d['items'] is List) for (final item in d['items']) { if (item is Map) { final p = _products.firstWhere((x) => '${x['code']}' == '${item['code']}', orElse: () => Map<String, dynamic>.from(item)); _lines.add(_newSaleLine(p, _n(item['quantity']), _n(item['price']))); } }
      if (d['payments'] is List && (d['payments'] as List).isNotEmpty) {
        for (final payment in _payments) {
          payment.dispose();
        }
        _payments.clear();
        for (final p in d['payments']) { if (p is Map) _payments.add(_PayLine(method: '${p['method'] ?? ''}', treasury: '${p['treasury'] ?? ''}', value: _n(p['amount']))); }
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
  void _finishLine(_SaleLine line) {
    final hasProduct = line.product['code']?.toString().isNotEmpty ?? false;
    if (!hasProduct) { line.codeFocus.requestFocus(); return; }
    if (_n(line.qty.text) <= 0) { line.qtyFocus.requestFocus(); return; }
    _startNewEntry();
  }

  void _removeLine(_SaleLine line) {
    setState(() {
      _lines.remove(line);
      _ensureEntryRow();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => line.dispose());
  }

  void _selectSaleProduct(_SaleLine line, JMap product, {double? quantity, bool focusQty = true}) {
    final sameProduct = line.product['code']?.toString() == product['code']?.toString();
    final oldPrice = line.price.text.trim();
    line.product = product;
    line.code.text = '${product['code'] ?? ''}';
    line.name.text = '${product['name'] ?? ''}';
    if (quantity != null) line.qty.text = _plain(quantity);
    if (!sameProduct || oldPrice.isEmpty) {
      line.price.text = _plain(_n(product['selling_price'] ?? product['sellingPrice']));
    }
    if (mounted) setState(() {});
    if (focusQty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) line.qtyFocus.requestFocus();
      });
    }
  }

  void _submitSaleCode(_SaleLine line) {
    final value = line.code.text.trim();
    final product = value.isEmpty ? null : _products.where((item) =>
      item['code']?.toString() == value || item['barcode']?.toString() == value,
    ).firstOrNull;
    if (product == null) {
      line.nameFocus.requestFocus();
      return;
    }
    _selectSaleProduct(line, product, quantity: _n(line.qty.text) == 0 ? 1.0 : null);
  }

  /// إضافة صنف من مسح الكاميرا: لو موجود تزيد كميته، وإلا يُدخل في صف الإدخال وينزل تحته.
  void _addProduct(JMap p) {
    final existing = _lines.where((x) => '${x.product['code']}' == '${p['code']}').firstOrNull;
    if (existing != null) {
      existing.qty.text = _plain(_n(existing.qty.text) + 1);
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

  Widget _codeField(_SaleLine line, {required bool compact}) => _saleCell(
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

  Widget _nameField(_SaleLine line, {required bool compact}) => LayoutBuilder(builder: (context, c) {
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
        quantity: _n(line.qty.text) == 0 ? 1.0 : null),
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
                quantity: _n(line.qty.text) == 0 ? 1.0 : null);
            }
          }),
    );
  });

  Widget _qtyField(_SaleLine line, {required bool compact}) => _saleCell(
    label: 'الكمية', compact: compact, controller: line.qty, focusNode: line.qtyFocus,
    keyboard: const TextInputType.numberWithOptions(decimal: true),
    action: PermissionsService().canChangeSellingPrice ? TextInputAction.next : TextInputAction.done,
    onChanged: (_) => setState(() {}),
    onSubmitted: (_) => PermissionsService().canChangeSellingPrice
        ? line.priceFocus.requestFocus()
        : _finishLine(line));

  Widget _priceField(_SaleLine line, {required bool compact}) => _saleCell(
    label: 'سعر البيع', compact: compact, controller: line.price, focusNode: line.priceFocus,
    keyboard: const TextInputType.numberWithOptions(decimal: true),
    enabled: PermissionsService().canChangeSellingPrice,
    action: TextInputAction.done,
    onChanged: (_) => setState(() {}),
    onSubmitted: (_) => _finishLine(line));

  Widget _totalBox(_SaleLine line) => InputDecorator(
    decoration: InputDecoration(
      labelText: 'الإجمالي', isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
    child: SizedBox(
      width: double.infinity,
      child: Text(_money(line.amount), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
    ),
  );

  /// صف الإدخال (الأول): زر ✓ لإنزال الصنف. باقي الصفوف: زر حذف.
  Widget _rowAction(_SaleLine line, int index) {
    if (index == 0) {
      final ready = (line.product['code']?.toString().isNotEmpty ?? false) && _n(line.qty.text) > 0;
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
            _money(_n(line.product['wholesale_price'] ?? line.product['wholesalePrice'])),
            textAlign: TextAlign.center)),
        ],
        const SizedBox(width: 6),
        Expanded(flex: 2, child: Text(_money(line.amount), textAlign: TextAlign.center,
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
          child: Text('سعر الجملة: ${_money(_n(line.product['wholesale_price'] ?? line.product['wholesalePrice']))}',
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
      decoration: _fieldDecoration('نسبة الخصم', suffixText: '%', errorText: _n(_discountPct.text) > 100 ? 'الحد الأقصى 100%' : null),
      onChanged: (_) { _discountByPct = true; _setDiscountAmountFromPct(); setState(() {}); },
    );
    final fields = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: amountField),
      const SizedBox(width: 10),
      Expanded(child: pctField),
    ]);
    final tiles = _tileWrap([
      _statTile('المجموع قبل الخصم', _money(_subtotal)),
      _statTile('قيمة الخصم', _money(_discountValue), color: Colors.red.shade600),
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
              ? 'المتبقي بعد المدفوع يُسجَّل على العميل: ${_name(_customers, _customer ?? '')}'
              : 'فاتورة نقدية: تُحصَّل كاملة، واترك المبلغ فارغًا للدفع الكامل.',
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
        ),
      ),
    );
  }

  void _fillPayment(int index) {
    var others = 0.0;
    for (var i = 0; i < _payments.length; i++) {
      if (i != index) others += _n(_payments[i].amount.text);
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
        hint: (index == 0 && !_credit) ? _money(_total) : '0',
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
      _statTile('الإجمالي المطلوب', _money(_total), big: true),
      _statTile(_credit ? 'المدفوع الآن' : 'المستلم', _money(_received), color: Colors.blue.shade600),
      if (_change > 0.005) _statTile('الباقي للعميل', _money(_change), color: Colors.green.shade600),
      if (_credit) _statTile('المتبقي على العميل', _money(_due), color: _due > 0.005 ? Colors.orange.shade700 : Colors.green.shade600),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _tileWrap(tiles),
      if (_change > 0.005) Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('يُسلَّم الباقي للعميل من الدرج${_drawerName.isEmpty ? '' : ' ($_drawerName)'} ولا يُحسب ضمن المدفوع.',
          style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Theme.of(context).hintColor)),
      ),
      if (_cashShortfall) _warningBox(
        'المبلغ المستلم أقل من الإجمالي بمقدار ${_money(_total - _received)}. أكمل المبلغ أو امسحه ليُعتبر الدفع كاملًا، أو فعّل «فاتورة آجل» لتسجيل المتبقي على العميل.'),
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
        onPressed: () => setState(() => _payments.add(_PayLine(method: '${_methods.first['name']}', treasury: '${_safes.first['name']}'))),
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
        'cashier': _cashier, 'seller': _seller, 'items': _validSaleLines.map((l) => {'code': l.product['code'], 'name': l.product['name'], 'quantity': _n(l.qty.text), 'price': _n(l.price.text), 'total': l.amount}).toList(),
        'subtotal': _subtotal, 'discount': _discountValue, 'total': _total, 'paid': _paid, 'due': _due,
        'payments': payments, 'employee': widget.userName ?? '',
      };
      final stock = await StockBalanceService.calculateBalances(companyCode: widget.companyCode, branchCode: _branch!, storeCode: _store!, toDate: DateTime.now());
      final available = {for (final row in stock) '${row['code']}': _n(row['quantity'])};
      if (widget.editItem != null &&
          widget.editItem!['branch_code']?.toString() == _branch &&
          widget.editItem!['store_code']?.toString() == _store &&
          widget.editItem!['items'] is List) {
        for (final old in (widget.editItem!['items'] as List).whereType<Map>()) {
          final code = '${old['code']}';
          available[code] = (available[code] ?? 0) + _n(old['quantity']);
        }
      }
      final grouped = <String, double>{};
      for (final line in _validSaleLines) { grouped['${line.product['code']}'] = (grouped['${line.product['code']}'] ?? 0) + _n(line.qty.text); }
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
        final oldLines = List<_SaleLine>.from(_lines);
        final oldPayments = List<_PayLine>.from(_payments);
        _lines.clear();
        _payments..clear()..add(_PayLine(method: defaultMethod, treasury: defaultSafe));
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
    'customer_name': _name(_customers, _customer ?? ''), 'branch_code': _branch, 'store_code': _store,
    'items': _validSaleLines.map((l) => {'name': l.product['name'], 'quantity': _n(l.qty.text), 'price': _n(l.price.text), 'total': l.amount}).toList(),
    'subtotal': _subtotal, 'discount': _discountValue, 'total': _total, 'paid': _paid, 'due': _due,
    'tendered': _received, 'change': _change,
  };

  Future<Uint8List> _invoicePdf(JMap data) async {
    final doc = pw.Document();
    final font = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final isCredit = _n(data['due']) > 0.005;
    final hasChange = data['tendered'] != null && _n(data['change']) > 0.005;
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a5, theme: pw.ThemeData.withFont(base: font), build: (ctx) => pw.Directionality(textDirection: pw.TextDirection.rtl, child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Center(child: pw.Text('فاتورة مبيعات رقم ${data['serial'] ?? ''}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
      pw.SizedBox(height: 8), pw.Text('التاريخ: ${data['date']}     العميل: ${data['customer_name']}'), pw.Text('الفرع: ${_name(_branches, '${data['branch_code']}')}     المخزن: ${_name(_stores, '${data['store_code']}')}'),
      pw.Text('نوع الفاتورة: ${isCredit ? 'آجل' : 'نقدي'}'),
      pw.SizedBox(height: 10), pw.Table.fromTextArray(headers: ['الصنف', 'الكمية', 'السعر', 'الإجمالي'], data: (data['items'] as List).map((e) => ['${e['name']}', '${e['quantity']}', _money(_n(e['price'])), _money(_n(e['total']))]).toList()),
      pw.SizedBox(height: 10), pw.Text('الإجمالي قبل الخصم: ${_money(_n(data['subtotal']))}'), pw.Text('الخصم: ${_money(_n(data['discount']))}'), pw.Text('الإجمالي: ${_money(_n(data['total']))}'),
      if (hasChange) pw.Text('المستلم من العميل: ${_money(_n(data['tendered']))}'),
      if (hasChange) pw.Text('الباقي للعميل: ${_money(_n(data['change']))}'),
      pw.Text('المدفوع: ${_money(_n(data['paid']))}'),
      if (isCredit) pw.Text('المتبقي على العميل: ${_money(_n(data['due']))}'),
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
                    _drop('الفرع', _branch, _branches, (v) { setState(() { _branch = v; _stores = _storesForBranch(widget.companyCode, v); if (!_stores.any((e) => '${e['code']}' == _store)) _store = _stores.firstOrNull?['code']?.toString(); }); }),
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

class SalesHistoryPage extends StatefulWidget {
  final String companyCode; final String? branchCode; final String? userName;
  const SalesHistoryPage({super.key, required this.companyCode, this.branchCode, this.userName});
  @override State<SalesHistoryPage> createState() => _SalesHistoryPageState();
}
class _SalesHistoryPageState extends State<SalesHistoryPage> {
  final _service = CommercialService(); List<JMap> _records = []; bool _busy = true;
  StreamSubscription<BoxEvent>? _salesSubscription;
  @override void initState() { super.initState(); _salesSubscription = Hive.box('sales_box').watch().listen((_) => _load()); _load(); }
  @override void dispose() { _salesSubscription?.cancel(); super.dispose(); }
  Future<void> _load() async { try { _records = await _service.fetch('sales', widget.companyCode, branchCode: widget.branchCode); } catch (_) {} if (mounted) setState(() => _busy = false); }
  Future<void> _refreshFromServer() async { await _service.fetch('sales', widget.companyCode, branchCode: widget.branchCode, forceRefresh: true); await _load(); }
  Future<void> _delete(JMap r) async { try { await _service.delete('sales', widget.companyCode, '${r['id']}'); await _load(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); } }
  @override Widget build(BuildContext context) => CommercialPageFrame(title: 'معاينة المبيعات', child: _busy ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _refreshFromServer, child: ListView(padding: const EdgeInsets.all(14), children: _records.map<Widget>((r) => Card(
  child: ListTile(
    title: Text('فاتورة ${r['serial']} · ${r['customer_name']}'),
subtitle: Text(
  '${r['date']} · الإجمالي ${_money(_n(r['total']))} · الباقي ${_money(_n(r['due']))}'
  '${r['sync_status'] == 'pending' ? ' · بانتظار المزامنة' : ''}'
  '${r['sync_status'] == 'error' ? ' · تعذرت المزامنة، تحقق من الاتصال والصلاحية' : ''}'
  '${r['sync_status'] == 'conflict' ? ' · تغيّرت على جهاز آخر؛ حدّث القائمة ثم أعد تطبيق تعديلك' : ''}',
),
    trailing: Wrap(
      children: [
        if (PermissionsService().hasPermission('المبيعات', 'تعديل'))
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
        if (PermissionsService().hasPermission('المبيعات', 'حذف'))
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(r),
          ),
      ],
    ),
  ),
)).toList(),)));
}

class SaleReturnPage extends StatefulWidget {
  final String companyCode; final String? selectedBranchCode; final String? userName; final JMap? editItem;
  const SaleReturnPage({super.key, required this.companyCode, this.selectedBranchCode, this.userName, this.editItem});
  @override State<SaleReturnPage> createState() => _SaleReturnPageState();
}
class _SaleReturnPageState extends State<SaleReturnPage> {
  final _service = CommercialService();
  List<JMap> _sales = [], _stores = [], _methods = [], _safes = [];
  final _lines = <_ReturnLine>[];
  JMap? _sale;
  String? _store, _method, _safe;
  bool _busy = false;
  final List<StreamSubscription<BoxEvent>> _localSubscriptions = [];
  double _customerBalance = 0;
  String _settlementMode = 'credit_first';
  final Map<String, double> _alreadyReturned = {};

  List<JMap> get _invoiceItems => (_sale?['items'] as List? ?? [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();

  double _availableQuantity(JMap item) =>
      (_n(item['quantity']) - (_alreadyReturned['${item['code']}'] ?? 0))
          .clamp(0, double.infinity)
          .toDouble();

  List<JMap> _optionsFor(_ReturnLine line) => _invoiceItems.where((item) {
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
      _localSubscriptions.add(Hive.box(name).watch().listen((_) => _refreshSelectedSaleContext()));
    }
    _load();
  }

  @override
  void dispose() {
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
        _alreadyReturned[code] = (_n(item['quantity']) - _n(remaining[code]))
            .clamp(0, double.infinity).toDouble();
      }
      _sale = refreshedSale;
      _customerBalance = _n(state['customer_balance']);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _load() async {
    final branch = widget.editItem?['branch_code']?.toString() ?? widget.selectedBranchCode;
    try {
      _sales = await _service.fetch('sales', widget.companyCode, branchCode: branch);
    } catch (_) {}
    _stores = _storesForBranch(widget.companyCode, branch);
    _methods = _catalog(widget.companyCode, 'payment_methods');
    _safes = _catalog(widget.companyCode, 'safes');
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
          _alreadyReturned[code] = (_n(item['quantity']) - _n(remaining[code])).clamp(0, double.infinity).toDouble();
        }
        _customerBalance = _n(state['customer_balance']);
      } catch (_) {}
      if (widget.editItem != null && widget.editItem!['sale_id']?.toString() == value['id']?.toString() && widget.editItem!['items'] is List) {
        for (final item in (widget.editItem!['items'] as List).whereType<Map>()) {
          final product = _invoiceItems.where((row) => row['code']?.toString() == item['code']?.toString()).firstOrNull;
          if (product != null) {
            _lines.add(_ReturnLine(product: product, quantity: _n(item['quantity'])));
          }
        }
      }
      if (_hasAvailableReturnItem) _lines.add(_ReturnLine());
    }
    if (mounted) setState(() {});
  }

  void _addReturnLine() {
    if (_sale == null || !_hasAvailableReturnItem) return;
    final line = _ReturnLine();
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) line.nameFocus.requestFocus();
    });
  }

  void _selectReturnProduct(_ReturnLine line, JMap product) {
    if (_lines.any((other) => !identical(other, line) &&
        other.product?['code']?.toString() == product['code']?.toString())) {
      return;
    }
    line.product = product;
    line.code.text = '${product['code'] ?? ''}';
    line.name.text = '${product['name'] ?? ''}';
    if (_n(line.qty.text) <= 0) line.qty.text = '1';
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) line.qtyFocus.requestFocus();
    });
  }

  void _submitReturnProduct(_ReturnLine line, String value) {
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
    if (product != null && _n(line.qty.text) > _availableQuantity(product) + .0001) {
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
                  line.product == null ? '—' : _money(_availableQuantity(line.product!)),
                  textAlign: TextAlign.center,
                )),
                const SizedBox(width: 5),
                SizedBox(width: 105, child: TextField(
                  controller: line.qty,
                  focusNode: line.qtyFocus,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: index == _lines.length - 1 ? TextInputAction.done : TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submitReturnQuantity(index),
                  decoration: const InputDecoration(hintText: 'الكمية', isDense: true),
                )),
                const SizedBox(width: 5),
                SizedBox(width: 90, child: Text(
                  line.product == null ? '—' : _money(_n(line.product!['price'])),
                  textAlign: TextAlign.center,
                )),
                const SizedBox(width: 5),
                SizedBox(width: 100, child: Text(_money(line.amount), textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold))),
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
    final selectedLines = _lines.where((line) => line.product != null && _n(line.qty.text) > 0).toList();
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
      if (_n(line.qty.text) > _availableQuantity(item) + .0001) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('الكمية المرتجعة للصنف ${item['name']} أكبر من المتاح')));
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final items = selectedLines.map((line) => {
        'code': line.product!['code'],
        'name': line.product!['name'],
        'quantity': _n(line.qty.text),
        'price': _n(line.product!['price']),
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
      Text('رصيد العميل الآجل: ${_money(_customerBalance)} · قيمة المرتجع: ${_money(_returnTotal)} · تخصم من المديونية: ${_money(_creditAmount)} · المردود من الخزينة: ${_money(_refundAmount)}'),
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
      FilledButton.icon(
        onPressed: _busy ? null : _save,
        icon: const Icon(Icons.save),
        label: Text(widget.editItem == null ? 'حفظ المرتجع' : 'حفظ التعديل'),
      ),
    ]),
  );
}

class CustomerPaymentsPage extends StatefulWidget {
  final String companyCode; final String? branchCode; final String? userName; final JMap? editItem;
  const CustomerPaymentsPage({super.key, required this.companyCode, this.branchCode, this.userName, this.editItem});
  @override State<CustomerPaymentsPage> createState() => _CustomerPaymentsPageState();
}
class _CustomerPaymentsPageState extends State<CustomerPaymentsPage> {
  final _service = CommercialService(); final _amount = TextEditingController(); List<JMap> _customers = [], _branches = [], _methods = [], _safes = []; String? _customer, _branch, _method, _safe; bool _busy = false;
  @override void initState() { super.initState(); _customers = _catalog(widget.companyCode, 'customers'); _branches = _catalog(widget.companyCode, 'branches').where((b) => PermissionsService().canAccessBranch('${b['code']}')).toList(); _methods = _catalog(widget.companyCode, 'payment_methods'); _safes = _catalog(widget.companyCode, 'safes'); _branch = widget.editItem?['branch_code']?.toString() ?? widget.branchCode ?? _branches.firstOrNull?['code']?.toString(); _customer = widget.editItem?['customer_code']?.toString() ?? _customers.firstOrNull?['code']?.toString(); _method = ((widget.editItem?['payments'] as List?)?.firstOrNull as Map?)?['method']?.toString() ?? _methods.firstOrNull?['name']?.toString(); _safe = ((widget.editItem?['payments'] as List?)?.firstOrNull as Map?)?['treasury']?.toString() ?? _safes.firstOrNull?['name']?.toString(); if (widget.editItem != null) _amount.text = '${widget.editItem!['amount'] ?? 0}'; }
  Future<void> _save() async { if (_branch == null || _customer == null || _method == null || _safe == null || _n(_amount.text) <= 0) return; setState(() => _busy = true); try { final c = _customers.firstWhere((e) => '${e['code']}' == _customer); await _service.save('customer-payments', {'id': widget.editItem?['id']?.toString() ?? _service.newId(), 'company_code': widget.companyCode, 'branch_code': _branch, if (widget.editItem != null) 'base_updated_at': widget.editItem!['updated_at'], 'serial': widget.editItem?['serial'] ?? 0, 'date': widget.editItem?['date'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now()), 'customer_code': _customer, 'customer_name': c['name'], 'amount': _n(_amount.text), 'payments': [{'method': _method, 'treasury': _safe, 'amount': _n(_amount.text)}], 'statement': 'تحصيل مديونية عميل', 'employee': widget.userName ?? ''}); if (widget.editItem == null) _amount.clear(); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ التحصيل'))); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); } finally { if (mounted) setState(() => _busy = false); } }
  @override Widget build(BuildContext context) => CommercialPageFrame(title: 'تحصيل من عميل', child: ListView(padding: const EdgeInsets.all(16), children: [DropdownButtonFormField<String>(initialValue: _customers.any((c) => '${c['code']}' == _customer) ? _customer : null, decoration: const InputDecoration(labelText: 'العميل'), items: _customers.map((c) => DropdownMenuItem(value: '${c['code']}', child: Text('${c['name']}'))).toList(), onChanged: (v) => setState(() => _customer = v)), DropdownButtonFormField<String>(initialValue: _branches.any((b) => '${b['code']}' == _branch) ? _branch : null, decoration: const InputDecoration(labelText: 'الفرع'), items: _branches.map((b) => DropdownMenuItem(value: '${b['code']}', child: Text('${b['name']}'))).toList(), onChanged: (v) => setState(() => _branch = v)), TextField(controller: _amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ المحصل')), DropdownButtonFormField<String>(initialValue: _methods.any((m) => '${m['name']}' == _method) ? _method : null, decoration: const InputDecoration(labelText: 'طريقة الدفع'), items: _methods.map((m) => DropdownMenuItem(value: '${m['name']}', child: Text('${m['name']}'))).toList(), onChanged: (v) => setState(() => _method = v)), DropdownButtonFormField<String>(initialValue: _safes.any((s) => '${s['name']}' == _safe) ? _safe : null, decoration: const InputDecoration(labelText: 'الخزينة'), items: _safes.map((s) => DropdownMenuItem(value: '${s['name']}', child: Text('${s['name']}'))).toList(), onChanged: (v) => setState(() => _safe = v)), const SizedBox(height: 14), FilledButton.icon(onPressed: _busy ? null : _save, icon: const Icon(Icons.save), label: const Text('تسجيل التحصيل'))]));
}

class StockTransfersPage extends StatefulWidget {
  final String companyCode; final String? branchCode; final String? userName; final JMap? editItem;
  const StockTransfersPage({super.key, required this.companyCode, this.branchCode, this.userName, this.editItem});
  @override State<StockTransfersPage> createState() => _StockTransfersPageState();
}
class _StockTransfersPageState extends State<StockTransfersPage> {
  final _service = CommercialService();
  List<JMap> _branches = [], _products = [];
  final _items = <_SaleLine>[];

  String? _fromBranch, _toBranch, _fromStore, _toStore;
  bool _busy = false;

  @override
  void dispose() {
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  List<JMap> get _fromStores =>
      _storesForBranch(widget.companyCode, _fromBranch);

  List<JMap> get _toStores =>
      _storesForBranch(widget.companyCode, _toBranch);

  @override
  void initState() {
    super.initState();

    _branches = _catalog(widget.companyCode, 'branches')
        .where((b) => PermissionsService().canAccessBranch('${b['code']}'))
        .toList();
    _products = _catalog(widget.companyCode, 'items');

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
          final product = _products.firstWhere(
            (e) => '${e['code']}' == '${item['code']}',
            orElse: () => Map<String, dynamic>.from(item),
          );
          _items.add(
            _SaleLine(
              product,
              _n(item['quantity']),
              _n(item['price']),
            ),
          );
        }
      }
    }
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
        for (final s in stock) '${s['code']}': _n(s['quantity']),
      };

      if (widget.editItem != null &&
          widget.editItem!['from_branch_code']?.toString() == _fromBranch &&
          widget.editItem!['from_store_code']?.toString() == _fromStore &&
          widget.editItem!['items'] is List) {
        for (final old
            in (widget.editItem!['items'] as List).whereType<Map>()) {
          final code = '${old['code']}';
          balances[code] = (balances[code] ?? 0) + _n(old['quantity']);
        }
      }

      for (final item in _items) {
        if (_n(item.qty.text) >
            (balances['${item.product['code']}'] ?? 0)) {
          throw Exception(
            'الكمية غير متاحة في المخزن المصدر للصنف '
            '${item.product['name']}',
          );
        }
      }

      await _service.save('transfers', {
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
                  'quantity': _n(item.qty.text),
                  'price': _n(item.price.text),
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
            optionsBuilder: (value) => _products.where(
              (e) => '${e['code']} ${e['name']}'
                  .toLowerCase()
                  .contains(value.text.toLowerCase()),
            ),
            onSelected: (product) {
              if (!_items.any(
                (item) => '${item.product['code']}' == '${product['code']}',
              )) {
                setState(() => _items.add(_SaleLine(product, 1, 0)));
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

class CommercialHistoryPage extends StatefulWidget {
  final String companyCode; final String kind; final String title; final String? branchCode;
  const CommercialHistoryPage({super.key, required this.companyCode, required this.kind, required this.title, this.branchCode});
  @override State<CommercialHistoryPage> createState() => _CommercialHistoryPageState();
}
class _CommercialHistoryPageState extends State<CommercialHistoryPage> {
  final _service = CommercialService(); List<JMap> _rows = []; bool _busy = true;
  StreamSubscription<BoxEvent>? _recordsSubscription;
  String get _boxName => widget.kind == 'returns' ? 'sales_returns_box' : widget.kind == 'customer-payments' ? 'customer_payments_box' : 'stock_transfers_box';
  @override void initState() { super.initState(); _recordsSubscription = Hive.box(_boxName).watch().listen((_) => _load()); _load(); }
  @override void dispose() { _recordsSubscription?.cancel(); super.dispose(); }
  Future<void> _load() async { try { _rows = await _service.fetch(widget.kind, widget.companyCode, branchCode: widget.branchCode); } catch (_) {} if (mounted) setState(() => _busy = false); }
  Future<void> _refreshFromServer() async { await _service.fetch(widget.kind, widget.companyCode, branchCode: widget.branchCode, forceRefresh: true); await _load(); }
  String get _category => widget.kind == 'returns' ? 'المرتجعات' : widget.kind == 'customer-payments' ? 'حسابات العملاء' : 'التحويلات المخزنية';
  Future<void> _delete(JMap r) async { try { await _service.delete(widget.kind, widget.companyCode, '${r['id']}'); await _load(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); } }
  @override Widget build(BuildContext context) => CommercialPageFrame(title: widget.title, child: _busy ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _refreshFromServer, child: ListView(padding: const EdgeInsets.all(14), children: _rows.map((r) { final title = widget.kind == 'transfers' ? 'تحويل ${r['serial']} · ${r['from_branch_code']}/${r['from_store_code']} ← ${r['to_branch_code']}/${r['to_store_code']}' : 'إذن ${r['serial']} · ${r['customer_name'] ?? ''}'; final amount = _n(r['total'] ?? r['amount'] ?? ((r['items'] is List) ? (r['items'] as List).whereType<Map>().fold<double>(0, (sum, item) => sum + _n(item['quantity']) * _n(item['price'])) : 0)); return Card(child: ListTile(title: Text(title), subtitle: Text('${r['date']} · ${_money(amount)}${r['sync_status'] == 'pending' ? ' · بانتظار المزامنة' : ''}${r['sync_status'] == 'error' ? ' · تعذرت المزامنة' : ''}${r['sync_status'] == 'conflict' ? ' · تغيّر على جهاز آخر؛ حدّث القائمة' : ''}'), trailing: Wrap(children: [if (widget.kind == 'customer-payments' && PermissionsService().hasPermission(_category, 'تعديل تحصيل')) IconButton(icon: const Icon(Icons.edit), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPaymentsPage(companyCode: widget.companyCode, branchCode: widget.branchCode, editItem: r))).then((_) => _load())), if (widget.kind == 'returns' && PermissionsService().canEditSaleReturn) IconButton(icon: const Icon(Icons.edit), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SaleReturnPage(companyCode: widget.companyCode, selectedBranchCode: widget.branchCode, editItem: r))).then((_) => _load())), if (widget.kind == 'transfers' && PermissionsService().canEditStockTransfer) IconButton(icon: const Icon(Icons.edit), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StockTransfersPage(companyCode: widget.companyCode, branchCode: widget.branchCode, editItem: r))).then((_) => _load())), if (PermissionsService().hasPermission(_category, widget.kind == 'customer-payments' ? 'حذف تحصيل' : 'حذف')) IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r))]))); }).toList())));
}

class CustomerBalancesPage extends StatefulWidget { final String companyCode; final String? branchCode; const CustomerBalancesPage({super.key, required this.companyCode, this.branchCode}); @override State<CustomerBalancesPage> createState() => _CustomerBalancesPageState(); }
class _CustomerBalancesPageState extends State<CustomerBalancesPage> {
  final _service = CommercialService(); List<JMap> _rows = []; bool _busy = true;
  final List<StreamSubscription<BoxEvent>> _subscriptions = [];
  @override void initState() { super.initState(); for (final name in ['sales_box', 'sales_returns_box', 'customer_payments_box']) { _subscriptions.add(Hive.box(name).watch().listen((_) => _load())); } _load(); }
  @override void dispose() { for (final subscription in _subscriptions) { subscription.cancel(); } super.dispose(); }
  Future<void> _load() async { try { final balances = await _service.customerBalances(widget.companyCode, branchCode: widget.branchCode); _rows = balances.map((r) => {'code': r['customer_code'], 'name': r['customer_name'], 'balance': _n(r['balance'])}).toList(); } catch (_) {} if (mounted) setState(() => _busy = false); }
  Future<void> _refreshFromServer() async { await _service.customerBalances(widget.companyCode, branchCode: widget.branchCode, forceRefresh: true); await _load(); }
  @override Widget build(BuildContext context) => CommercialPageFrame(title: 'أرصدة العملاء', child: _busy ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _refreshFromServer, child: ListView(padding: const EdgeInsets.all(14), children: _rows.map<Widget>((r) => Card(
  child: ListTile(
    title: Text('${r['name']}'),
    subtitle: Text('كود ${r['code']}'),
    trailing: Text(
      _money(_n(r['balance'])),
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
  ),
)).toList(),)));
}

class SalesTreasuryBalancesPage extends StatefulWidget { final String companyCode; final String? branchCode; const SalesTreasuryBalancesPage({super.key, required this.companyCode, this.branchCode}); @override State<SalesTreasuryBalancesPage> createState() => _SalesTreasuryBalancesPageState(); }
class _SalesTreasuryBalancesPageState extends State<SalesTreasuryBalancesPage> {
  final _service = CommercialService(); Map<String, double> _balances = {}; bool _busy = true;
  final List<StreamSubscription<BoxEvent>> _subscriptions = [];
  @override void initState() { super.initState(); for (final name in ['sales_box', 'sales_returns_box', 'customer_payments_box']) { _subscriptions.add(Hive.box(name).watch().listen((_) => _load())); } _load(); }
  @override void dispose() { for (final subscription in _subscriptions) { subscription.cancel(); } super.dispose(); }
  Future<void> _load() async { try { _balances = await _service.treasuryBalances(widget.companyCode, branchCode: widget.branchCode); } catch (_) {} if (mounted) setState(() => _busy = false); }
  Future<void> _refreshFromServer() async { await _service.treasuryBalances(widget.companyCode, branchCode: widget.branchCode, forceRefresh: true); await _load(); }
  @override Widget build(BuildContext context) => CommercialPageFrame(title: 'أرصدة خزائن المبيعات', child: _busy ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _refreshFromServer, child: ListView(padding: const EdgeInsets.all(14), children: _balances.entries.map<Widget>((e) => Card(child: ListTile(leading: const Icon(Icons.account_balance_wallet), title: Text(e.key), trailing: Text(_money(e.value), style: const TextStyle(fontWeight: FontWeight.bold))))).toList())));
}

class SalesDashboardPage extends StatelessWidget {
  final String companyCode; final String? branchCode; final String? userName;
  const SalesDashboardPage({super.key, required this.companyCode, this.branchCode, this.userName});
  @override Widget build(BuildContext context) {
    final p = PermissionsService();
    final pages = <(String, String, IconData, Widget)>[];
    if (p.canAddSale) pages.add(('فاتورة مبيعات', 'بيع الأصناف وتسجيل الدفع أو الآجل', Icons.point_of_sale, SalesPage(companyCode: companyCode, selectedBranchCode: branchCode, userName: userName)));
    if (p.canViewSales) pages.add(('معاينة المبيعات', 'البحث في الفواتير وتعديلها حسب الصلاحيات', Icons.receipt_long, SalesHistoryPage(companyCode: companyCode, branchCode: branchCode, userName: userName)));
    if (p.canAddSaleReturn) pages.add(('مرتجع مبيعات', 'إرجاع الأصناف وتسجيل رد قيمتها', Icons.assignment_return, SaleReturnPage(companyCode: companyCode, selectedBranchCode: branchCode, userName: userName)));
    if (p.canViewSaleReturns) pages.add(('معاينة المرتجعات', 'سجل المرتجعات السابقة', Icons.history, CommercialHistoryPage(companyCode: companyCode, kind: 'returns', title: 'معاينة المرتجعات', branchCode: branchCode)));
    if (p.canAddCustomerPayment) pages.add(('تحصيل من عميل', 'تسجيل دفعة تقلل رصيد العميل', Icons.price_check, CustomerPaymentsPage(companyCode: companyCode, branchCode: branchCode, userName: userName)));
    if (p.canViewCustomerPayments) pages.add(('معاينة تحصيلات العملاء', 'سجل التحصيلات وتعديلها أو حذفها حسب الصلاحيات', Icons.history, CommercialHistoryPage(companyCode: companyCode, kind: 'customer-payments', title: 'تحصيلات العملاء', branchCode: branchCode)));
    if (p.canViewCustomerBalances) pages.add(('أرصدة العملاء', 'متابعة المبالغ الآجلة والتحصيلات', Icons.people_alt, CustomerBalancesPage(companyCode: companyCode, branchCode: branchCode)));
    if (p.canViewSalesTreasuries) pages.add(('أرصدة خزائن المبيعات', 'أرصدة مستقلة عن اليومية الحالية', Icons.account_balance_wallet, SalesTreasuryBalancesPage(companyCode: companyCode, branchCode: branchCode)));
    return CommercialPageFrame(title: 'المبيعات والعملاء', child: ListView(padding: const EdgeInsets.all(16), children: pages.map((e) => Card(child: ListTile(leading: Icon(e.$3, color: AppTheme.accentFor(context)), title: Text(e.$1, style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)), subtitle: Text(e.$2, style: const TextStyle(fontFamily: 'Cairo')), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => e.$4))))).toList()));
  }
}
