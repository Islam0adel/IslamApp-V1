import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';

typedef JMap = Map<String, dynamic>;

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull { final iterator = this.iterator; return iterator.moveNext() ? iterator.current : null; }
}

double n(dynamic x) => x is num ? x.toDouble() : double.tryParse(x?.toString() ?? '') ?? 0;
String money(num x) => NumberFormat('#,##0.##', 'en').format(x);
String plain(num x) => x.isFinite && x == x.roundToDouble() ? x.toInt().toString() : x.toString();

List<JMap> catalog(String company, String category) {
  final raw = Hive.box('coding_box').get('${company}_$category', defaultValue: []);
  if (raw is! List) return [];
  return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).where((e) => e['is_deleted'] != true).toList();
}

List<JMap> storesForBranch(String company, String? branchCode) =>
    catalog(company, 'stores').where((store) {
      final assigned = store['branch_code']?.toString() ?? '';
      return assigned.isEmpty || assigned == branchCode;
    }).toList();

String nameOf(List<JMap> data, String code) => data.firstWhere((e) => '${e['code']}' == code, orElse: () => {'name': code})['name']?.toString() ?? code;

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


class SaleLine {
  JMap product;
  final TextEditingController code;
  final TextEditingController name;
  final TextEditingController qty;
  final TextEditingController price;
  final FocusNode codeFocus = FocusNode();
  final FocusNode nameFocus = FocusNode();
  final FocusNode qtyFocus = FocusNode();
  final FocusNode priceFocus = FocusNode();
  SaleLine(this.product, double quantity, double unitPrice)
      : code = TextEditingController(text: '${product['code'] ?? ''}'),
        name = TextEditingController(text: '${product['name'] ?? ''}'),
        qty = TextEditingController(text: quantity == 0 ? '' : plain(quantity)),
        price = TextEditingController(text: (unitPrice == 0 && product.isEmpty) ? '' : plain(unitPrice)) {
    // عند الدخول على الكمية/السعر يُحدَّد النص كله ليُستبدل مباشرة بما يُكتب.
    void selectAllOnFocus(FocusNode node, TextEditingController c) => node.addListener(() {
      if (node.hasFocus) c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    });
    selectAllOnFocus(qtyFocus, qty);
    selectAllOnFocus(priceFocus, price);
  }
  double get amount => n(qty.text) * n(price.text);
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

class ReturnLine {
  JMap? product;
  final TextEditingController code;
  final TextEditingController name;
  final TextEditingController qty;
  final FocusNode nameFocus = FocusNode();
  final FocusNode qtyFocus = FocusNode();

  ReturnLine({this.product, double quantity = 0})
      : code = TextEditingController(text: '${product?['code'] ?? ''}'),
        name = TextEditingController(text: '${product?['name'] ?? ''}'),
        qty = TextEditingController(text: quantity == 0 ? '' : '$quantity');

  double get amount => n(qty.text) * n(product?['price']);

  void dispose() {
    code.dispose();
    name.dispose();
    qty.dispose();
    nameFocus.dispose();
    qtyFocus.dispose();
  }
}

class PayLine {
  String method;
  String treasury;
  final TextEditingController amount;
  PayLine({this.method = '', this.treasury = '', double value = 0}) : amount = TextEditingController(text: value == 0 ? '' : '$value');
  void dispose() => amount.dispose();
}
