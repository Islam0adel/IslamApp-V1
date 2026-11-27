// frontend/lib/views/dashboard/commercial/commercial_shared.dart
import '../../../services/cache_partitions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';

// نوع مختصر للخريطة النصية
typedef JMap = Map<String, dynamic>;

// امتداد يعيد أول عنصر أو null
extension FirstOrNull<T> on Iterable<T> {
  // يعيد أول عنصر في المجموعة أو null
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

// يحوّل القيمة إلى رقم عشري بأمان
double n(dynamic x) =>
    x is num ? x.toDouble() : double.tryParse(x?.toString() ?? '') ?? 0;

// ينسّق المبلغ بخانتين عشريتين كحد أقصى
String money(num x) => NumberFormat('#,##0.##', 'en').format(x);

// ينسّق الرقم بدون كسور إذا كان صحيحًا
String plain(num x) =>
    x.isFinite && x == x.roundToDouble() ? x.toInt().toString() : x.toString();

// يعيد عناصر فئة من الكتالوج المحلي للشركة
List<JMap> catalog(String company, String category) {
  final raw = CachePartitions.box('coding_box')
      .get('${company}_$category', defaultValue: []);
  if (raw is! List) return [];
  return raw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .where((e) => e['is_deleted'] != true)
      .toList();
}

// يعيد المخازن المتاحة للفرع
List<JMap> storesForBranch(String company, String? branchCode) =>
    catalog(company, 'stores').where((store) {
      final assigned = store['branch_code']?.toString() ?? '';
      return assigned.isEmpty || assigned == branchCode;
    }).toList();

// يعيد اسم العنصر من كوده
String nameOf(List<JMap> data, String code) =>
    data
        .firstWhere((e) => '${e['code']}' == code,
            orElse: () => {'name': code})['name']
        ?.toString() ??
    code;

// إطار صفحة الشاشات التجارية
class CommercialPageFrame extends StatelessWidget {
  final String title;
  final Widget child;
  final bool dashboard;
  const CommercialPageFrame(
      {super.key,
      required this.title,
      required this.child,
      this.dashboard = false});

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) => Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
            title: Text(title,
                style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.bold)),
            centerTitle: true,
            backgroundColor: AppTheme.appBarBg,
            elevation: 0),
        body: Container(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: dashboard
                        ? AppTheme.dashGradientDeep(context)
                        : AppTheme.dashGradientMain(context),
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight)),
            child: SafeArea(child: child)),
      );
}

// سطر صنف في فاتورة بيع
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

  // ينشئ سطر بيع بصنف وكمية وسعر
  SaleLine(this.product, double quantity, double unitPrice)
      : code = TextEditingController(text: '${product['code'] ?? ''}'),
        name = TextEditingController(text: '${product['name'] ?? ''}'),
        qty = TextEditingController(text: quantity == 0 ? '' : plain(quantity)),
        price = TextEditingController(
            text: (unitPrice == 0 && product.isEmpty) ? '' : plain(unitPrice)) {
    // عند الدخول على الكمية/السعر يُحدَّد النص كله ليُستبدل مباشرة بما يُكتب.
    void selectAllOnFocus(FocusNode node, TextEditingController c) =>
        node.addListener(() {
          if (node.hasFocus)
            c.selection =
                TextSelection(baseOffset: 0, extentOffset: c.text.length);
        });
    selectAllOnFocus(qtyFocus, qty);
    selectAllOnFocus(priceFocus, price);
  }

  // يحسب مبلغ السطر
  double get amount => n(qty.text) * n(price.text);

  // يحدد هل السطر فارغ
  bool get isEmpty => code.text.trim().isEmpty && name.text.trim().isEmpty;

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
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

// سطر صنف في مرتجع بيع
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

  // يحسب مبلغ سطر المرتجع
  double get amount => n(qty.text) * n(product?['price']);

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  void dispose() {
    code.dispose();
    name.dispose();
    qty.dispose();
    nameFocus.dispose();
    qtyFocus.dispose();
  }
}

// سطر دفع في فاتورة بيع
class PayLine {
  String method;
  String treasury;
  final TextEditingController amount;
  PayLine({this.method = '', this.treasury = '', double value = 0})
      : amount = TextEditingController(text: value == 0 ? '' : '$value');

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  void dispose() => amount.dispose();
}

// فهرس بحث محلي للأصناف
/// فهرس بحث محلي للأصناف: يُبنى مرة عند تحميل الكتالوج أو تغيّره بدل تجهيز
/// نصوص البحث مع كل ضغطة زر. يحافظ على ترتيب القائمة الأصلي وتكراراتها،
/// وأول تطابق في الفهارس هو أول عنصر مطابق في الترتيب الأصلي.
class ProductIndex {
  final List<JMap> products;
  final bool searchBarcode;
  late final List<String> _haystacks = [
    for (final p in products)
      searchBarcode
          ? '${p['code']} ${p['name']} ${p['barcode']}'.toLowerCase()
          : '${p['code']} ${p['name']}'.toLowerCase()
  ];
  late final Map<String, JMap> _byCode = {};
  late final Map<String, JMap> _byCodeOrBarcode = {};

  // ينشئ الفهرس من قائمة الأصناف
  ProductIndex(this.products, {this.searchBarcode = true}) {
    for (final p in products) {
      final code = p['code']?.toString();
      if (code != null) {
        _byCode.putIfAbsent(code, () => p);
        _byCodeOrBarcode.putIfAbsent(code, () => p);
      }
      final barcode = p['barcode']?.toString();
      if (barcode != null && barcode.isNotEmpty) {
        _byCodeOrBarcode.putIfAbsent(barcode, () => p);
      }
    }
  }

  // يبحث في الأصناف بالنص ويعيد النتائج مرتبة
  /// نفس نتائج وترتيب optionsBuilder الأصلي، مع نصوص بحث مجهزة مسبقًا.
  Iterable<JMap> search(String query,
      {int? limit = 30,
      bool trimQuery = true,
      bool emptyReturnsAll = false}) sync* {
    final q = trimQuery ? query.trim().toLowerCase() : query.toLowerCase();
    if (q.isEmpty && !emptyReturnsAll) return;
    var taken = 0;
    for (var i = 0; i < products.length; i++) {
      if (limit != null && taken >= limit) break;
      if (_haystacks[i].contains(q)) {
        yield products[i];
        taken++;
      }
    }
  }

  // يعيد الصنف بكوده
  JMap? byCode(String code) => _byCode[code];

  // يعيد الصنف بكوده أو باركوده
  JMap? byCodeOrBarcode(String value) => _byCodeOrBarcode[value];
}
