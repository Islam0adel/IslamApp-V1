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

  @override
  void initState() {
    super.initState();
    _priceController.addListener(_calculateValue);
    _qtyController.addListener(_calculateValue);
  }

  void _calculateValue() {
    double price = double.tryParse(_priceController.text) ?? 0;
    double qty = double.tryParse(_qtyController.text) ?? 0;
    if (mounted) {
      setState(() {
        _totalValueController.text = (price * qty).toStringAsFixed(2);
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _barcodeController.dispose();
    _priceController.dispose();
    _qtyController.dispose();
    _totalValueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("نظام التكويد", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          ),
        ),
        child: SafeArea(
          child: _isLoading 
            ? const Center(child: CircularProgressIndicator(color: Colors.amber))
            : ListView( // غيرنا الـ GridView لـ ListView عشان يبقوا تحت بعض
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                children: [
                  _buildListTile("تكويد الخزائن", Icons.account_balance_wallet, "safes"),
                  _buildListTile("تكويد الموردين", Icons.local_shipping, "suppliers"),
                  _buildListTile("تكويد المخازن", Icons.warehouse, "stores"),
                  _buildListTile("تكويد العملاء", Icons.people, "customers"),
                  _buildListTile("تكويد التصنيف", Icons.category, "types"),
                  _buildListTile("تكويد الموظفين", Icons.badge, "employees"),
                  _buildListTile("تكويد الأصناف", Icons.inventory_2, "items"),
                ],
              ),
        ),
      ),
    );
  }

  // الـ Widget الجديد للزراير المستطيلة
  Widget _buildListTile(String title, IconData icon, String category) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _openManageModal(category, title),
        child: GlassCard(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10), // صغرنا الـ Padding
            height: 60, // وحدنا الارتفاع عشان تبقى مستطيلة نحيفة
            child: Row(
              children: [
                Icon(icon, color: Colors.amberAccent, size: 28),
                const SizedBox(width: 20),
                Text(
                  title, 
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Cairo')
                ),
                const Spacer(),
                const Icon(Icons.arrow_forward_ios, color: Colors.white24, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
  // دالة لفتح واجهة الإدارة لكل قسم
  void _openManageModal(String category, String title) async {
    setState(() => _isLoading = true);
    try {
      List<dynamic> items = await _apiService.getCodingData(widget.companyCode, category);
      if (!mounted) return;
      
      _clearControllers(); // تصفير الحقول قبل كل عملية جديدة

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) => Container(
            height: MediaQuery.of(context).size.height * 0.85,
            decoration: const BoxDecoration(
              color: Color(0xFF1E293B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // العنوان
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(title, style: const TextStyle(color: Colors.amber, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, color: Colors.white54)),
                  ],
                ),
                const Divider(color: Colors.white10),

                // منطقة الإدخال
                _buildInputFields(category, setModalState, items),

                const SizedBox(height: 15),
                
                // زر الحفظ / التعديل الذكي
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _handleSave(category, setModalState, items),
                    icon: Icon(_isEditMode ? Icons.edit_note : Icons.add_task),
                    label: Text(_isEditMode ? "تحديث السجل الحالي" : "إضافة سجل جديد", style: const TextStyle(fontFamily: 'Cairo')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isEditMode ? Colors.blueAccent : Colors.green.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),

                const SizedBox(height: 20),
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text("السجلات الحالية:", style: TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'Cairo'))
                ),
                const SizedBox(height: 10),

                // عرض البيانات في لستة
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text("لا توجد بيانات مسجلة", style: TextStyle(color: Colors.white38)))
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.03),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: ListTile(
                                onTap: () {
                                  // عند الضغط يتم ملء الحقول للتعديل
                                  setModalState(() {
                                    _isEditMode = true;
                                    _codeController.text = item['code'].toString();
                                    _nameController.text = item['name'] ?? '';
                                    if (category == 'items') {
                                      _barcodeController.text = item['barcode'] ?? '';
                                      _priceController.text = item['price']?.toString() ?? '';
                                      _qtyController.text = item['quantity']?.toString() ?? '';
                                    }
                                  });
                                },
                                leading: CircleAvatar(
                                  backgroundColor: Colors.amber.withOpacity(0.1),
                                  child: Text(item['code'].toString(), style: const TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                                title: Text(item['name'], style: const TextStyle(color: Colors.white, fontSize: 14)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                                  onPressed: () => _confirmDelete(category, item['code'].toString(), setModalState, items),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _showSnackBar("فشل تحميل البيانات: $e", Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
  }
  Widget _buildInputFields(String category, StateSetter setModalState, List<dynamic> items) {
    // توليد سيريال تلقائي للأقسام العادية فقط لو مش في وضع التعديل
    if (!_isEditMode && category != "items" && _codeController.text.isEmpty) {
      int maxCode = 0;
      for (var item in items) {
        int current = int.tryParse(item['code'].toString()) ?? 0;
        if (current > maxCode) maxCode = current;
      }
      _codeController.text = (maxCode + 1).toString();
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(flex: 1, child: _customTextField("الكود", _codeController, enabled: category == "items")),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: _customTextField("الاسم", _nameController)),
          ],
        ),
        if (category == "items") ...[
          const SizedBox(height: 10),
          _customTextField("باركود الصنف", _barcodeController),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _customTextField("السعر", _priceController, isNumber: true)),
              const SizedBox(width: 10),
              Expanded(child: _customTextField("الكمية", _qtyController, isNumber: true)),
            ],
          ),
          const SizedBox(height: 10),
          _customTextField("إجمالي القيمة", _totalValueController, enabled: false),
        ],
      ],
    );
  }

  Widget _customTextField(String label, TextEditingController controller, {bool enabled = true, bool isNumber = false}) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: isNumber ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
        filled: true,
        fillColor: enabled ? Colors.white.withOpacity(0.05) : Colors.black26,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  // دالة الحفظ الذكية (إضافة وتعديل)
  void _handleSave(String category, StateSetter setModalState, List<dynamic> itemsList) async {
    if (_nameController.text.isEmpty || _codeController.text.isEmpty) {
      _showSnackBar("برجاء إكمال البيانات الأساسية", Colors.orange);
      return;
    }

    try {
      // مناداة الـ API بالأسماء (Named Arguments)
      await _apiService.saveNewCode(
        companyCode: widget.companyCode,
        category: category,
        code: _codeController.text,
        name: _nameController.text,
        barcode: category == 'items' ? _barcodeController.text : null,
        price: double.tryParse(_priceController.text),
        quantity: double.tryParse(_qtyController.text),
        totalValue: double.tryParse(_totalValueController.text),
      );

      _showSnackBar(_isEditMode ? "تم تحديث البيانات" : "تم حفظ السجل بنجاح", Colors.green);
      
      // جلب البيانات المحدثة فوراً
      List<dynamic> updated = await _apiService.getCodingData(widget.companyCode, category);
      setModalState(() {
        itemsList.clear();
        itemsList.addAll(updated);
        _clearControllers();
      });
    } catch (e) {
      _showSnackBar("فشل العملية: $e", Colors.red);
    }
  }

  void _confirmDelete(String category, String code, StateSetter setModalState, List<dynamic> itemsList) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text("تأكيد الحذف", style: TextStyle(color: Colors.white, fontFamily: 'Cairo')),
        content: const Text("هل تريد حذف هذا السجل نهائياً؟", style: TextStyle(color: Colors.white70, fontFamily: 'Cairo')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("إلغاء")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _apiService.deleteCode(widget.companyCode, category, code);
                List<dynamic> updated = await _apiService.getCodingData(widget.companyCode, category);
                setModalState(() {
                  itemsList.clear();
                  itemsList.addAll(updated);
                });
                _showSnackBar("تم الحذف بنجاح", Colors.blueGrey);
              } catch (e) {
                _showSnackBar("حدث خطأ أثناء الحذف", Colors.red);
              }
            },
            child: const Text("حذف"),
          ),
        ],
      ),
    );
  }

  void _clearControllers() {
    _nameController.clear();
    _codeController.clear();
    _barcodeController.clear();
    _priceController.clear();
    _qtyController.clear();
    _totalValueController.text = "0.00";
    _isEditMode = false;
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}