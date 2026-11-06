import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/coding_service.dart';
import '../../models/coding_model.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/permissions_service.dart';

class CodingPage extends StatefulWidget {
  final String companyCode;
  const CodingPage({super.key, required this.companyCode});

  @override
  State<CodingPage> createState() => _CodingPageState();
}

class _CodingPageState extends State<CodingPage> with TickerProviderStateMixin {
  final CodingService _codingService = CodingService();

  bool _isLoading = false;
  bool _isEditMode = false;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _wholesalePriceController = TextEditingController();
  final TextEditingController _sellingPriceController = TextEditingController();
  final TextEditingController _profitMarginController = TextEditingController(text: "0.00");
  final TextEditingController _profitPercentController = TextEditingController(text: "0.00 %");


  String _selectedCategory = "items";
  String? _selectedType;

  @override
  void initState() {
    super.initState();
    _wholesalePriceController.addListener(_calculateProfit);
    _sellingPriceController.addListener(_calculateProfit);
    _loadNextCode();
  }

  void _calculateProfit() {
    double wholesale = double.tryParse(_wholesalePriceController.text) ?? 0.0;
    double selling = double.tryParse(_sellingPriceController.text) ?? 0.0;
    double margin = selling - wholesale;
    double percent = wholesale > 0 ? (margin / wholesale) * 100 : 0.0;

    if (mounted) {
      setState(() {
        _profitMarginController.text = margin.toStringAsFixed(2);
        _profitPercentController.text = "${percent.toStringAsFixed(1)} %";
      });
    }
  }

  Future<void> _loadNextCode() async {
    if (_isEditMode) return;

    try {
      final Box codingBox = Hive.box('coding_box');
      final String localKey = "${widget.companyCode}_$_selectedCategory";
      int maxCode = 0;

            List<CodingModel> items = [];

      if (codingBox.containsKey(localKey)) {
        final rawData = codingBox.get(localKey);
        if (rawData is List) {
          items = rawData
              .map((item) => CodingModel.fromMap(Map<String, dynamic>.from(item as Map)))
              .toList();
        }
      }

      if (items.isEmpty) {
        items = await _codingService.getCodingList(
          companyCode: widget.companyCode,
          category: _selectedCategory,
        );
      }

      for (var item in items) {
        int current = int.tryParse(item.code) ?? 0;
        if (current > maxCode) maxCode = current;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _codeController.text = "1";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    bool canView = PermissionsService().canViewCoding;
    bool canAdd = PermissionsService().canAddCodingItem;

    if (!canView && !canAdd) {
      return Scaffold(
        appBar: AppBar(
          title: Text("شاشة التكويد", style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textMainFor(context))),
          backgroundColor: AppTheme.appBarBg,
          elevation: 0,
        ),
        extendBodyBehindAppBar: true,
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: AppTheme.dashGradientMain(context),
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: Text(
              "ليس لديك صلاحية للوصول إلى التكويد",
              style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo', fontSize: 16),
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text("شاشة التكويد", style: TextStyle(fontFamily: 'Cairo', color: AppTheme.textMainFor(context))),
          backgroundColor: AppTheme.appBarBg,
          elevation: 0,
        ),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: AppTheme.dashGradientMain(context),
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: AppTheme.textMainFor(context)))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(15),
                    child: Column(
                      children: [
                        GlassCard(
                          child: Column(
                            children: [
                              Align(alignment: Alignment.centerRight, child: Text("اختر القسم", style: TextStyle(color: AppTheme.warningFor(context), fontSize: 14, fontFamily: 'Cairo'))),
                              const SizedBox(height: 15),
                              Wrap(
                                spacing: 8, runSpacing: 8, alignment: WrapAlignment.center,
                                children: [
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddSafe)
                                    _buildTinyCategory("safes", "الخزائن", Icons.account_balance_wallet),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddCodingItem)
                                    _buildTinyCategory("items", "الأصناف", Icons.inventory_2),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddSupplier)
                                    _buildTinyCategory("suppliers", "الموردين", Icons.local_shipping),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddCustomer)
                                    _buildTinyCategory("customers", "العملاء", Icons.groups),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddStore)
                                    _buildTinyCategory("stores", "المخازن", Icons.store),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddCodingItem)
                                    _buildTinyCategory("types", "التصنيف", Icons.payments),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddPaymentMethod)
                                    _buildTinyCategory("payment_methods", "طرق الدفع", Icons.credit_card),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddBank)
                                    _buildTinyCategory("banks", "البنوك", Icons.account_balance),
                                  if (PermissionsService().canViewCoding || PermissionsService().canAddBranch)
                                    _buildTinyCategory("branches", "الفروع", Icons.storefront),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (canAdd)
                          GlassCard(
                            child: Column(
                              children: [
                                _buildField("الاسم / البيان", _nameController, Icons.edit),
                                const SizedBox(height: 10),
                                _buildField("الكود", _codeController, Icons.qr_code, enabled: true),
                                if (_selectedCategory == "types") ...[
                                  const SizedBox(height: 10),
                                  DropdownButtonFormField<String>(
                                    initialValue: _selectedType,
                                    dropdownColor: AppTheme.dropdownBackground(context),
                                    style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 14, fontFamily: 'Cairo'),
                                    decoration: InputDecoration(
                                      labelText: "نوع التصنيف (وارد / صادر)",
                                      labelStyle: TextStyle(color: AppTheme.textSoftFor(context), fontSize: 12, fontFamily: 'Cairo'),
                                      prefixIcon: Icon(Icons.swap_horiz, color: AppTheme.warningFor(context), size: 18),
                                      filled: true, fillColor: GlassStyle.fill03For(context),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                    ),
                                    items: const [
                                      DropdownMenuItem(value: "وارد", child: Text("وارد", style: TextStyle(fontFamily: 'Cairo'))),
                                      DropdownMenuItem(value: "صادر", child: Text("صادر", style: TextStyle(fontFamily: 'Cairo'))),
                                    ],
                                    onChanged: (val) {
                                      setState(() {
                                        _selectedType = val;
                                      });
                                    },
                                  ),
                                ],
                                if (_selectedCategory == "items") ...[
                                  const SizedBox(height: 10),
                                  _buildField("الباركود", _barcodeController, Icons.barcode_reader),
                                  const SizedBox(height: 10),
                                  Row(children: [
                                    Expanded(child: _buildField("سعر الجملة", _wholesalePriceController, Icons.money)),
                                    const SizedBox(width: 10),
                                    Expanded(child: _buildField("سعر البيع", _sellingPriceController, Icons.sell)),
                                  ]),
                                  const SizedBox(height: 10),
                                  Row(children: [
                                    Expanded(child: _buildField("هامش الربح", _profitMarginController, Icons.calculate, enabled: false)),
                                    const SizedBox(width: 10),
                                    Expanded(child: _buildField("نسبة الربح", _profitPercentController, Icons.percent, enabled: false)),
                                  ]),
                                ],



                                const SizedBox(height: 20),
                                _buildActionButtons(),
                              ],
                            ),
                          ),
                        if (!canAdd)
                          Padding(
                            padding: EdgeInsets.all(20.0),
                            child: Text(
                              "ليس لديك صلاحية لإضافة أو تعديل التكويدات",
                              style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo', fontSize: 14),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildTinyCategory(String cat, String title, IconData icon) {
    bool isSelected = _selectedCategory == cat;
    return InkWell(
      onTap: () {
        if (_selectedCategory == cat && _isEditMode) return;
        setState(() {
          _selectedCategory = cat;
          _isEditMode = false;
          _clearControllers();
        });
        _loadNextCode();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.warningFor(context) : GlassStyle.fill05For(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? AppTheme.warningFor(context) : GlassStyle.line10For(context)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isSelected ? AppTheme.onAccentFor(context) : AppTheme.textSoftFor(context)),
            const SizedBox(width: 4),
            Text(title, style: TextStyle(color: isSelected ? AppTheme.onAccentFor(context) : AppTheme.textMainFor(context), fontSize: 11, fontFamily: 'Cairo')),
          ],
        ),
      ),
    );
  }

  Widget _buildField(String lbl, TextEditingController ctrl, IconData ico, {bool enabled = true}) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 14),
      decoration: InputDecoration(
        labelText: lbl,
        labelStyle: TextStyle(color: AppTheme.textSoftFor(context), fontSize: 12),
        prefixIcon: Icon(ico, color: AppTheme.warningFor(context), size: 18),
        filled: true,
        fillColor: GlassStyle.fill03For(context),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      ),
    );
  }

  Widget _buildActionButtons() {
    bool canAdd = PermissionsService().canAddCodingItem;
    bool canView = PermissionsService().canViewCoding;

    return Row(
      children: [
        if (canAdd)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _handleSave,
              icon: Icon(_isEditMode ? Icons.update : Icons.save, size: 18),
              label: Text(_isEditMode ? "تحديث" : "حفظ", style: const TextStyle(fontFamily: 'Cairo')),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.warningFor(context), foregroundColor: AppTheme.onAccentFor(context)),
            ),
          ),
        if (canView)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _showItemsModal,
              icon: const Icon(Icons.visibility, size: 18),
              label: const Text("معاينة", style: TextStyle(fontFamily: 'Cairo')),
              style: ElevatedButton.styleFrom(backgroundColor: GlassStyle.fill10For(context), foregroundColor: Theme.of(context).colorScheme.onPrimary),
            ),
          ),
        IconButton(
          onPressed: () {
            _clearControllers();
            _loadNextCode();
          },
          icon: Icon(Icons.refresh, color: AppTheme.textMutedFor(context)),
        ),
      ],
    );
  }

  void _handleSave() async {
    if (!PermissionsService().canAddCodingItem) {
      _showSnackBar("ليس لديك صلاحية للحفظ", AppTheme.warningOrangeFor(context));
      return;
    }

    if (_nameController.text.isEmpty) {
      _showSnackBar("الاسم مطلوب", AppTheme.warningOrangeFor(context));
      return;
    }
    if (_codeController.text.isEmpty) {
      _showSnackBar("الكود مطلوب", AppTheme.warningOrangeFor(context));
      return;
    }
    if (_selectedCategory == "types" && _selectedType == null) {
      _showSnackBar("يرجى اختيار نوع التصنيف (وارد/صادر)", AppTheme.warningOrangeFor(context));
      return;
    }

    setState(() => _isLoading = true);
    try {
            // ✅ حفظ تكويد عادي
      double cleanPercent = double.tryParse(
            _profitPercentController.text.replaceAll('%', '').trim(),
          ) ??
          0.0;

      final newCodingItem = CodingModel(
        code: _codeController.text,
        name: _nameController.text,
        type: _selectedType ?? "وارد",
        barcode: _barcodeController.text,
        wholesalePrice: double.tryParse(_wholesalePriceController.text) ?? 0.0,
        sellingPrice: double.tryParse(_sellingPriceController.text) ?? 0.0,
        profitMargin: double.tryParse(_profitMarginController.text) ?? 0.0,
        profitPercent: cleanPercent,
      );

      final result = await _codingService.saveCode(
        companyCode: widget.companyCode,
        category: _selectedCategory,
        model: newCodingItem,
      );

      if (result['success'] == true) {
        _showSnackBar(
          _isEditMode ? "تم التحديث بنجاح" : "تم الحفظ بنجاح",
          AppTheme.successStrongFor(context),
        );
        _clearControllers();
        _loadNextCode();
      } else {
        _showSnackBar(
          "فشل عملية الحفظ: ${result['error']}",
          AppTheme.dangerStrongFor(context),
        );
      }
    } catch (e) {
      _showSnackBar("خطأ: $e", AppTheme.dangerStrongFor(context));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showItemsModal() async {
    if (!PermissionsService().canViewCoding) {
      _showSnackBar("ليس لديك صلاحية للمعاينة", AppTheme.warningOrangeFor(context));
      return;
    }

    setState(() => _isLoading = true);
    try {
            // ✅ معاينة التكويد
      List<CodingModel> items = await _codingService.getCodingList(
        companyCode: widget.companyCode,
        category: _selectedCategory,
      );
      setState(() => _isLoading = false);
      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppTheme.sheetBgTransparent,
        builder: (ctx) => _buildModal(items),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar("حدث خطأ أثناء المعاينة", AppTheme.dangerStrongFor(context));
    }
  }

  Widget _buildModal(List<CodingModel> initialItems) {
    return StatefulBuilder(
      builder: (BuildContext context, StateSetter setModalState) {
        bool canAdd = PermissionsService().canAddCodingItem;

        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: BoxDecoration(
            color: AppTheme.modalPanelFor(context),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: initialItems.isEmpty
              ? Center(
                  child: Text(
                    "القسم فارغ حالياً",
                    style: TextStyle(
                      color: AppTheme.textSoftFor(context),
                      fontFamily: 'Cairo',
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: initialItems.length,
                  itemBuilder: (c, i) => Material(
                    color: Colors.transparent,
                    child: ListTile(
                      title: Text(
                        initialItems[i].name,
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Text(
                            "كود: ${initialItems[i].code}",
                            style: TextStyle(
                              color: AppTheme.textMutedFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 12,
                            ),
                          ),
                          if (_selectedCategory == "types") ...[
                            const SizedBox(width: 15),
                            Text(
                              "النوع: ${initialItems[i].type}",
                              style: TextStyle(
                                color: initialItems[i].type == "وارد"
                                    ? AppTheme.successFor(context)
                                    : AppTheme.dangerFor(context),
                                fontFamily: 'Cairo',
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ],
                      ),
                      trailing: canAdd
                          ? IconButton(
                              icon: Icon(
                                Icons.delete,
                                color: AppTheme.dangerStrongFor(context),
                              ),
                              onPressed: () async {
                                setState(() => _isLoading = true);
                                bool isDeleted =
                                    await _codingService.deleteCode(
                                  companyCode: widget.companyCode,
                                  category: _selectedCategory,
                                  code: initialItems[i].code,
                                );
                                setState(() => _isLoading = false);
                                if (isDeleted) {
                                  _showSnackBar(
                                    "تم الحذف بنجاح",
                                    AppTheme.successStrongFor(context),
                                  );
                                  setModalState(() {
                                    initialItems.removeAt(i);
                                  });
                                  _loadNextCode();
                                } else {
                                  _showSnackBar(
                                    "فشل الحذف، تحقق من الاتصال",
                                    AppTheme.dangerStrongFor(context),
                                  );
                                }
                              },
                            )
                          : null,
                      onTap: () {
                        if (!canAdd) return;
                        Navigator.pop(context);
                        setState(() {
                          _isEditMode = true;
                          _nameController.text = initialItems[i].name;
                          _codeController.text = initialItems[i].code;
                          if (_selectedCategory == "types") {
                            _selectedType = initialItems[i].type;
                          }
                          if (_selectedCategory == "items") {
                            _barcodeController.text = initialItems[i].barcode;
                            _wholesalePriceController.text =
                                initialItems[i].wholesalePrice.toString();
                            _sellingPriceController.text =
                                initialItems[i].sellingPrice.toString();
                            _profitMarginController.text =
                                initialItems[i].profitMargin.toString();
                            _profitPercentController.text =
                                "${initialItems[i].profitPercent} %";
                          }
                        });
                      },
                    ),
                  ),
                ),
        );
      },
    );
  }



  void _clearControllers() {
    _nameController.clear();
    _codeController.clear();
    _barcodeController.clear();
    _wholesalePriceController.clear();
    _sellingPriceController.clear();
    _profitMarginController.text = "0.00";
    _profitPercentController.text = "0.00 %";
    _selectedType = null;
    _isEditMode = false;


  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m, textAlign: TextAlign.center), backgroundColor: c),
      );

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _barcodeController.dispose();
    _wholesalePriceController.dispose();
    _sellingPriceController.dispose();
    _profitMarginController.dispose();
    _profitPercentController.dispose();



    super.dispose();
  }
}