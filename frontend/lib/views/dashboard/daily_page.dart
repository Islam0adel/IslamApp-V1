import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import '../../services/api_service.dart';

class DailyPage extends StatefulWidget {
  final String companyCode;
  const DailyPage({super.key, required this.companyCode});

  @override
  State<DailyPage> createState() => _DailyPageState();
}

class _DailyPageState extends State<DailyPage> {
  final DailyService _dailyService = DailyService();
  final ApiService _apiService = ApiService();

  final _amountController = TextEditingController();
  final _statementController = TextEditingController();
  final _dateController = TextEditingController();

  bool _isLoading = false;
  double _cashBalance = 0.0; // بيبدأ بـ 0
  double _visaBalance = 0.0; // بيبدأ بـ 0
  int _currentSerial = 1;    // بيبدأ بـ 1
  String? _selectedTreasury;
  String? _selectedCategory;

  List<dynamic> _treasuries = [];
  List<dynamic> _categories = [];

  @override
  void initState() {
    super.initState();
    _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    _amountController.addListener(() {
    setState(() {}); 
  });
  
  _loadInitialData();
  }

  void _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      // جلب البيانات من السيرفر (أو تصفيرها لو لسه مفيش بيانات)
      final summary = await _dailyService.getDailySummary(widget.companyCode);
      final lastSerial = await _dailyService.getLastSerial(widget.companyCode);
      final safes = await _apiService.getCodingData(widget.companyCode, "safes");
      final types = await _apiService.getCodingData(widget.companyCode, "types");

      setState(() {
        _cashBalance = (summary['cash_balance'] ?? 0.0).toDouble();
        _visaBalance = (summary['visa_balance'] ?? 0.0).toDouble();
        _currentSerial = lastSerial == 0 ? 1 : lastSerial + 1; // يبدأ بـ 1 لو الداتا فاضية
        _treasuries = safes;
        _categories = types;
        _isLoading = false;
      });
    } catch (e) {
      // في حالة أول مرة تشغيل والأرصدة لسه مفيش سيرفر، نخليهم أصفار
      setState(() {
        _cashBalance = 0.0;
        _visaBalance = 0.0;
        _currentSerial = 1;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 1. إضافة AppBar عشان زرار الرجوع
      appBar: AppBar(
        title: const Text("تسجيل اليومية"),
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.amber))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      _buildBalanceCards(),
                      const SizedBox(height: 20),
                      _buildTransactionForm(),
                      const SizedBox(height: 20),
                      _buildActionButtons(),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildBalanceCards() {
    double inputAmount = double.tryParse(_amountController.text) ?? 0.0;
    
    // حسابات لحظية (Preview)
    double displayCash = _cashBalance;
    double displayVisa = _visaBalance;

    if (_selectedCategory != null && inputAmount > 0) {
      if (_selectedCategory == "ايراد" || _selectedCategory == "تحويل من الفيزا") {
        displayCash += inputAmount;
      } else if (_selectedCategory != "فيزا" && _selectedCategory != "تحويل من النقدي") {
        displayCash -= inputAmount;
      }

      if (_selectedCategory == "فيزا" || _selectedCategory == "تحويل من النقدي") {
        displayVisa += inputAmount;
      } else if (_selectedCategory == "تحويل من الفيزا") {
        displayVisa -= inputAmount;
      }
    }

    return Row(
      children: [
        _balanceItem("رصيد نقدي", displayCash, Colors.greenAccent),
        const SizedBox(width: 15),
        _balanceItem("رصيد فيزا", displayVisa, Colors.lightBlueAccent),
      ],
    );
  }

  Widget _balanceItem(String label, double amount, Color color) {
    return Expanded(
      child: GlassCard(
        child: Column(
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            Text(amount.toStringAsFixed(2),
                style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionForm() {
    return GlassCard(
      child: Column(
        children: [
          Text("إذن رقم: $_currentSerial",
              style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 22)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _buildDropdown("الخزينة", _selectedTreasury, _treasuries, (val) => setState(() => _selectedTreasury = val)),
              ),
              const SizedBox(width: 10),
              Expanded(flex: 1, child: _customField("المبلغ", _amountController, isNumber: true)),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: _buildDropdown("التصنيف", _selectedCategory, _categories, (val) => setState(() => _selectedCategory = val)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _customField("التاريخ", _dateController, isDate: true),
              ),
            ],
          ),
          const SizedBox(height: 15),
          _customField("البيان / ملاحظات", _statementController),
        ],
      ),
    );
  }

  void _handleSave() async {
    if (_amountController.text.isEmpty || _selectedTreasury == null || _selectedCategory == null) {
      _showSnackBar("برجاء إكمال كافة البيانات", Colors.orange);
      return;
    }
    
    double amount = double.tryParse(_amountController.text) ?? 0.0;
    String cat = _selectedCategory!;

    setState(() => _isLoading = true);
    try {
      // لوجيك تعديل الأرصدة محلياً قبل الإرسال (أو الاعتماد على حسابات الباك إند)
      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: _currentSerial,
        treasury: _selectedTreasury!,
        amount: amount,
        statement: _statementController.text,
        category: cat,
        date: _dateController.text,
        type: (cat == "فيزا" || cat == "تحويل من النقدي") ? "visa" : "cash",
      );

      _showSnackBar("تم حفظ الإذن $_currentSerial بنجاح", Colors.green);
      
      // تحديث الواجهة بعد الحفظ
      _loadInitialData(); 
      _clearFields();
    } catch (e) {
      _showSnackBar("خطأ: $e", Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: color),
    );
  }

  void _clearFields() {
    _amountController.clear();
    _statementController.clear();
    setState(() {
      _selectedTreasury = null;
      _selectedCategory = null;
    });
  }

  Widget _customField(String label, TextEditingController controller, {bool isNumber = false, bool isDate = false}) {
    return TextField(
      controller: controller,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        suffixIcon: isDate ? IconButton(
          icon: const Icon(Icons.calendar_month, color: Colors.amber),
          onPressed: _pickDate,
        ) : null,
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _pickDate() async {
    DateTime? picked = await showDatePicker(
        context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2101));
    if (picked != null) setState(() => _dateController.text = DateFormat('yyyy-MM-dd').format(picked));
  }

  Widget _buildDropdown(String label, String? value, List<dynamic> items, Function(String?) onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          hint: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          dropdownColor: const Color(0xFF1E293B),
          items: items.map((item) {
            return DropdownMenuItem<String>(
                value: item['name'], child: Text(item['name'], style: const TextStyle(color: Colors.white, fontSize: 13)));
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 55,
          child: ElevatedButton.icon(
            onPressed: _handleSave,
            icon: const Icon(Icons.save_rounded),
            label: const Text("حفظ الحركة الآن", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
          ),
        ),
        const SizedBox(height: 15),
        Row(
          children: [
            Expanded(child: _secondaryButton("معاينة الأذون", Icons.visibility, Colors.blueGrey, () {})),
            const SizedBox(width: 10),
            Expanded(child: _secondaryButton("استيراد Excel", Icons.file_upload, Colors.teal, () {})),
          ],
        ),
      ],
    );
  }

  Widget _secondaryButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(backgroundColor: color.withOpacity(0.2), foregroundColor: color),
    );
  }
}