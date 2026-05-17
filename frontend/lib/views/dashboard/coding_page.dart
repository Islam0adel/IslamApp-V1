import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';

class CodingPage extends StatefulWidget {
  final String companyCode;
  const CodingPage({super.key, required this.companyCode});

  @override
  State<CodingPage> createState() => _CodingPageState();
}

class _CodingPageState extends State<CodingPage> with TickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  bool _isLoading = false;
  bool _isEditMode = false;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _wholesalePriceController = TextEditingController(); // سعر الجملة
  final TextEditingController _sellingPriceController = TextEditingController();   // سعر البيع
  final TextEditingController _profitMarginController = TextEditingController(text: "0.00"); // هامش الربح
  final TextEditingController _profitPercentController = TextEditingController(text: "0.00 %"); // نسبة الربح

  // تعديل: الآن الكود قابل للتعديل عادي لو اخترنا الأصناف (items)، ويكون مقفول (ReadOnly) في باقي الأقسام
  bool get _isCodeReadOnly => _selectedCategory != "items";

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
    
    double margin = selling - wholesale; // هامش الربح
    double percent = wholesale > 0 ? (margin / wholesale) * 100 : 0.0; // نسبة الربح بالنسبة لسعر الجملة

    if (mounted) {
      setState(() {
        _profitMarginController.text = margin.toStringAsFixed(2);
        _profitPercentController.text = "${percent.toStringAsFixed(1)} %";
      });
    }
  }

  // جلب الكود التالي أوتوماتيكياً
  void _loadNextCode() async {
    if (_isEditMode) return; // 👈 السطر ده مهم جداً: لو في وضع التعديل ميتعبش كود جديد فوق الكود المستدعى
    try {
      final data = await _apiService.getCodingData(widget.companyCode, _selectedCategory);
      int maxCode = 0;
      for (var item in data) {
        int current = int.tryParse(item['code'].toString()) ?? 0;
        if (current > maxCode) maxCode = current;
      }
      setState(() => _codeController.text = (maxCode + 1).toString());
    } catch (e) {
      setState(() => _codeController.text = "1");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("شاشة التكويد", style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Colors.indigo.shade900, Colors.black],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading 
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(15),
                child: Column(
                  children: [
                    GlassCard(
                      child: Column(
                        children: [
                          const Align(alignment: Alignment.centerRight, child: Text("اختر القسم", style: TextStyle(color: Colors.amber, fontSize: 14, fontFamily: 'Cairo'))),
                          const SizedBox(height: 15),
                          Wrap(
                            spacing: 8, runSpacing: 8, alignment: WrapAlignment.center,
                            children: [
                              _buildTinyCategory("safes", "الخزائن", Icons.account_balance_wallet),
                              _buildTinyCategory("items", "الأصناف", Icons.inventory_2),
                              _buildTinyCategory("suppliers", "الموردين", Icons.local_shipping),
                              _buildTinyCategory("customers", "العملاء", Icons.groups),
                              _buildTinyCategory("stores", "المخازن", Icons.store),
                              _buildTinyCategory("types", "التصنيف", Icons.payments),
                              _buildTinyCategory("payment_methods", "طرق الدفع", Icons.credit_card), // تعديل الاسم
                              _buildTinyCategory("banks", "البنوك", Icons.account_balance),
                              _buildTinyCategory("employees", "الموظفين", Icons.badge), // تعديل الاسم
                              _buildTinyCategory("branches", "الفروع", Icons.storefront), // إضافة الفروع الجديدة
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    GlassCard(
                      child: Column(
                        children: [
                          _buildField("الاسم / البيان", _nameController, Icons.edit),
                          const SizedBox(height: 10),
                          _buildField("الكود", _codeController, Icons.qr_code, enabled: !_isCodeReadOnly), // قفل الكود حسب القسم
                          
                          if (_selectedCategory == "types") ...[
                            const SizedBox(height: 10),
                            DropdownButtonFormField<String>(
                              value: _selectedType,
                              dropdownColor: Colors.indigo.shade900,
                              style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'Cairo'),
                              decoration: InputDecoration(
                                labelText: "نوع التصنيف (وارد / صادر)",
                                labelStyle: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'Cairo'),
                                prefixIcon: const Icon(Icons.swap_horiz, color: Colors.amber, size: 18),
                                filled: true, fillColor: Colors.white.withOpacity(0.03),
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
                  ],
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
        // حماية: لو المستخدم ضغط على نفس القسم وهو في وضع التعديل، نمنع تصفير البيانات عشان متتمسحش
        if (_selectedCategory == cat && _isEditMode) return;

        setState(() {
          _selectedCategory = cat;
          _isEditMode = false;
          _clearControllers(); // تصفير الحقول فقط عند التنقل الفعلي بين الأقسام
        });
        _loadNextCode(); // حساب الكود التالي تلقائياً للقسم المختار
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.amber : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? Colors.amber : Colors.white10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isSelected ? Colors.black : Colors.white70),
            const SizedBox(width: 4),
            Text(title, style: TextStyle(color: isSelected ? Colors.black : Colors.white, fontSize: 11, fontFamily: 'Cairo')),
          ],
        ),
      ),
    );
  }

  Widget _buildField(String lbl, TextEditingController ctrl, IconData ico, {bool enabled = true}) {
    return TextField(
      controller: ctrl, enabled: enabled,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: lbl, labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
        prefixIcon: Icon(ico, color: Colors.amber, size: 18),
        filled: true, fillColor: Colors.white.withOpacity(0.03),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(child: ElevatedButton.icon(
          onPressed: _handleSave, icon: Icon(_isEditMode ? Icons.update : Icons.save, size: 18),
          label: Text(_isEditMode ? "تحديث" : "حفظ", style: const TextStyle(fontFamily: 'Cairo')),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
        )),
        const SizedBox(width: 8),
        Expanded(child: ElevatedButton.icon(
          onPressed: _showItemsModal, icon: const Icon(Icons.visibility, size: 18),
          label: const Text("معاينة", style: TextStyle(fontFamily: 'Cairo')),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
        )),
        IconButton(onPressed: () { _clearControllers(); _loadNextCode(); }, icon: const Icon(Icons.refresh, color: Colors.white60)),
      ],
    );
  }

  // --- المنطق البرمجي (نفس كودك الأصلي) ---

  void _handleSave() async {
    if (_nameController.text.isEmpty || _codeController.text.isEmpty) {
      _showSnackBar("الاسم والكود مطلوبين", Colors.orange); return;
    }

    // التحقق من اختيار نوع التصنيف (وارد / صادر) لو واقفين في قسم التصنيفات المالية
    if (_selectedCategory == "types" && _selectedType == null) {
      _showSnackBar("يرجى اختيار نوع التصنيف (وارد/صادر)", Colors.orange);
      return;
    }

    setState(() => _isLoading = true);
    try {
      // تنظيف النسبة المئوية من علامة % والمسافات قبل الإرسال
      double cleanPercent = double.tryParse(_profitPercentController.text.replaceAll('%', '').trim()) ?? 0.0;

      await _apiService.saveNewCode(
        companyCode: widget.companyCode, 
        category: _selectedCategory,
        code: _codeController.text, 
        name: _nameController.text,
        barcode: _barcodeController.text, 
        wholesalePrice: double.tryParse(_wholesalePriceController.text) ?? 0.0,
        sellingPrice: double.tryParse(_sellingPriceController.text) ?? 0.0,
        profitMargin: double.tryParse(_profitMarginController.text) ?? 0.0,
        profitPercent: cleanPercent,
        type: _selectedType, // تمرير "وارد" أو "صادر" للـ Service
      );

      _showSnackBar("تم بنجاح", Colors.green);
      _clearControllers(); 
      _loadNextCode();
    } catch (e) { 
      _showSnackBar("خطأ: $e", Colors.red); 
    } finally { 
      setState(() => _isLoading = false); 
    }
  }

  void _showItemsModal() async {
    setState(() => _isLoading = true);
    try {
      List<dynamic> items = await _apiService.getCodingData(widget.companyCode, _selectedCategory);
      setState(() => _isLoading = false);
      showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: (ctx) => _buildModal(items));
    } catch (e) { setState(() => _isLoading = false); }
  }

  Widget _buildModal(List items) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: Colors.indigo.shade900, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20))
      ),
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (c, i) => ListTile(
          title: Text(
            items[i]['name'] ?? '', 
            style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 14)
          ),
          subtitle: Row(
            children: [
              Text("كود: ${items[i]['code']}", style: const TextStyle(color: Colors.white60, fontFamily: 'Cairo', fontSize: 12)),
              if (_selectedCategory == "types" && items[i]['type'] != null) ...[
                const SizedBox(width: 15),
                Text(
                  "النوع: ${items[i]['type']}", 
                  style: TextStyle(
                    color: items[i]['type'] == "وارد" ? Colors.greenAccent : Colors.redAccent, 
                    fontFamily: 'Cairo', 
                    fontSize: 12,
                    fontWeight: FontWeight.bold
                  ),
                ),
              ],
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete, color: Colors.red), 
            onPressed: () async {
              await _apiService.deleteCode(widget.companyCode, _selectedCategory, items[i]['code']);
              Navigator.pop(context); 
              _showItemsModal();
            }
          ),
          onTap: () { 
            Navigator.pop(context); 
            setState(() { 
              _isEditMode = true; 
              _nameController.text = items[i]['name'] ?? ''; 
              _codeController.text = items[i]['code'].toString(); 
              
              // 1. لو واقفين في قسم "التصنيف" (types) نرجع حقل النوع في الـ Dropdown
              if (_selectedCategory == "types") {
                _selectedType = items[i]['type']; // ده السطر السحري اللي هيرجع النوع مكانه!
              }
              
              // 2. لو واقفين في قسم "الأصناف" (items) نرجع كل حقول الأسعار والأرباح
              if (_selectedCategory == "items") {
                _barcodeController.text = items[i]['barcode'] ?? '';
                
                // بنحول القيم لأرقام ثم نصوص للتأكد إنها مش هتعمل كراش لو جاية null من سيرفر قديم
                _wholesalePriceController.text = (items[i]['wholesale_price'] ?? '').toString();
                _sellingPriceController.text = (items[i]['selling_price'] ?? '').toString();
                _profitMarginController.text = (items[i]['profit_margin'] ?? '0.00').toString();
                _profitPercentController.text = "${items[i]['profit_percent'] ?? '0.00'} %";
              }
            }); 
          },
        ),
      ),
    );
  }

  void _clearControllers() {
    _nameController.clear(); _codeController.clear(); _barcodeController.clear();
    _wholesalePriceController.clear(); _sellingPriceController.clear();
    _profitMarginController.text = "0.00"; _profitPercentController.text = "0.00 %";
    _selectedType = null;
    _isEditMode = false;
  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, textAlign: TextAlign.center), backgroundColor: c));

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