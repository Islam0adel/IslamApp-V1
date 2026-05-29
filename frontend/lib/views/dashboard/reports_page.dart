import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../views/widgets/glass_card.dart';

class ReportsPage extends StatefulWidget {
  final String companyCode;
  
  const ReportsPage({super.key, required this.companyCode});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  // متغيرات التواريخ
  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();
  
  // نوع التقرير: 1 = مبيعات، 2 = إيراد ومصاريف
  int _selectedReportType = 1;

  // جلب البيانات من Hive
  List<Map<dynamic, dynamic>> _getFilteredTransactions() {
    final box = Hive.box('daily_transactions_box');
    return box.values.where((tx) {
      if (tx['company_code'] != widget.companyCode) return false;
      
      try {
        DateTime txDate = DateTime.parse(tx['date'].toString().substring(0, 10));
        // تجاهل الوقت في المقارنة
        DateTime from = DateTime(_fromDate.year, _fromDate.month, _fromDate.day);
        DateTime to = DateTime(_toDate.year, _toDate.month, _toDate.day);
        
        return (txDate.isAtSameMomentAs(from) || txDate.isAfter(from)) && 
               (txDate.isAtSameMomentAs(to) || txDate.isBefore(to));
      } catch (e) {
        return false;
      }
    }).map((e) => e as Map<dynamic, dynamic>).toList();
  }

  // اختيار التاريخ
  Future<void> _selectDate(BuildContext context, bool isFrom) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _fromDate : _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.dark(
              primary: Theme.of(context).primaryColor,
              onPrimary: Colors.white,
              surface: Color.fromARGB(255, 30, 30, 30),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _fromDate = picked;
          if (_toDate.isBefore(_fromDate)) _toDate = _fromDate;
        } else {
          _toDate = picked;
          if (_fromDate.isAfter(_toDate)) _fromDate = _toDate;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Color.fromARGB(149, 5, 15, 76),
        elevation: 0,
        title: const Text("التقارير", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Theme.of(context).scaffoldBackgroundColor, Color.fromARGB(238, 48, 98, 248)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                // 1. فلتر التواريخ
                _buildDateFilters(),
                const SizedBox(height: 15),
                
                // 2. أزرار اختيار نوع التقرير
                _buildReportTypeSelector(),
                const SizedBox(height: 20),
                
                // 3. عرض التقرير
                Expanded(
                  child: GlassCard(
                    child: _selectedReportType == 1 
                        ? _buildSalesReport() 
                        : _buildIncomeExpenseReport(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===================== عناصر واجهة المستخدم =====================

  Widget _buildDateFilters() {
    return Row(
      children: [
        Expanded(child: _dateButton("من", _fromDate, () => _selectDate(context, true))),
        const SizedBox(width: 10),
        Expanded(child: _dateButton("إلى", _toDate, () => _selectDate(context, false))),
      ],
    );
  }

  Widget _dateButton(String label, DateTime date, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'Cairo')),
            const SizedBox(height: 4),
            Text(DateFormat('yyyy-MM-dd').format(date), style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildReportTypeSelector() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _selectedReportType == 1 ? Theme.of(context).primaryColor : Colors.white.withOpacity(0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () => setState(() => _selectedReportType = 1),
            child: const Text("تقرير المبيعات (وارد)", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _selectedReportType == 2 ? Theme.of(context).primaryColor : Colors.white.withOpacity(0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () => setState(() => _selectedReportType = 2),
            child: const Text("تقرير فترة", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  // ===================== تقرير المبيعات =====================
  Widget _buildSalesReport() {
    final transactions = _getFilteredTransactions();
    
    // تجميع البيانات: { '2023-05-01': { 'نقدي': 100, 'فيزا': 50, 'total': 150 } }
    Map<String, Map<String, double>> dailyData = {};
    Set<String> allCategories = {}; // لمعرفة الأعمدة المطلوبة
    
    double grandTotal = 0;
    Map<String, double> categoryTotals = {};

    for (var tx in transactions) {
      if (tx['type'] == 'وارد') {
        String date = tx['date'].toString().substring(0, 10);
        String category = tx['category'] ?? 'عام';
        double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;

        allCategories.add(category);
        
        dailyData.putIfAbsent(date, () => {'total': 0.0});
        dailyData[date]![category] = (dailyData[date]![category] ?? 0.0) + amount;
        dailyData[date]!['total'] = dailyData[date]!['total']! + amount;

        categoryTotals[category] = (categoryTotals[category] ?? 0.0) + amount;
        grandTotal += amount;
      }
    }

    List<String> sortedDates = dailyData.keys.toList()..sort();
    List<String> columns = allCategories.toList()..sort();

    if (dailyData.isEmpty) {
      return const Center(child: Text("لا توجد مبيعات في هذه الفترة", style: TextStyle(color: Colors.white, fontFamily: 'Cairo')));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: MaterialStateProperty.all(Colors.white.withOpacity(0.1)),
                columns: [
                  const DataColumn(label: Text('التاريخ', style: TextStyle(color: Colors.white, fontFamily: 'Cairo'))),
                  ...columns.map((c) => DataColumn(label: Text(c, style: const TextStyle(color: Colors.white, fontFamily: 'Cairo')))),
                  const DataColumn(label: Text('إجمالي اليوم', style: TextStyle(color: Colors.amber, fontFamily: 'Cairo', fontWeight: FontWeight.bold))),
                ],
                rows: sortedDates.map((date) {
                  return DataRow(
                    cells: [
                      DataCell(Text(date, style: const TextStyle(color: Colors.white70))),
                      ...columns.map((c) => DataCell(Text((dailyData[date]![c] ?? 0).toStringAsFixed(2), style: const TextStyle(color: Colors.white70)))),
                      DataCell(Text(dailyData[date]!['total']!.toStringAsFixed(2), style: const TextStyle(color: Colors.amber))),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        const Divider(color: Colors.white24),
        // ملخص الشهر
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("الإجماليات للفترة المحددة:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              const SizedBox(height: 5),
              Wrap(
                spacing: 15,
                children: columns.map((c) => Text("$c: ${categoryTotals[c]!.toStringAsFixed(2)}", style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo'))).toList(),
              ),
              const SizedBox(height: 5),
              Text("الإجمالي الكلي: ${grandTotal.toStringAsFixed(2)}", style: const TextStyle(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
            ],
          ),
        ),
      ],
    );
  }

  // ===================== تقرير إيراد ومصاريف =====================
  Widget _buildIncomeExpenseReport() {
    final transactions = _getFilteredTransactions();
    
    double totalIncome = 0;
    Map<String, double> safeIncomes = {}; // تجميع حسب الخزينة (الفيزا، الكاش، الخ)
    
    double totalExpenses = 0;
    double totalGoods = 0; // البضاعة
    Map<String, double> expenseCategories = {};

    for (var tx in transactions) {
      double amount = double.tryParse(tx['amount'].toString()) ?? 0.0;
      
      if (tx['type'] == 'وارد') {
        totalIncome += amount;
        String treasury = tx['treasury'] ?? 'غير محدد';
        safeIncomes[treasury] = (safeIncomes[treasury] ?? 0.0) + amount;
      } else if (tx['type'] == 'صادر') {
        String category = tx['category'] ?? 'عام';
        totalExpenses += amount;
        expenseCategories[category] = (expenseCategories[category] ?? 0.0) + amount;
        if (category == 'بضاعة') {
          totalGoods += amount;
        }
      }
    }

    // الحسبة المحاسبية المحدثة
    double netExpenses = totalExpenses - totalGoods; // مصاريف بدون بضاعة
    double totalExpensesWithGoods = totalExpenses;   // المصاريف الشاملة (بما فيها البضاعة)
    double finalBalance = totalIncome - totalExpensesWithGoods; // الرصيد المتبقي = الإيراد - المصاريف الشاملة

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. قسم الإيرادات (الخزائن)
          _buildSummarySection("اجمالي الايراد", safeIncomes, totalIncome, Colors.green),
          const SizedBox(height: 15),
          
          // 2. قسم المصروفات
          _buildSummarySection("المصروفات", expenseCategories, totalExpenses, Colors.redAccent),
          const SizedBox(height: 15),
          
          // 3. الخلاصة المعدلة بالتصميم الجديد
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.3),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Theme.of(context).primaryColor),
            ),
            child: Column(
              children: [
                // أ. بيان للاطلاع فقط (المصاريف التشغيلية العادية)
                _summaryRow("إجمالي المصروفات (بدون البضاعة):", netExpenses, Colors.orangeAccent),
                
                const Divider(color: Colors.white24),
                
                // ب. البيان الجديد: إجمالي المصاريف بالبضاعة وتدخل في الحسبة
                _summaryRow("إجمالي المصروفات:", totalExpensesWithGoods, Colors.redAccent.shade100),
                
                const Divider(color: Colors.white24),
                
                // ج. الرصيد المتبقي النهائي الصحيح
                _summaryRow(
                  "الرصيد المتبقي:", 
                  finalBalance, 
                  finalBalance >= 0 ? Colors.greenAccent : Colors.redAccent, 
                  isBold: true,
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildSummarySection(String title, Map<String, double> items, double total, Color titleColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: titleColor, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          const Divider(color: Colors.white10),
          ...items.entries.map((e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(e.key, style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo')),
                Text(e.value.toStringAsFixed(2), style: const TextStyle(color: Colors.white, fontFamily: 'Cairo')),
              ],
            ),
          )),
          const Divider(color: Colors.white10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("الإجمالي", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
              Text(total.toStringAsFixed(2), style: TextStyle(color: titleColor, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, double amount, Color color, {bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.white, fontSize: isBold ? 16 : 14, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, fontFamily: 'Cairo')),
        Text(amount.toStringAsFixed(2), style: TextStyle(color: color, fontSize: isBold ? 18 : 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
      ],
    );
  }
}