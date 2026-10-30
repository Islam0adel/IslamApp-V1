
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme.dart';
import '../../services/product_lookup_service.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';

class ProductLookupPage extends StatefulWidget {
  const ProductLookupPage({super.key});

  @override
  State<ProductLookupPage> createState() => _ProductLookupPageState();
}

class _ProductLookupPageState extends State<ProductLookupPage> {
  final _controller = TextEditingController();
  final _service = ProductLookupService();
  Map<String, dynamic>? _result;
  bool _loading = false;
  String? _error;
  bool _nameSearch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search({bool refresh = false}) async {
    FocusScope.of(context).unfocus();
    final input = _controller.text.trim();

    if (input.isEmpty) {
      setState(() {
        _error = 'اكتب باركود المنتج أو اسمه أولًا';
        _result = null;
      });
      return;
    }

    final isBarcode = RegExp(r'^\d{8,14}$').hasMatch(input);

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _nameSearch = !isBarcode;
    });

    try {
      final result = isBarcode
          ? await _service.lookup(input, forceRefresh: refresh)
          : await _service.searchByName(input, forceRefresh: refresh);

      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _text(dynamic value, [String fallback = 'غير متاح']) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty || text == 'null' ? fallback : text;
  }

  String _money(dynamic value) {
    if (value is! num || value <= 0) return 'السعر غير متاح';
    return '${value.toStringAsFixed(value % 1 == 0 ? 0 : 2)} جنيه';
  }

  String _priceLabel(Map<String, dynamic>? price) {
    if (price == null) return 'لم نعثر على سعر موثوق لهذا الباركود';

    final type = price['type']?.toString();
    final amount = price['amount'];
    final min = price['min'];
    final max = price['max'];

    String format(dynamic value) => value is num
        ? value.toStringAsFixed(value % 1 == 0 ? 0 : 2)
        : value.toString();

    if (type == 'estimated' && min is num && max is num) {
      return 'من ${format(min)} إلى ${format(max)} جنيه (تقديري)';
    }

    if (amount == null) {
      return 'لم نعثر على سعر موثوق لهذا الباركود';
    }

    return '${format(amount)} جنيه ${type == 'unconfirmed' ? '(سعر منشور غير مؤكد)' : ''}';
  }

  String _date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return 'غير متاح';

    return '${parsed.year.toString().padLeft(4, '0')}-'
        '${parsed.month.toString().padLeft(2, '0')}-'
        '${parsed.day.toString().padLeft(2, '0')}';
  }

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 145,
              child: Text(
                label,
                style: TextStyle(
                  color: AppTheme.textSoftFor(context),
                  fontSize: 13,
                ),
              ),
            ),
            Expanded(
              child: Text(value, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );

  Future<void> _copyProductUrl(String url) async {
    if (url.isEmpty || url == 'غير متاح') return;

    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم نسخ رابط المنتج')),
    );
  }

  Widget _nameResults() {
    final results = _result?['results'];
    final items = results is List
        ? results
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];

    final range = _result?['price_range'];
    final rangeMap = range is Map ? Map<String, dynamic>.from(range) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'نتائج البحث بالاسم',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('بحث عن: ${_text(_result?['query'], _controller.text)}'),
              if (rangeMap != null &&
                  rangeMap['min'] is num &&
                  rangeMap['max'] is num) ...[
                const SizedBox(height: 8),
                Text(
                  'نطاق الأسعار المنشورة: ${_money(rangeMap['min'])} إلى ${_money(rangeMap['max'])}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
              if (items.isEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _text(
                    _result?['message'],
                    'لم نعثر على نتائج متاحة حاليًا',
                  ),
                  style: TextStyle(color: AppTheme.textSoftFor(context)),
                ),
                const SizedBox(height: 10),
                const Text(
                  'يمكنك فتح البحث مباشرة في المتاجر:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                if (_result?['store_search_urls'] is Map) ...[
                  SelectableText(
                    'أمازون: ${(_result!['store_search_urls'] as Map)['amazon'] ?? ''}',
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    'كارفور: ${(_result!['store_search_urls'] as Map)['carrefour'] ?? ''}',
                  ),
                ],
              ],
            ],
          ),
        ),
        for (final item in items) ...[
          const SizedBox(height: 10),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.shopping_bag_outlined),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _text(item['title'], 'منتج بدون اسم'),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _detail('المتجر', _text(item['store'])),
                _detail('السعر', _money(item['price'])),
                if (item['price'] is num)
                  _detail(
                    'نوع السعر',
                    'سعر منشور على صفحة المتجر، وقد يتغير حسب التوافر',
                  ),
                const SizedBox(height: 4),
                SelectableText(
                  _text(item['url'], 'رابط المنتج غير متاح'),
                  style: TextStyle(
                    color: AppTheme.textSoftFor(context),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => _copyProductUrl(
                    item['url']?.toString() ?? '',
                  ),
                  icon: const Icon(Icons.copy),
                  label: const Text('نسخ رابط المنتج'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'الأسعار المعروضة مأخوذة من النتائج المتاحة وقت البحث، وقد تختلف حسب الفرع أو البائع أو التوصيل. تشابه الاسم لا يضمن تطابق الحجم أو العبوة.',
          style: TextStyle(
            color: AppTheme.textSoftFor(context),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _loading ? null : () => _search(refresh: true),
          icon: const Icon(Icons.refresh),
          label: const Text('إعادة البحث'),
        ),
      ],
    );
  }

  @override
Widget build(BuildContext context) {
  // ============================================================
  // حماية بالصلاحية الجديدة
  // ============================================================
  if (!PermissionsService().canShowProductLookup) {
    return Scaffold(
      appBar: AppBar(title: const Text('البحث عن المنتجات')),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 54,
                color: AppTheme.textMutedFor(context),
              ),
              const SizedBox(height: 12),
              Text(
                'غير مصرح بالوصول لهذه الصفحة',
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // المحتوى الطبيعي
  // ============================================================
  final product = _result?['product'] is Map
      ? Map<String, dynamic>.from(_result!['product'])
      : null;
  final price = _result?['price'] is Map
      ? Map<String, dynamic>.from(_result!['price'])
      : null;
  final found = _result?['found'] == true;
  final valid = _result?['barcode_format_valid'] == true;

  return Scaffold(
    appBar: AppBar(title: const Text('البحث عن المنتجات')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'ابحث بالباركود أو اسم المنتج',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _controller,
                  keyboardType: TextInputType.text,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(
                    hintText: 'باركود أو مثال: زيت عباد الشمس 1.5 لتر',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _search(),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _loading ? null : () => _search(),
                  icon: const Icon(Icons.search),
                  label: const Text('بحث'),
                ),
                if (_loading) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text(
                    'جارٍ البحث في مصادر المنتجات...',
                    textAlign: TextAlign.center,
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: AppTheme.dangerFor(context)),
                    ),
                  ),
              ],
            ),
          ),
          if (_result != null && _nameSearch) ...[
            const SizedBox(height: 14),
            _nameResults(),
          ],
          if (_result != null && !_nameSearch) ...[
            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        found
                            ? Icons.inventory_2_outlined
                            : Icons.search_off_rounded,
                        color: found
                            ? AppTheme.successFor(context)
                            : AppTheme.warningFor(context),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          found
                              ? _text(
                                  product?['name'],
                                  'اسم المنتج غير متاح',
                                )
                              : 'لم يتم العثور على سجل لهذا الباركود',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _detail('الباركود', _text(_result!['barcode'])),
                  _detail(
                    'فحص الصيغة',
                    valid
                        ? 'اجتاز فحص رقم التحقق الحسابي'
                        : 'لم يجتز فحص رقم التحقق أو نوع الكود غير مدعوم',
                  ),
                  if (found) ...[
                    _detail('الماركة', _text(product?['brand'])),
                    _detail('الوزن / الحجم', _text(product?['quantity'])),
                    _detail('التصنيف', _text(product?['category'])),
                    _detail(
                      'الشركة المصنعة',
                      _text(product?['manufacturer']),
                    ),
                    _detail(
                      'بلد المنشأ',
                      _text(product?['origin_country']),
                    ),
                    _detail(
                      'مصدر بيانات المنتج',
                      _text(product?['source']),
                    ),
                    _detail(
                      'آخر تحديث للبيانات',
                      _date(product?['updated_at']),
                    ),
                  ],
                  const Divider(height: 26),
                  const Text(
                    'السعر في مصر',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _priceLabel(price),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (price != null) ...[
                    _detail('وحدة السعر', _text(price['unit'], 'القطعة')),
                    _detail('مصدر السعر', _text(price['source'])),
                    _detail(
                      'تاريخ رصد السعر',
                      _date(price['observed_at']),
                    ),
                    _detail(
                      'آخر تحديث فعلي للسعر',
                      _date(price['updated_at']),
                    ),
                    _detail(
                      'آخر محاولة فحص للسعر',
                      _date(price['checked_at']),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'صحة صيغة الباركود لا تثبت وحدها تسجيله رسميًا أو صحة بيانات المنتج. السعر غير المتاح لا يتم تخمينه دون مصدر مناسب.',
                    style: TextStyle(
                      color: AppTheme.textSoftFor(context),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _loading
                        ? null
                        : () => _search(refresh: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('تحديث البيانات والسعر'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
}
