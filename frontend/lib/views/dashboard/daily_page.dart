import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart';
import '../../services/coding_service.dart'; 
import 'daily_history_page.dart';
import 'package:hive_flutter/hive_flutter.dart';

class DailyPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranch; 
  final String? userName; // 🌟 هذا هو السطر الجديد الذي أضفناه لاستقبال اسم الموظف
  final Map<String, dynamic>? editItem; 

  // 🌟 هنا قمنا بتحديث الـ Constructor ليتعرف على المتغير الجديد
  const DailyPage({
    super.key, 
    required this.companyCode, 
    this.selectedBranch, 
    this.userName, // 👈 أضفنا هذا السطر هنا
    this.editItem,
  });

  @override
  State<DailyPage> createState() => _DailyPageState();
}

class _DailyPageState extends State<DailyPage> {
  final DailyService _dailyService = DailyService();
  final CodingService _codingService = CodingService(); 

  final _amountController = TextEditingController();
  final _statementController = TextEditingController();
  final _dateController = TextEditingController();

  bool _isLoading = false;
  
  // خريطة لتخزين الأرصدة التراكمية الفعلية لكل خزينة قادمة من الـ Hive
  Map<String, double> _treasuryBalances = {};
  
  int _currentSerial = 1;
  String? _selectedTreasury;
  String? _selectedCategory;

  List<Map<String, dynamic>> _treasuries = [];
  List<Map<String, dynamic>> _categories = [];

  @override
  void initState() {
    super.initState();
    // 🌟 السحر هنا: عند الكتابة في خانة المبلغ، يتم إعادة بناء الواجهة لتحديث الأرصدة لحظياً في كل الكروت
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
      _amountController.clear();
      _statementController.clear();
      _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    }
  }

  // 🌟 دالة ذكية جديدة تماماً لحساب الرصيد اللحظي لأي خزينة نمررها لها أثناء الكتابة
  double _getLiveBalanceForTreasury(String treasuryName) {
  double currentBaseBalance = _treasuryBalances[treasuryName] ?? 0.0;
  
  // إذا كانت الخزينة الحالية هي الخزينة المختارة في الـ Dropdown
  if (_selectedTreasury == treasuryName && _selectedCategory != null) {
    double enteredAmount = double.tryParse(_amountController.text) ?? 0.0;

    // 🌟 السحر هنا: لو احنا في وضع التعديل، لازم نطرح قيمة المبلغ القديم الأصلي للإذن أولاً
    if (widget.editItem != null && widget.editItem!['treasury'] == treasuryName) {
      double originalAmount = double.tryParse(widget.editItem!['amount'].toString()) ?? 0.0;
      
      // جلب تفاصيل التصنيف الأصلي للإذن القديم لمعرفة هل كان مضاف أم مخصوم لنعكس تأثيره القديم
      String originalType = widget.editItem!['type'] ?? "وارد";
      if (originalType == "وارد") {
        currentBaseBalance -= originalAmount; // نطرحه لأنه كان مضافاً
      } else if (originalType == "صادر") {
        currentBaseBalance += originalAmount; // نرده لأنه كان مخصوماً
      }
    }

    // الآن نؤثر بالمبلغ الجديد المكتوب في الـ Controller بناءً على التصنيف الحالي
    var matchingCategory = _categories.firstWhere(
      (c) => c['name'] == _selectedCategory,
      orElse: () => {}
    );
    
    if (matchingCategory.isNotEmpty) {
      String actionType = matchingCategory['type'] ?? "وارد"; 
      if (actionType == "وارد") {
        return currentBaseBalance + enteredAmount;
      } else if (actionType == "صادر") {
        return currentBaseBalance - enteredAmount;
      }
    }
  }
  return currentBaseBalance;
}

  void _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      // 1️⃣ جلب حركات الفرع الحالي من السيرفر وتخزينها في متغير مؤقت
      final List<dynamic> transactions = await _dailyService.getTransactionsHistory(
        widget.companyCode,
        DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 3))),
        DateFormat('yyyy-MM-dd').format(DateTime.now()),
        branch: widget.selectedBranch,
      );

      // 2️⃣ جلب الأرصدة والملخص
      final summary = await _dailyService.getDailySummaryLocal(
        widget.companyCode, 
        branch: widget.selectedBranch,
      );
      
      // 🌟 السطر السحري: إجبار الـ Hive على التحديث لكي تظهر الأرصدة فوراً في الواجهة
      Hive.box('daily_transactions_box').put("${widget.companyCode}_balances", summary['balances']);
      
      final safes = await _codingService.getCodingList(companyCode: widget.companyCode, category: "safes");
      final types = await _codingService.getCodingList(companyCode: widget.companyCode, category: "types");

      // 3️⃣ 🌟 حساب السيريال المباشر من قائمة الحركات اللي لسه جايبينها (أضمن طريقة)
      int nextSerial = 1;
      if (transactions.isNotEmpty) {
        // بنشوف أكبر رقم سيريال موجود في الحركات اللي رجعت من السيرفر ونزود عليه 1
        int maxSerial = transactions.map((e) => (e['serial'] as int? ?? 0)).reduce((a, b) => a > b ? a : b);
        nextSerial = maxSerial + 1;
      }

      setState(() {
        _treasuryBalances = Map<String, double>.from(summary['balances'] ?? {});
        _treasuries = safes.map((e) => Map<String, dynamic>.from(e.toMap())).toList();
        _categories = types.map((e) => Map<String, dynamic>.from(e.toMap())).toList();

        // تعيين السيريال المحسوب مباشرة
        if (widget.editItem == null) {
          _currentSerial = nextSerial;
        }

        // 🌟 التعديل الآمن (Bulletproof) لاختيار الخزنة رقم 1 بدون أخطاء
        // 🌟 التعديل الآمن (Bulletproof) لاختيار الخزنة رقم 1 بدون أخطاء
        if (widget.editItem == null && _selectedTreasury == null && _treasuries.isNotEmpty) {
          var defaultSafe = _treasuries.firstWhere(
            (s) => s['code'] != null && s['code'].toString() == "1",
            orElse: () => _treasuries.first
          );
          
          if (defaultSafe.containsKey('name')) { // 👈 تم إزالة التحذير هنا
            _selectedTreasury = defaultSafe['name'];
          }
        }
        
        _isLoading = false;
      });
      
    } catch (e) {
      setState(() => _isLoading = false);
      print("خطأ في مزامنة البيانات الافتتاحية للفرع: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isEditMode = widget.editItem != null;
    
    // جلب عرض الشاشة الحالي لتحديد نوع الجهاز
    double screenWidth = MediaQuery.of(context).size.width;
    bool isWebOrDesktop = screenWidth > 600;

    // 🌟 استدعاء صندوق الـ Hive المفتوح في الماين لكي نراقب التحديثات من خلاله
    final Box dailyBox = Hive.box('daily_transactions_box');

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min, // للحفاظ على تماسك العناصر داخل الـ Column
          children: [
            Text(
              isEditMode ? "تعديل حركة" : "تسجيل يومية",
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 15),
            ),
            Text(
              "إذن رقم: $_currentSerial",
              style: const TextStyle(
                fontFamily: 'Cairo', 
                fontSize: 13, 
                color: Colors.cyanAccent, 
                fontWeight: FontWeight.bold
              ),
            ),
            // 🌟 الإضافة الجديدة: عرض اسم الفرع الحالي النشط أسفل رقم الإذن
            Text(
              "الفرع: ${widget.selectedBranch ?? 'الرئيسي'}",
              style: const TextStyle(
                fontFamily: 'Cairo', 
                fontSize: 11, 
                color: Colors.white70,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        // 🌟 قمنا بتكبير الارتفاع إلى 70 ليستوعب الأسطر الثلاثة بشكل مريح ومنظم جداً وبدون تداخل
        toolbarHeight: 70, 
      ),
      body: Container(
        height: double.infinity, 
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, Colors.indigo.shade900, Colors.black],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : Center(
                  // 🌟 إذا كان لابتوب، نحدد العرض بـ 650 بكسل كحد أقصى ويتم تركيزه في المنتصف
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: isWebOrDesktop ? 650 : double.infinity,
                    ),
                    child: SingleChildScrollView(
                      // تقليص الحواف والمسافات لتصبح الشاشة مدمجة وصغيرة
                      padding: EdgeInsets.symmetric(
                        horizontal: isWebOrDesktop ? 25 : 15, 
                        vertical: 10
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          
                          // 🌟 تم تعديل هذا الجزء لحماية الأرصدة من التصفير المفاجئ
                          ValueListenableBuilder(
                            valueListenable: dailyBox.listenable(keys: ["${widget.companyCode}_balances"]),
                            builder: (context, Box box, child) {
                              // 1. جلب البيانات الخام من الـ Hive
                              final rawBalances = box.get("${widget.companyCode}_balances");
                              
                              // 2. 🛡️ جدار الحماية: لا نقوم بالتحديث إلا إذا كانت البيانات خريطة (Map) وغير فارغة
                              if (rawBalances is Map && rawBalances.isNotEmpty) {
                                Map<String, double> safeBalances = {};
                                rawBalances.forEach((key, value) {
                                  // تحويل القيمة دائماً إلى double آمن لمنع الـ Crash
                                  safeBalances[key.toString()] = double.tryParse(value.toString()) ?? 0.0;
                                });
                                
                                // 3. تحديث الأرصدة في الصفحة فقط لو كانت البيانات حقيقية
                                _treasuryBalances = safeBalances;
                              }
                              
                              // 4. بناء شبكة الأرصدة بالبيانات الآمنة المستقرة
                              return _buildDynamicBalancesGrid();
                            },
                          ),

                          const SizedBox(height: 12),
                          _buildInputForm(),
                          const SizedBox(height: 15),
                          _buildMainActions(),
                          const SizedBox(height: 8),
                          _buildSecondaryActions(),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  // 🌟 دالة البناء الديناميكية الجديدة لكروت الأرصدة (GridView متجاوب يدعم أي عدد خزائن)
  Widget _buildDynamicBalancesGrid() {
  if (_treasuries.isEmpty) {
    return const SizedBox.shrink();
  }
  
  double screenWidth = MediaQuery.of(context).size.width;
  // 3 أعمدة للابتوب والشاشات الواسعة، وعمودين للموبايل
  int columnsCount = screenWidth > 500 ? 3 : 2;

  return GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columnsCount,
      crossAxisSpacing: 10, // مسافات متناسقة ونظيفة
      mainAxisSpacing: 10,
      // 🌟 تم ضبط النسبة لتوسيع مساحة الكارت رأسياً وأفقياً لراحة النص والارقام
      childAspectRatio: screenWidth > 500 ? 2.4 : 1.7, 
    ),
    itemCount: _treasuries.length,
    itemBuilder: (context, index) {
      String treasuryName = _treasuries[index]['name'] ?? "خزينة غير معرفة";
      double liveBalance = _getLiveBalanceForTreasury(treasuryName);

      return GlassCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: .5, horizontal: 1),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 🌟 1. اسم الخزينة: يأخذ نصف المساحة الرأسية ويدعم الالتفاف لسطرين بدون قص
              Expanded(
                flex: 4,
                child: Center(
                  child: Text(
                    treasuryName, 
                    style: const TextStyle(
                      color: Colors.white, // تم تفتيح اللون لمزيد من الوضوح
                      fontSize: 13, 
                      fontFamily: 'Cairo', 
                      fontWeight: FontWeight.bold,
                      height: 1.2, // تحسين تباعد الأسطر إذا التف النص
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              
              const SizedBox(height: 4), // فاصل مريح
              
              // 🌟 2. الرصيد المالي: يستخدم FittedBox ليتمدد ويكبر ليملأ عرض الكارت المتاح بالكامل
              Expanded(
                flex: 5,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown, // يجعل الرقم يكبر لأقصى مساحة متاحة ويصغر ذكياً فقط لو الشاشة ضيقة جداً
                    child: Text(
                      liveBalance.toStringAsFixed(2), 
                      style: const TextStyle(
                        color: Colors.greenAccent, 
                        fontSize: 16, // خط أساسي كبير وواضح جداً
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
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
                child: _buildDropdown("الخزينة", _selectedTreasury, _treasuries, 
                    (val) => setState(() => _selectedTreasury = val)),
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
            child: Text(isEdit ? "تعديل الإذن " : "حفظ  ", 
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          ),
        ),
        if (!isEdit) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.greenAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              onPressed: _importFromExcel,
              icon: const Icon(Icons.upload_file, color: Colors.greenAccent),
              label: const Text("استيراد من إكسيل", style: TextStyle(color: Colors.greenAccent, fontFamily: 'Cairo')),
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
      var matchingCategory = _categories.firstWhere((c) => c['name'] == _selectedCategory, orElse: () => {});
      String currentType = matchingCategory.isNotEmpty ? (matchingCategory['type'] ?? "وارد") : "وارد";

      int serialToSend = widget.editItem != null ? widget.editItem!['serial'] : 0;
      String targetBranch = widget.editItem != null 
          ? (widget.editItem!['branch'] ?? "الفرع الرئيسي") 
          : (widget.selectedBranch ?? "الفرع الرئيسي");

      // 🌟 التعديل هنا: أضفنا تمرير المتغير employee لكي يُحفظ اسم الموظف الفعلي بدلاً من "غير معروف"
      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: serialToSend,
        treasury: _selectedTreasury!,
        amount: double.parse(_amountController.text),
        statement: _statementController.text,
        category: _selectedCategory!,
        date: _dateController.text,
        type: currentType,
        branch: targetBranch,
        employee: widget.userName ?? "غير معروف", // 👈 هذا هو السطر الجديد
      );

      if (widget.editItem != null) {
        Navigator.pop(context, true);
      } else {
        _showSnackBar("تم الحفظ بنجاح وتحديث الذاكرة المحلية والشبكية التراكمية", Colors.green);
        _amountController.clear();
        _statementController.clear();
        _loadInitialData();
      }
    } catch (e) {
      _showSnackBar("خطأ: $e", Colors.red);
      setState(() => _isLoading = false);
    }
  }

  Widget _buildDropdown(String label, String? value, List<Map<String, dynamic>> items, Function(String?) onChanged) {
    return DropdownButtonFormField<String>(
      value: value,
      dropdownColor: Colors.indigo.shade900,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label, labelStyle: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 12),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
        contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
      ),
      items: items.map((item) {
        return DropdownMenuItem<String>(
          value: item['name']?.toString(), 
          child: Text(item['name']?.toString() ?? "")
        );
      }).toList(),
      onChanged: onChanged,
    );
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

  Widget _buildDatePicker() {
    return TextField(
      controller: _dateController,
      readOnly: true,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.calendar_today, color: Colors.white70),
        labelText: "التاريخ", labelStyle: const TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white10)),
      ),
      onTap: _pickDate,
    );
  }

  Widget _buildSecondaryActions() {
  return TextButton.icon(
    onPressed: () {
      Navigator.push(
        context, 
        MaterialPageRoute(
          builder: (context) => DailyHistoryPage(
            companyCode: widget.companyCode,
            userName: widget.userName,           // 🌟 مررنا اسم الموظف هنا
            selectedBranch: widget.selectedBranch, // 🌟 مررنا الفرع المختار هنا
          ),
        ),
      ).then((value) {
        // بمجرد ما المستخدم يقفل صفحة الهيستوري ويرجع لليومية، السطر ده هيشتغل فوراً
        _loadInitialData(); 
      });
    },
    icon: const Icon(Icons.history, color: Colors.cyanAccent),
    label: const Text("معاينة الحركات", style: TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo')),
  );
}

  Future<void> _pickDate() async {
    DateTime? p = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2101));
    if (p != null) setState(() => _dateController.text = DateFormat('yyyy-MM-dd').format(p));
  }

  void _importFromExcel() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx'], withData: true);
    if (result != null) {
      setState(() => _isLoading = true);
      try {
        var bytes = result.files.single.bytes;
        if (bytes == null && result.files.single.path != null) bytes = File(result.files.single.path!).readAsBytesSync();
        if (bytes == null) throw "تعذر قراءة بيانات الملف";

        var excel = excel_lib.Excel.decodeBytes(bytes);
        String defaultTreasury = _selectedTreasury ?? "الخزينة الرئيسية";

        for (var table in excel.tables.keys) {
          var rows = excel.tables[table]!.rows;
          for (int i = 1; i < rows.length; i++) {
            var row = rows[i];
            if (row.isEmpty || row[0] == null || row[0]?.value == null) continue;

            String rawDate = row.length > 3 ? row[3]!.value.toString() : DateFormat('yyyy-MM-dd').format(DateTime.now());
            String formattedDate = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
            String categoryStr = (row.length > 2 && row[2] != null) ? row[2]!.value.toString() : "عام";
            
            var match = _categories.firstWhere((c) => c['name'] == categoryStr, orElse: () => {});
            String calculatedType = match.isNotEmpty ? (match['type'] ?? "وارد") : "وارد";

            await _dailyService.saveTransaction(
              companyCode: widget.companyCode,
              serial: 0, 
              treasury: defaultTreasury,
              amount: double.tryParse(row[0]!.value.toString()) ?? 0.0,
              statement: (row.length > 1 && row[1] != null) ? row[1]!.value.toString() : "",
              category: categoryStr,
              date: formattedDate,
              type: calculatedType,
              branch: widget.selectedBranch ?? "الفرع الرئيسي",
            );
          }
        }
        _showSnackBar("تم الاستيراد المباشر والمزامنة بنجاح محلياً وسحابياً", Colors.green);
        _loadInitialData(); 
      } catch (e) {
        _showSnackBar("خطأ في الاستيراد: $e", Colors.red);
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showSnackBar(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: c)
  );
}