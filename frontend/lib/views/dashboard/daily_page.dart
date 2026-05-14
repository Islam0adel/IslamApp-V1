import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import '../../services/api_service.dart';
import 'daily_history_page.dart'; // استدعاء صفحة المعاينة

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
  double _cashBalance = 0.0;
  double _visaBalance = 0.0;
  int _currentSerial = 1;
  String? _selectedTreasury;
  String? _selectedCategory;

  List<dynamic> _treasuries = [];
  List<dynamic> _categories = [];

  @override
  void initState() {
    super.initState();
    _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    _amountController.addListener(() => setState(() {})); // التحديث اللحظي
    _loadInitialData();
  }

  void _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      final summary = await _dailyService.getDailySummary(widget.companyCode);
      final lastSerial = await _dailyService.getLastSerial(widget.companyCode);
      final safes = await _apiService.getCodingData(widget.companyCode, "safes");
      final types = await _apiService.getCodingData(widget.companyCode, "types");

      setState(() {
        _cashBalance = (summary['cash_balance'] ?? 0.0).toDouble();
        _visaBalance = (summary['visa_balance'] ?? 0.0).toDouble();
        _currentSerial = lastSerial == 0 ? 1 : lastSerial + 1;
        _treasuries = safes;
        _categories = types;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("تسجيل اليومية", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Container(
        height: double.infinity,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Colors.indigo.shade900, Colors.black],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      _buildBalanceCards(), // الأرصدة لحظياً
                      const SizedBox(height: 20),
                      _buildInputForm(),    // فورم الإدخال (جلاس)
                      const SizedBox(height: 25),
                      _buildMainActions(),  // زر الحفظ
                      const SizedBox(height: 15),
                      _buildSecondaryActions(), // زر المعاينة والاستيراد
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  // --- Widgets المقسمة لتصغير حجم الكود ---

  Widget _buildBalanceCards() {
    double input = double.tryParse(_amountController.text) ?? 0.0;
    double tempCash = _cashBalance;
    double tempVisa = _visaBalance;

    if (_selectedCategory != null && input > 0) {
      if (_selectedCategory == "ايراد" || _selectedCategory == "تحويل من الفيزا") tempCash += input;
      else if (_selectedCategory != "فيزا" && _selectedCategory != "تحويل من النقدي") tempCash -= input;
      if (_selectedCategory == "فيزا" || _selectedCategory == "تحويل من النقدي") tempVisa += input;
      else if (_selectedCategory == "تحويل من الفيزا") tempVisa -= input;
    }

    return Row(
      children: [
        _balanceCard("نقدي", tempCash, Colors.greenAccent),
        const SizedBox(width: 12),
        _balanceCard("فيزا", tempVisa, Colors.lightBlueAccent),
      ],
    );
  }

  Widget _balanceCard(String label, double val, Color col) {
    return Expanded(
      child: GlassCard(
        child: Column(
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            Text(val.toStringAsFixed(2), style: TextStyle(color: col, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildInputForm() {
    return GlassCard(
      child: Column(
        children: [
          Text("إذن رقم: $_currentSerial", style: const TextStyle(color: Colors.amber, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(flex: 2, child: _buildGlassDropdown("الخزينة", _selectedTreasury, _treasuries, (v) => setState(() => _selectedTreasury = v))),
              const SizedBox(width: 10),
              Expanded(flex: 1, child: _glassField("المبلغ", _amountController, isNum: true)),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(child: _buildGlassDropdown("التصنيف", _selectedCategory, _categories, (v) => setState(() => _selectedCategory = v))),
              const SizedBox(width: 10),
              Expanded(child: _glassField("التاريخ", _dateController, isDate: true)),
            ],
          ),
          const SizedBox(height: 15),
          _glassField("البيان / ملاحظات", _statementController),
        ],
      ),
    );
  }

  Widget _buildMainActions() {
    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white.withOpacity(0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          side: const BorderSide(color: Colors.white24),
        ),
        onPressed: _handleSave,
        child: const Text("حفظ الحركة", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildSecondaryActions() {
    return Row(
      children: [
        Expanded(
          child: _actionBtn("معاينة الأذون", Icons.visibility, () {
            Navigator.push(context, MaterialPageRoute(builder: (c) => DailyHistoryPage(companyCode: widget.companyCode)));
          }),
        ),
        const SizedBox(width: 10),
        Expanded(child: _actionBtn("استيراد Excel", Icons.file_present, () {})),
      ],
    );
  }

  // --- دالات مساعدة (Helper Functions) ---

  Widget _glassField(String label, TextEditingController ctrl, {bool isNum = false, bool isDate = false}) {
    return TextField(
      controller: ctrl,
      keyboardType: isNum ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        suffixIcon: isDate ? IconButton(icon: const Icon(Icons.calendar_month, color: Colors.amber, size: 20), onPressed: _pickDate) : null,
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white10)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.amber)),
      ),
    );
  }

  Widget _buildGlassDropdown(String label, String? val, List items, Function(String?) onChg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: val,
          isExpanded: true,
          dropdownColor: Colors.indigo.shade900,
          hint: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          items: items.map((i) => DropdownMenuItem<String>(value: i['name'], child: Text(i['name'], style: const TextStyle(color: Colors.white, fontSize: 13)))).toList(),
          onChanged: onChg,
        ),
      ),
    );
  }

  Widget _actionBtn(String txt, IconData ico, VoidCallback tap) {
    return OutlinedButton.icon(
      onPressed: tap,
      icon: Icon(ico, size: 18, color: Colors.amber),
      label: Text(txt, style: const TextStyle(color: Colors.white, fontSize: 12)),
      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 12)),
    );
  }

  void _handleSave() async {
    if (_amountController.text.isEmpty || _selectedTreasury == null || _selectedCategory == null) {
      _showSnackBar("برجاء إكمال البيانات", Colors.orange);
      return;
    }
    setState(() => _isLoading = true);
    try {
      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: _currentSerial,
        treasury: _selectedTreasury!,
        amount: double.parse(_amountController.text),
        statement: _statementController.text,
        category: _selectedCategory!,
        date: _dateController.text,
        type: (_selectedCategory == "فيزا" || _selectedCategory == "تحويل من النقدي") ? "visa" : "cash",
      );
      _showSnackBar("تم الحفظ بنجاح", Colors.green);
      _loadInitialData();
      _amountController.clear();
      _statementController.clear();
    } catch (e) {
      _showSnackBar("خطأ: $e", Colors.red);
      setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, textAlign: TextAlign.center), backgroundColor: c));

  Future<void> _pickDate() async {
    DateTime? p = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2101));
    if (p != null) setState(() => _dateController.text = DateFormat('yyyy-MM-dd').format(p));
  }
}