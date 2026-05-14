import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../views/widgets/glass_card.dart';

class DailyHistoryPage extends StatefulWidget {
  final String companyCode;
  const DailyHistoryPage({super.key, required this.companyCode});

  @override
  State<DailyHistoryPage> createState() => _DailyHistoryPageState();
}

class _DailyHistoryPageState extends State<DailyHistoryPage> {
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 7));
  DateTime _toDate = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("معاينة الأذون", style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: Colors.transparent,
        elevation: 0,
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
          child: Column(
            children: [
              // فلتر التاريخ (جلاس)
              Padding(
                padding: const EdgeInsets.all(15),
                child: GlassCard(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _dateFilter("من", _fromDate, (d) => setState(() => _fromDate = d!)),
                      const Icon(Icons.arrow_forward, color: Colors.white24),
                      _dateFilter("إلى", _toDate, (d) => setState(() => _toDate = d!)),
                    ],
                  ),
                ),
              ),

              // قائمة الأذون (هنا يتم عرض البيانات مثل شيت الإكسيل)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(top: 10),
                  child: const Center(
                    child: Text("قائمة الأذون تظهر هنا (قيد البرمجة)", style: TextStyle(color: Colors.white38)),
                  ),
                ),
              ),

              // أزرار التصدير
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade800),
                    onPressed: () {},
                    icon: const Icon(Icons.download),
                    label: const Text("تصدير إلى Excel"),
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateFilter(String lbl, DateTime dt, Function(DateTime?) onChg) {
    return InkWell(
      onTap: () async {
        DateTime? p = await showDatePicker(context: context, initialDate: dt, firstDate: DateTime(2020), lastDate: DateTime(2101));
        onChg(p);
      },
      child: Column(
        children: [
          Text(lbl, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          Text(DateFormat('yyyy-MM-dd').format(dt), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}