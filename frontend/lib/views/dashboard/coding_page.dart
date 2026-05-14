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
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _totalValueController = TextEditingController(text: "0.00");

  String _selectedCategory = "items"; 

  @override
  void initState() {
    super.initState();
    _priceController.addListener(_calculateValue);
    _qtyController.addListener(_calculateValue);
    _loadNextCode(); // عشان أول ما يفتح يجيب الكود اللي عليه الدور
  }

  // منع تعديل الكود يدوياً إلا في الأصناف
  bool get _isCodeReadOnly => _selectedCategory != "items";

  void _calculateValue() {
    double price = double.tryParse(_priceController.text) ?? 0;
    double qty = double.tryParse(_qtyController.text) ?? 0;
    if (mounted) setState(() => _totalValueController.text = (price * qty).toStringAsFixed(2));
  }

  // جلب الكود التالي أوتوماتيكياً
  void _loadNextCode() async {
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
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8, runSpacing: 8, alignment: WrapAlignment.center,
                            children: [
                              _buildTinyCategory("safes", "الخزائن", Icons.account_balance_wallet),
                              _buildTinyCategory("items", "الأصناف", Icons.inventory_2),
                              _buildTinyCategory("suppliers", "الموردين", Icons.local_shipping),
                              _buildTinyCategory("customers", "العملاء", Icons.groups),
                              _buildTinyCategory("stores", "المخازن", Icons.store),
                              _buildTinyCategory("types","التصنيف", Icons.payments), // تم التعديل
                              _buildTinyCategory("units", "طرق الدفع", Icons.straighten),
                              _buildTinyCategory("banks", "البنوك", Icons.account_balance),
                              _buildTinyCategory("jobs", "الموظفين", Icons.badge), // تم التعديل
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
                          
                          if (_selectedCategory == "items") ...[
                            const SizedBox(height: 10),
                            _buildField("الباركود", _barcodeController, Icons.barcode_reader),
                            const SizedBox(height: 10),
                            Row(children: [
                              Expanded(child: _buildField("السعر", _priceController, Icons.money)),
                              const SizedBox(width: 10),
                              Expanded(child: _buildField("الكمية", _qtyController, Icons.add_box)),
                            ]),
                            const SizedBox(height: 10),
                            _buildField("الإجمالي", _totalValueController, Icons.calculate, enabled: false),
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
    setState(() => _isLoading = true);
    try {
      await _apiService.saveNewCode(
        companyCode: widget.companyCode, category: _selectedCategory,
        code: _codeController.text, name: _nameController.text,
        barcode: _barcodeController.text, price: double.tryParse(_priceController.text) ?? 0.0,
        quantity: double.tryParse(_qtyController.text) ?? 0.0, totalValue: double.tryParse(_totalValueController.text) ?? 0.0,
      );
      _showSnackBar("تم بنجاح", Colors.green);
      _clearControllers(); _loadNextCode();
    } catch (e) { _showSnackBar("خطأ: $e", Colors.red); }
    finally { setState(() => _isLoading = false); }
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
      decoration: BoxDecoration(color: Colors.indigo.shade900, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (c, i) => ListTile(
          title: Text(items[i]['name'] ?? '', style: const TextStyle(color: Colors.white)),
          subtitle: Text("كود: ${items[i]['code']}", style: const TextStyle(color: Colors.white60)),
          trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () async {
            await _apiService.deleteCode(widget.companyCode, _selectedCategory, items[i]['code']);
            Navigator.pop(context); _showItemsModal();
          }),
          onTap: () { Navigator.pop(context); setState(() { _isEditMode = true; _nameController.text = items[i]['name']; _codeController.text = items[i]['code'].toString(); }); },
        ),
      ),
    );
  }

  void _clearControllers() {
    _nameController.clear(); _codeController.clear(); _barcodeController.clear();
    _priceController.clear(); _qtyController.clear(); _totalValueController.text = "0.00";
    _isEditMode = false;
  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, textAlign: TextAlign.center), backgroundColor: c));

  @override
  void dispose() {
    _nameController.dispose(); _codeController.dispose(); _barcodeController.dispose();
    _priceController.dispose(); _qtyController.dispose(); _totalValueController.dispose();
    super.dispose();
  }
}