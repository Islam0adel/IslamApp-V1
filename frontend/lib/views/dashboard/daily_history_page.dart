import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import 'daily_page.dart';
import 'package:universal_html/html.dart' as html;
import 'package:excel/excel.dart' as excel_lib;
import 'package:hive_flutter/hive_flutter.dart';

class DailyHistoryPage extends StatefulWidget {
  final String companyCode;
  final String? userName;
  final String? selectedBranchCode; // 🌟 التعديل هنا: استقبال الكود بدلاً من الاسم

  const DailyHistoryPage({
    super.key,
    required this.companyCode,
    this.userName,
    this.selectedBranchCode,
  });

  @override
  State<DailyHistoryPage> createState() => _DailyHistoryPageState();
}

class _DailyHistoryPageState extends State<DailyHistoryPage> {
  final DailyService _dailyService = DailyService();
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 7));
  DateTime _toDate = DateTime.now();

  // 🌟 هذا هو السطر السحري الناقص الذي كان يسبب الإيرور في الملف كله:
  // ignore: unused_field
  List<Map<String, dynamic>> _historyData = [];

  bool _isLoading = false;
  bool _isCategoryGrouped = false;

  @override
  void initState() {
    super.initState();
    _fetchData(); // لتغذية وجلب البيانات وتحديث الكاش المحلي عند الفتح
  }

  // 🌟 دالة مساعدة لجلب اسم الفرع من الكود الخاص به لعرضه للمستخدم
  String _getBranchName(String? code) {
    if (code == null || code == 'all' || code == '') return 'كل الفروع';
    final Box codingBox = Hive.box('coding_box');
    final rawData = codingBox.get("${widget.companyCode}_branches", defaultValue: []);
    for(var item in rawData) {
      if(item['code']?.toString() == code.toString()) return item['name']?.toString() ?? "فرع غير معروف";
    }
    return "فرع غير معروف";
  }

  void _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final data = await _dailyService.getTransactionsHistory(
        widget.companyCode,
        DateFormat('yyyy-MM-dd').format(_fromDate),
        DateFormat('yyyy-MM-dd').format(_toDate),
        branchCode: widget.selectedBranchCode, // 🌟 التعديل هنا
      );

      setState(() {
        _historyData = data.map<Map<String, dynamic>>((item) => Map<String, dynamic>.from(item)).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  // ⚠️ ملحوظة: باقي الدوال الخاصة بك مثل الـ build و _buildDataRow تظل كما هي بالأسفل ولا تحذفها!

  // دالة لفرز وترتيب الحركات المفلترة ديناميكياً
  List<Map<String, dynamic>> _getSortedData(List<Map<String, dynamic>> list) {
    List<Map<String, dynamic>> sortedList = List.from(list);
    
    if (_isCategoryGrouped) {
      sortedList.sort((a, b) {
        int cmp = (a['category'] ?? '').compareTo(b['category'] ?? '');
        if (cmp != 0) return cmp;
        
        // الترتيب بالتاريخ من الأقدم للأحدث في نفس التصنيف
        String dateA = a['date'] ?? '';
        String dateB = b['date'] ?? '';
        int dateCmp = dateA.compareTo(dateB);
        if (dateCmp != 0) return dateCmp;
        
        return (a['serial'] ?? 0).compareTo(b['serial'] ?? 0);
      });
    } else {
      // 🌟 الترتيب الأساسي: بالتاريخ المكتوب (من الأقدم للأحدث)
      sortedList.sort((a, b) {
        String dateA = a['date'] ?? '';
        String dateB = b['date'] ?? '';
        int dateCmp = dateA.compareTo(dateB);
        
        // لو التاريخين متطابقين، نرتبهم برقم الإذن كخيار احتياطي
        if (dateCmp != 0) return dateCmp;
        return (a['serial'] ?? 0).compareTo(b['serial'] ?? 0);
      });
    }
    return sortedList;
  }

  Future<void> _exportToExcel(List<Map<String, dynamic>> currentData) async {
    if (currentData.isEmpty) {
      _showSnackBar("لا توجد بيانات لتصديرها", Colors.orange);
      return;
    }

    try {
      String formattedDate =
          "${DateTime.now().day}-${DateTime.now().month}-${DateTime.now().year}";
      String fileName = "تقرير_اليومية_$formattedDate.xlsx";
      var excel = excel_lib.Excel.createExcel();

      String defaultSheet = excel.tables.keys.first;
      excel.rename(defaultSheet, 'Daily_Records');
      excel_lib.Sheet sheetObject = excel['Daily_Records'];

      for (var table in excel.tables.keys.toList()) {
        if (table != 'Daily_Records') {
          excel.delete(table);
        }
      }

      // 🌟 إضافة كل الأعمدة الجديدة لملف الإكسيل
      sheetObject.appendRow([
        excel_lib.TextCellValue("رقم الإذن"),
        excel_lib.TextCellValue("المبلغ"),
        excel_lib.TextCellValue("البيان"),
        excel_lib.TextCellValue("التصنيف"),
        excel_lib.TextCellValue("التاريخ"),
        excel_lib.TextCellValue("الفرع"),  // 👈 إضافة جديدة
        excel_lib.TextCellValue("الموظف"), // 👈 إضافة جديدة
      ]);

      for (var row in currentData) {
        sheetObject.appendRow([
          excel_lib.TextCellValue(row['serial']?.toString() ?? ""),
          excel_lib.TextCellValue(row['amount']?.toString() ?? "0"),
          excel_lib.TextCellValue(row['statement'] ?? ""),
          excel_lib.TextCellValue(row['category'] ?? ""),
          excel_lib.TextCellValue(row['date'] ?? ""),
          excel_lib.TextCellValue(_getBranchName(row['branch_code']?.toString())), // 🌟 التعديل هنا
          excel_lib.TextCellValue(row['employee'] ?? "غير معروف"), // 👈 إضافة جديدة
        ]);
      }

      var fileBytes = excel.encode();
      if (fileBytes == null) return;

      if (identical(0, 0.0)) {
        final blob = html.Blob([
          fileBytes
        ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
        final url = html.Url.createObjectUrlFromBlob(blob);
        final anchor = html.AnchorElement(href: url)
          ..setAttribute("download", fileName)
          ..style.display = "none";
        html.document.body?.append(anchor);
        anchor.click();
        anchor.remove();
        html.Url.revokeObjectUrl(url);
        _showSnackBar("تم تحميل $fileName بنجاح", Colors.green);
      } else {
        String? selectedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'اختر مكان حفظ ملف الإكسيل',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['xlsx'],
        );

        if (selectedPath != null) {
          if (!selectedPath.endsWith('.xlsx')) selectedPath += '.xlsx';
          final file = File(selectedPath);
          await file.writeAsBytes(fileBytes);
          _showSnackBar("تم حفظ الملف في: $selectedPath", Colors.green);
        }
      }
    } catch (e) {
      _showSnackBar("فشل التصدير: $e", Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    bool isWebOrDesktop = screenWidth > 600;
    final Box dailyBox = Hive.box('daily_transactions_box');

    // 🌟 السحر هنا: التحكم في إيماءة وزر الرجوع الخاص بنظام الهاتف بالكامل
    return PopScope(
      canPop: false, // تعطيل الخروج التلقائي لمنع إغلاق التطبيق فجأة
      onPopInvoked: (didPop) async {
        if (didPop) return; // إذا تم الخروج بالفعل لا تفعل شيء
        
        if (context.mounted) {
          Navigator.pop(context); // 🌟 تنفيذ نفس أمر الرجوع المعتمد داخل البرنامج
        }
      },
      child: ValueListenableBuilder(
        valueListenable: dailyBox.listenable(),
        builder: (context, Box box, child) {
          // 1. استخراج الحركات الفردية المحدثة وتصفيتها بحسب نطاق التاريخ المختار وكود الشركة ديناميكياً
          List<Map<String, dynamic>> displayList = [];
          String startStr = DateFormat('yyyy-MM-dd').format(_fromDate);
          String endStr = DateFormat('yyyy-MM-dd').format(_toDate);

          for (var item in box.values) {
            if (item is Map && item['company_code'] == widget.companyCode) {

            // 🌟 الإضافة السحرية: تجاهل حركات التحويل المخفية لكي لا تظهر نهائياً في الواجهة!
            // if (item['category'] == 'transfer_hidden') continue; 
              // 🌟 فلترة ذكية: تجاهل الحركات التي لا تنتمي للفرع المختار (إلا لو اختار الكل) بناءً على الكود
            if (widget.selectedBranchCode != null && widget.selectedBranchCode != "all" && widget.selectedBranchCode != "") {
              if (item['branch_code']?.toString() != widget.selectedBranchCode) continue;
            }

              String txDate = item['date']?.toString() ?? "";
              if (txDate.compareTo(startStr) >= 0 && txDate.compareTo(endStr) <= 0) {
                displayList.add(Map<String, dynamic>.from(item));
              }
            }
          }

          // 2. تطبيق الفرز والترتيب المطلق
          displayList = _getSortedData(displayList);

          return Scaffold(
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              title: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "سجل الحركات",
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  // 🌟 توضيح الفرع الحالي المفلتر
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.cyanAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
  "فرع: ${_getBranchName(widget.selectedBranchCode)}", // 🌟 التعديل هنا
  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.cyanAccent),
),
                  ),
                ],
              ),
              centerTitle: true,
              backgroundColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: 70, // متناسق مع ارتفاع صفحة اليومية

              // 🌟 أزرار التحكم في أعلى اليسار
              actions: [
                // 1️⃣ زر التجميع والفلترة حسب التصنيف
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Tooltip(
                    message: _isCategoryGrouped ? "إلغاء تجميع التصنيفات" : "تجميع حسب التصنيف",
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.12), // خلفية زجاجية خفيفة
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _isCategoryGrouped ? Colors.orangeAccent.withOpacity(0.5) : Colors.cyanAccent.withOpacity(0.3),
                        ),
                      ),
                      child: IconButton(
                        icon: Icon(
                          _isCategoryGrouped ? Icons.filter_alt : Icons.filter_alt_outlined,
                          color: _isCategoryGrouped ? Colors.orangeAccent : Colors.cyanAccent,
                          size: 22,
                        ),
                        onPressed: () {
                          setState(() {
                            _isCategoryGrouped = !_isCategoryGrouped;
                          });
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // 2️⃣ زر التصدير إلى إكسيل (يصدر الفترة الحالية المعروضة فقط المفلترة من وإلى)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Tooltip(
                    message: "تصدير البيانات المعروضة لإكسيل",
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.12), // خلفية زجاجية خفيفة
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.file_download, color: Colors.greenAccent, size: 22),
                        onPressed: () {
                          // نقوم بتمرير الـ displayList التي تحتوي على بيانات البحث الحالي فقط
                          _exportToExcel(displayList);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12), // مسافة جمالية عن حافة الشاشة اليسرى
              ],
            ),
            body: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black, Colors.indigo.shade900, Colors.black],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: SafeArea(
                child: Center(
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: isWebOrDesktop ? 600 : double.infinity,
                    ),
                    child: Column(
                      children: [
                        _buildDateFilters(),
                        _buildTableHeader(),
                        Expanded(
                          child: _isLoading
                              ? const Center(
                                  child: CircularProgressIndicator(
                                      color: Colors.white))
                              : displayList.isEmpty
                                  ? const Center(
                                      child: Text("لا توجد بيانات",
                                          style: TextStyle(
                                              color: Colors.white38,
                                              fontFamily: 'Cairo',
                                              fontSize: 14)))
                                  : ListView.builder(
                                      padding: const EdgeInsets.only(
                                          bottom: 20, left: 5, right: 5),
                                      itemCount: displayList.length,
                                      itemBuilder: (context, index) =>
                                          _buildDataRow(displayList[index]),
                                    ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDateFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _datePickerBtn("من", _fromDate, (d) {
                setState(() => _fromDate = d!);
                _fetchData();
              }),
              const Icon(Icons.arrow_forward_ios,
                  color: Colors.white24, size: 10),
              _datePickerBtn("إلى", _toDate, (d) {
                setState(() => _toDate = d!);
                _fetchData();
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _datePickerBtn(
      String label, DateTime date, Function(DateTime?) onPick) {
    return InkWell(
      onTap: () async {
        DateTime? p = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(2020),
          lastDate: DateTime(2101),
        );
        if (p != null) onPick(p);
      },
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white60, fontSize: 10, fontFamily: 'Cairo')),
          Text(DateFormat('yyyy-MM-dd').format(date),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
          color: Colors.white10, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: const [
          Expanded(
              flex: 2,
              child: Text("المبلغ",
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
          Expanded(
              flex: 3,
              child: Text("البيان",
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
          Expanded(
              flex: 2,
              child: Text("التصنيف",
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
          Expanded(
              flex: 2,
              child: Text("التاريخ",
                  style: TextStyle(
                      color: Colors.cyan,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  Widget _buildDataRow(Map<String, dynamic> item) {
    return InkWell(
      onTap: () => _showOptionsModal(item),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        // 🌟 قمنا بتغيير الابن الأساسي إلى Column ليستوعب السطر الجديد
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1️⃣ السطر الأول: بيانات الحركة القديمة (شغالة تمام وملمسناش فيها أي حاجة)
            Row(
              children: [
                Expanded(
                    flex: 2,
                    child: Text("${item['amount'] ?? 0.0}",
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600))),
                Expanded(
                    flex: 3,
                    child: Text("${item['statement'] ?? ''}",
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontFamily: 'Cairo'),
                        overflow: TextOverflow.ellipsis)),
                Expanded(
                    flex: 2,
                    child: Text("${item['category'] ?? ''}",
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontFamily: 'Cairo'),
                        overflow: TextOverflow.ellipsis)),
                Expanded(
                    flex: 2,
                    child: Text("${item['date'] ?? ''}",
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 10))),
              ],
            ),

            const SizedBox(height: 6), // مسافة صغيرة جداً بين السطرين

            // 2️⃣ السطر الثاني الجديد: عرض الفرع والموظف بشكل متناسق أسفل البيانات
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // عرض اسم الفرع مع أيقونة متجر صغيرة
                Row(
                  children: [
                    const Icon(Icons.store_rounded,
                        color: Colors.cyan, size: 12),
                    const SizedBox(width: 4),
                    Text(
  "الفرع: ${_getBranchName(item['branch_code']?.toString())}", // 🌟 التعديل هنا
  style: const TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'Cairo'),
),
                  ],
                ),
                // عرض اسم الموظف مع أيقونة مستخدم صغيرة
                Row(
                  children: [
                    const Icon(Icons.person_rounded,
                        color: Colors.amber, size: 12),
                    const SizedBox(width: 4),
                    Text(
                      "الموظف: ${item['employee'] ?? 'غير معروف'}",
                      style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 9,
                          fontFamily: 'Cairo'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _editTransaction(Map<String, dynamic> item) async {
    // 🌟 منع التعديل لحركات التحويل المزدوجة لحماية الأرصدة
    if (item['category'] == 'تحويل خزائن') {
      _showSnackBar("لا يمكن تعديل إذن التحويل المزدوج! الرجاء حذفه وإنشاء تحويل جديد.", Colors.orange);
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DailyPage(
          companyCode: widget.companyCode,
          editItem: item,
          userName: widget.userName, 
          selectedBranchCode: item['branch_code']?.toString() ?? widget.selectedBranchCode,
        ),
      ),
    );
    _fetchData();
  }

  void _showOptionsModal(Map<String, dynamic> item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.indigo.shade900,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(15))),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.orange, size: 20),
            title: const Text("تعديل الإذن",
                style: TextStyle(
                    color: Colors.white, fontFamily: 'Cairo', fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              _editTransaction(item);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red, size: 20),
            title: const Text("حذف الإذن",
                style: TextStyle(
                    color: Colors.white, fontFamily: 'Cairo', fontSize: 14)),
            onTap: () {
              Navigator.pop(context);
              _confirmDelete(item);
            },
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  void _confirmDelete(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.indigo.shade900,
        title: const Text("تأكيد الحذف", style: TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 15)),
        content: Text(
          item['category'] == 'تحويل خزائن' 
              ? "هل أنت متأكد من حذف هذا التحويل؟\n(سيقوم النظام آلياً بحذف حركة الصادر والوارد معاً لضبط الأرصدة)" 
              : "حذف إذن رقم ${item['serial']}؟", 
          style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                // 1. حذف الإذن الأساسي الذي ضغط عليه المستخدم
                await _dailyService.deleteTransaction(
                    widget.companyCode, item['serial'] ?? 0, item['branch_code']?.toString() ?? "1"); 
                
                // 2. 🌟 البحث الذكي عن الحركة التوأم (المقابلة) وحذفها آلياً
                if (item['category'] == 'تحويل خزائن') {
                  int counterpartSerial = -1;
                  String counterpartBranch = item['branch_code']?.toString() ?? "1";
                  double targetAmount = double.tryParse(item['amount'].toString()) ?? 0.0;
                  
                  final box = Hive.box('daily_transactions_box');
                  for (var val in box.values) {
                    if (val is Map && 
                        val['company_code'] == widget.companyCode && 
                        val['category'] == 'تحويل خزائن' && 
                        val['date'] == item['date'] && 
                        val['type'] != item['type'] && // نوع عكسي (لو صادر يبحث عن الوارد)
                        (double.tryParse(val['amount'].toString()) ?? 0.0) == targetAmount) {
                          
                      counterpartSerial = val['serial'] ?? -1;
                      counterpartBranch = val['branch_code']?.toString() ?? counterpartBranch;
                      break; // وجدنا الحركة التوأم!
                    }
                  }
                  
                  // إذا وجدنا التوأم، نحذفه فوراً من الفايربيز أيضاً
                  if (counterpartSerial != -1) {
                    await _dailyService.deleteTransaction(
                        widget.companyCode, counterpartSerial, counterpartBranch);
                  }
                }

                if (mounted) {
                  Navigator.pop(context); 
                  _showSnackBar(
                    item['category'] == 'تحويل خزائن' 
                        ? "تم حذف حركتي التحويل (الصادر والوارد) بنجاح لضبط ميزان الخزائن"
                        : "تم حذف الإذن بنجاح وتحديث الأرصدة محلياً", 
                    Colors.green
                  );
                  _fetchData(); 
                }
              } catch (e) {
                if (mounted) {
                  Navigator.pop(context); 
                  _showSnackBar("فشل الحذف: ${e.toString()}", Colors.red); 
                }
              }
            },
            child: const Text("حذف", style: TextStyle(color: Colors.redAccent, fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String m, Color c) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(m,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
          backgroundColor: c));
}
