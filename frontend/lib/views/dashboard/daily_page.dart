import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import '../../services/api_service.dart';
import 'daily_history_page.dart';

class DailyPage extends StatefulWidget {
  final String companyCode;
  final String selectedBranch; 
  final String userName; 
  final Map<String, dynamic>? editItem;

  const DailyPage({
    super.key, 
    required this.companyCode, 
    required this.selectedBranch,
    required this.userName, 
    this.editItem,
  });

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
    _amountController.addListener(() => setState(() {}));
    _loadInitialData();

    if (widget.editItem != null) {
      _amountController.text = widget.editItem!['amount'].toString();
      _statementController.text = widget.editItem!['statement'] ?? "";
      _dateController.text = widget.editItem!['date'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
      _currentSerial = widget.editItem!['serial'] ?? 1;
      _selectedTreasury = widget.editItem!['treasury'];
      _selectedCategory = widget.editItem!['category'];
    } else {
      _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    }
  }

  double get _liveCashBalance {
    double val = double.tryParse(_amountController.text) ?? 0.0;
    if (_selectedCategory == "ايراد" || _selectedCategory == "تحويل من الفيزا") {
      return _cashBalance + val;
    } else if (_selectedCategory == "تحويل من النقدي") {
      return _cashBalance - val;
    } else if (_selectedCategory != null && _selectedCategory != "فيزا") {
      return _cashBalance - val;
    }
    return _cashBalance;
  }

  double get _liveVisaBalance {
    double val = double.tryParse(_amountController.text) ?? 0.0;
    if (_selectedCategory == "فيزا" || _selectedCategory == "تحويل من النقدي") {
      return _visaBalance + val;
    } else if (_selectedCategory == "تحويل من الفيزا") {
      return _visaBalance - val;
    }
    return _visaBalance;
  }

  void _loadInitialData() async {
    if (_treasuries.isEmpty) {
      setState(() => _isLoading = true);
    }
    try {
      final safes = await _apiService.getCodingData(widget.companyCode, "safes");
      final types = await _apiService.getCodingData(widget.companyCode, "types");

      String? targetTreasury = _selectedTreasury;
      if (widget.editItem == null && targetTreasury == null && safes.isNotEmpty) {
        var defaultSafe = safes.firstWhere(
          (s) => s['id'].toString() == "1" || s['code'].toString() == "1",
          orElse: () => safes.first
        );
        targetTreasury = defaultSafe['name'];
      }

      final summary = await _dailyService.getDailySummary(widget.companyCode, targetTreasury, widget.selectedBranch);

      int serialVal = _currentSerial;
      if (widget.editItem == null) {
        final lastSerial = await _dailyService.getLastSerial(widget.companyCode);
        serialVal = lastSerial == 0 ? 1 : lastSerial + 1;
      }

      if (mounted) {
        setState(() {
          _treasuries = safes;
          _categories = types;
          _selectedTreasury = targetTreasury;
          _currentSerial = serialVal;
          _cashBalance = (summary['cash_balance'] ?? 0.0).toDouble();
          _visaBalance = (summary['visa_balance'] ?? 0.0).toDouble();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 🚀 إعادة بناء دالة الاستيراد لتأمين سحب البيانات المحددة وحقن الفرع والمستخدم تلقائياً
  Future<void> _importFromExcel() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true, 
    );

    if (result != null) {
      setState(() => _isLoading = true);
      try {
        var bytes = result.files.single.bytes;
        if (bytes == null && result.files.single.path != null) {
          bytes = File(result.files.single.path!).readAsBytesSync();
        }

        if (bytes == null) throw "تعذر قراءة بيانات ملف الإكسيل";

        var excel = excel_lib.Excel.decodeBytes(bytes);
        String defaultTreasury = _selectedTreasury ?? "الخزينة الرئيسية";
        String savingBranch = widget.selectedBranch == "كل الفروع" ? "الفرع الرئيسي" : widget.selectedBranch;

        for (var table in excel.tables.keys) {
          var rows = excel.tables[table]!.rows;
          if (rows.isEmpty) continue;

          // 1. قراءة الصف الأول ديناميكياً لتحديد أماكن الأعمدة
          var headerRow = rows[0];
          int amountIndex = -1;
          int statementIndex = -1;
          int categoryIndex = -1;
          int dateIndex = -1;

          for (int c = 0; c < headerRow.length; c++) {
            if (headerRow[c] == null || headerRow[c]?.value == null) continue;
            String headerText = headerRow[c]!.value.toString().trim().toLowerCase();

            if (headerText.contains("المبلغ") || headerText.contains("amount")) {
              amountIndex = c;
            } else if (headerText.contains("البيان") || headerText.contains("statement") || headerText.contains("الشرح")) {
              statementIndex = c;
            } else if (headerText.contains("التصنيف") || headerText.contains("category") || headerText.contains("النوع")) {
              categoryIndex = c;
            } else if (headerText.contains("التاريخ") || headerText.contains("date")) {
              dateIndex = c;
            }
          }

          // التحقق من أن الأعمدة الأساسية تم العثور عليها لمنع الأخطاء
          if (amountIndex == -1) {
            throw "لم يتم العثور على عمود (المبلغ) في السطر الأول من شيت الإكسيل!";
          }

          // 2. نبدأ الآن من الصف الثاني i = 1 لقراءة الحركات بناءً على الكشافات المستخرجة
          for (int i = 1; i < rows.length; i++) {
            var row = rows[i];
            if (row.isEmpty) continue;
            
            // التأكد من أن خانة المبلغ ليست فارغة للسطر الحالي
            if (row.length <= amountIndex || row[amountIndex] == null || row[amountIndex]?.value == null) continue;

            // أ. سحب القيم ديناميكياً بناءً على الكشافات (Indexes) المحددة
            String amountStr = row[amountIndex]!.value.toString();
            
            String statementStr = (statementIndex != -1 && row.length > statementIndex && row[statementIndex] != null) 
                ? row[statementIndex]!.value.toString() : "";
                
            String categoryStr = (categoryIndex != -1 && row.length > categoryIndex && row[categoryIndex] != null) 
                ? row[categoryIndex]!.value.toString() : "عام";
            
            // معالجة التاريخ بديناميكية
            String rawDate = (dateIndex != -1 && row.length > dateIndex && row[dateIndex] != null) 
                ? row[dateIndex]!.value.toString() : DateFormat('yyyy-MM-dd').format(DateTime.now());
            String formattedDate = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;

            // ب. تحديد نوع الحركة دايناميك (visa أو cash) بناءً على اسم التصنيف المستورد ديناميكياً
            String calculatedType = (categoryStr == "فيزا" || categoryStr == "تحويل من النقدي") ? "visa" : "cash";

            // ج. رفع السطر المصفى إلى الباك إند
            await _dailyService.saveTransaction(
              companyCode: widget.companyCode,
              serial: _currentSerial++,
              treasury: defaultTreasury,
              amount: double.tryParse(amountStr) ?? 0.0,
              statement: statementStr,
              category: categoryStr,
              date: formattedDate,
              type: calculatedType,
              employee: widget.userName,       
              branch: savingBranch,            
            );
          }
        }
        
        _showSnackBar("تم استيراد الشيت ديناميكياً بنجاح وتجاهل الأعمدة الزائدة", Colors.green);
        _loadInitialData(); 
        
      } catch (e) {
        _showSnackBar("خطأ أثناء الاستيراد: $e", Colors.red);
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Column(
          children: [
            Text(widget.editItem != null ? "تعديل حركة" : "تسجيل يومية", style: const TextStyle(fontFamily: 'Cairo', fontSize: 16)),
            Text("إذن رقم: $_currentSerial", style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Container(
        height: double.infinity, width: double.infinity,
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
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text("فرع العمل الحالي: ${widget.selectedBranch}", style: const TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _balanceCard("رصيد النقدي", _liveCashBalance, Colors.greenAccent)),
                          const SizedBox(width: 15),
                          Expanded(child: _balanceCard("رصيد الفيزا", _liveVisaBalance, Colors.cyanAccent)),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildInputForm(),
                      const SizedBox(height: 25),
                      _buildMainActions(),
                      const SizedBox(height: 15),
                      _buildSecondaryActions(),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _balanceCard(String title, double amount, Color color) {
    return GlassCard(
      child: Column(
        children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'Cairo')),
          const SizedBox(height: 5),
          Text(amount.toStringAsFixed(2), style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildInputForm() {
    return GlassCard(
      child: Column(
        children: [
          _buildTextField(_amountController, "المبلغ", Icons.attach_money, isNumber: true),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: _buildDropdown("الخزينة", _selectedTreasury, _treasuries, (val) {
                  setState(() => _selectedTreasury = val);
                  _loadInitialData();
                }),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDropdown("التصنيف", _selectedCategory, _categories, 
                    (val) => setState(() => _selectedCategory = val)),
              ),
            ],
          ),
          const SizedBox(height: 15),
          _buildTextField(_statementController, "البيان", Icons.description),
          const SizedBox(height: 15),
          _buildDatePicker(),
        ],
      ),
    );
  }

  Widget _buildMainActions() {
    bool isEdit = widget.editItem != null;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 55,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isEdit ? Colors.orange.withOpacity(0.3) : Colors.white.withOpacity(0.2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              side: BorderSide(color: isEdit ? Colors.orangeAccent : Colors.white24),
            ),
            onPressed: _handleSave,
            child: Text(isEdit ? "تعديل الإذن" : "حفظ الحركة", 
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          ),
        ),
        // 🟢 إرجاع زرار "استيراد من إكسيل" الأنيق مكانه في حالة وضع الإدخال الجديد فقط
        if (!isEdit) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.greenAccent, width: 1.2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              onPressed: _importFromExcel, // استدعاء دالة الاستيراد المطورة
              icon: const Icon(Icons.upload_file, color: Colors.greenAccent, size: 20),
              label: const Text("استيراد من إكسيل", style: TextStyle(color: Colors.greenAccent, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
            ),
          ),
        ]
      ],
    );
  }

  void _handleSave() async {
    if (_amountController.text.isEmpty || _selectedTreasury == null || _selectedCategory == null) {
      _showSnackBar("برجاء إكمال البيانات", Colors.orange);
      return;
    }
    setState(() => _isLoading = true);
    try {
      String savingBranch = widget.selectedBranch == "كل الفروع" ? "الفرع الرئيسي" : widget.selectedBranch;

      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: _currentSerial,
        treasury: _selectedTreasury!,
        amount: double.parse(_amountController.text),
        statement: _statementController.text,
        category: _selectedCategory!,
        date: _dateController.text,
        type: (_selectedCategory == "فيزا" || _selectedCategory == "تحويل من النقدي") ? "visa" : "cash",
        employee: widget.userName, 
        branch: savingBranch, 
      );

      if (widget.editItem != null) {
        Navigator.pop(context, true);
      } else {
        _showSnackBar("تم الحفظ بنجاح", Colors.green);
        _amountController.clear();
        _statementController.clear();
        _loadInitialData();
      }
    } catch (e) {
      _showSnackBar("خطأ: $e", Colors.red);
      setState(() => _isLoading = false);
    }
  }

  Widget _buildTextField(TextEditingController ctrl, String label, IconData icon, {bool isNumber = false}) {
    return TextField(
      controller: ctrl,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: Colors.white70),
        labelText: label, labelStyle: const TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.cyanAccent)),
        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 15),
      ),
    );
  }

  Widget _buildDropdown(String label, String? value, List<dynamic> items, Function(String?) onChanged) {
    return DropdownButtonFormField<String>(
      value: value,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label, labelStyle: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 12),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
        contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
      ),
      items: items.map((item) => DropdownMenuItem<String>(value: item['name'], child: Text(item['name'] ?? ""))).toList(),
      onChanged: onChanged,
    );
  }

  Widget _buildDatePicker() {
    return TextField(
      controller: _dateController, readOnly: true, style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.calendar_today, color: Colors.white70), labelText: "التاريخ", 
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
      ),
      onTap: _pickDate,
    );
  }

  Widget _buildSecondaryActions() {
    return TextButton.icon(
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => DailyHistoryPage(
        companyCode: widget.companyCode,
        selectedBranch: widget.selectedBranch, 
        userName: widget.userName,
      ))),
      icon: const Icon(Icons.history, color: Colors.cyanAccent),
      label: const Text("معاينة الحركات", style: TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo')),
    );
  }

  Future<void> _pickDate() async {
    DateTime? p = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2101));
    if (p != null) setState(() => _dateController.text = DateFormat('yyyy-MM-dd').format(p));
  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: c)
  );
}