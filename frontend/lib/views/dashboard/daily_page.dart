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
    
    // 🌟 السحر هنا: عند الكتابة في خانة المبلغ، يتم إعادة بناء الواجهة لتحديث الأرصدة لحظياً في كل الكروت (تم الحفاظ عليها بالكامل)
    _amountController.addListener(() => setState(() {}));
    _loadInitialData();

    if (widget.editItem != null) {
      _amountController.text = widget.editItem!['amount']?.toString() ?? '';
      _statementController.text = widget.editItem!['statement'] ?? "";
      
      // 🎯 تأمين التاريخ: استخراج أول 10 حروف فقط (yyyy-MM-dd) لتفادي أي أخطاء في الـ DatePicker بسبب الطوابع الزمنية الكاملة
      if (widget.editItem!['date'] != null) {
        String rawDate = widget.editItem!['date'].toString();
        _dateController.text = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
      } else {
        _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
      }

      // 🌟 تم الحفاظ على المتغير الخاص بك لتحديد السيريال الحالي للحركة أثناء التعديل
      _currentSerial = widget.editItem!['serial'] ?? 1;
      _selectedTreasury = widget.editItem!['treasury'];
      _selectedCategory = widget.editItem!['category'];
    } else {
      // في حالة الإضافة الجديدة: تنظيف الحقول وتعيين تاريخ اليوم
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
      // 1. جلب السيريال من الـ Hive (سريع جداً)
      final Box dailyBox = Hive.box('daily_transactions_box');
      int maxSerial = 0;
      for (var item in dailyBox.values) {
        if (item is Map && item['company_code'] == widget.companyCode) {
          if (widget.selectedBranch == null || widget.selectedBranch == "كل الفروع" || item['branch'] == widget.selectedBranch) {
            int currentSerial = int.tryParse(item['serial']?.toString() ?? '0') ?? 0;
            if (currentSerial > maxSerial) maxSerial = currentSerial;
          }
        }
      }
      int nextSerial = maxSerial + 1;

      // 2. جلب الأرصدة من الـ Hive
      final summary = await _dailyService.getDailySummaryLocal(widget.companyCode, branch: widget.selectedBranch);
      Hive.box('daily_transactions_box').put("${widget.companyCode}_balances", summary['balances']);
      
      // 🌟 3. الحل الذكي للتكويدات (الخزائن والتصنيفات)
      final Box codingBox = Hive.box('coding_box');
      List<Map<String, dynamic>> safesList = [];
      List<Map<String, dynamic>> typesList = [];

      // الفحص: هل الـ Hive فارغ من التكويدات؟ (حالة أول تشغيل)
      if (!codingBox.containsKey("${widget.companyCode}_safes") || !codingBox.containsKey("${widget.companyCode}_types")) {
        print("📥 أول تشغيل لليومية: جاري تحميل التكويدات من السيرفر...");
        // جلب البيانات من السيرفر (ستقوم الـ Service بحفظها تلقائياً في الـ Hive للمرات القادمة)
        final safes = await _codingService.getCodingList(companyCode: widget.companyCode, category: "safes");
        final types = await _codingService.getCodingList(companyCode: widget.companyCode, category: "types");
        
        safesList = safes.map((e) => Map<String, dynamic>.from(e.toMap())).toList();
        typesList = types.map((e) => Map<String, dynamic>.from(e.toMap())).toList();
      } else {
        // 🔥 حالة الاستخدام العادية: الـ Hive ممتلئ، قراءة فورية بدون إنترنت
        var localSafes = codingBox.get("${widget.companyCode}_safes");
        safesList = (localSafes as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

        var localTypes = codingBox.get("${widget.companyCode}_types");
        typesList = (localTypes as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }

      setState(() {
        _treasuryBalances = Map<String, double>.from(summary['balances'] ?? {});
        _treasuries = safesList;
        _categories = typesList;

        if (widget.editItem == null) _currentSerial = nextSerial;

        if (widget.editItem == null && _selectedTreasury == null && _treasuries.isNotEmpty) {
          var defaultSafe = _treasuries.firstWhere((s) => s['code']?.toString() == "1", orElse: () => _treasuries.first);
          if (defaultSafe.containsKey('name')) _selectedTreasury = defaultSafe['name'];
        }
        
        _isLoading = false;
      });
      
    } catch (e) {
      setState(() => _isLoading = false);
      print("خطأ في جلب البيانات الافتتاحية: $e");
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

    // 🌟 السحر هنا: تغليف الصفحة بـ PopScope للتحكم في زر وإيماءة الرجوع الخاصة بالهاتف
    return PopScope(
      canPop: false, // تعطيل الخروج التلقائي المفاجئ
      onPopInvoked: (didPop) async {
        if (didPop) return; // إذا تم الرجوع بالفعل لا تفعل شيء
        
        if (context.mounted) {
          Navigator.pop(context); // 🌟 تنفيذ نفس أمر الرجوع المعتمد داخل البرنامج
        }
      },
      child: Scaffold(
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
              // 🌟 عرض اسم الفرع الحالي النشط أسفل رقم الإذن
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
          
          // 🌟 إضافة زر الاستيراد هنا في أعلى اليسار بشكل احترافي ومتناسق
          actions: [
            if (!isEditMode) // يظهر فقط في حالة تسجيل حركة جديدة وليس التعديل
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                child: Tooltip(
                  message: "استيراد من إكسيل",
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15), // خلفية زجاجية خفيفة
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.greenAccent.withOpacity(0.4)), // حواف خضراء متناسقة
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.upload_file, color: Colors.greenAccent, size: 22),
                      onPressed: _importFromExcel,
                    ),
                  ),
                ),
              ),
          ],
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
                    (val) {
                      setState(() {
                        _selectedCategory = val;
                        
                        if (val == "فيزا") {
                          // 1️⃣ إذا تم اختيار "فيزا"، نغير الخزينة إلى فيزا (كود 2) تلقائياً
                          var visaTreasury = _treasuries.firstWhere(
                            (t) => t['code']?.toString() == "2",
                            orElse: () => {}
                          );
                          
                          if (visaTreasury.isNotEmpty && visaTreasury.containsKey('name')) {
                            _selectedTreasury = visaTreasury['name'];
                          }
                        } else {
                          // 2️⃣ 🌟 التعديل الجديد: إذا تم اختيار أي تصنيف آخر، تعود الخزينة نقدي (كود 1) تلقائياً
                          var cashTreasury = _treasuries.firstWhere(
                            (t) => t['code']?.toString() == "1",
                            orElse: () => {}
                          );
                          
                          if (cashTreasury.isNotEmpty && cashTreasury.containsKey('name')) {
                            _selectedTreasury = cashTreasury['name'];
                          }
                        }
                      });
                    }),
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
    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isEdit ? Colors.orange.withOpacity(0.3) : Colors.white.withOpacity(0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          side: BorderSide(color: isEdit ? Colors.orangeAccent : Colors.white24),
        ),
        onPressed: _handleSave,
        child: Text(
          isEdit ? "تعديل الإذن" : "حفظ", 
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
        ),
      ),
    );
  }

  void _handleSave() async {
    // 1. التحقق المبدئي من الحقول الأساسية لضمان عدم إرسال بيانات فارغة
    if (_amountController.text.isEmpty || _selectedTreasury == null || _selectedCategory == null) {
      _showSnackBar("برجاء إكمال البيانات", Colors.orange);
      return;
    }

    // 🌟 حماية المدخلات: تحويل آمن للمبلغ لمنع الـ FormatException في حالة الأخطاء الإملائية
    final double? parsedAmount = double.tryParse(_amountController.text.trim());
    if (parsedAmount == null || parsedAmount <= 0) {
      _showSnackBar("برجاء إدخال مبلغ صحيح أكبر من الصفر", Colors.orange);
      return;
    }

    setState(() => _isLoading = true);

    try {
      var matchingCategory = _categories.firstWhere((c) => c['name'] == _selectedCategory, orElse: () => {});
      String currentType = matchingCategory.isNotEmpty ? (matchingCategory['type'] ?? "وارد") : "وارد";

      // 🎯 آلية السيريال الذكية لمنع التداخل: 0 للإضافة الجديدة (ليقوم الفايربيز بتوليده سحابياً)، والسيريال الأصلي للتعديل
      int serialToSend = widget.editItem != null ? widget.editItem!['serial'] : 0;
      
      String targetBranch = widget.editItem != null 
          ? (widget.editItem!['branch'] ?? "الفرع الرئيسي") 
          : (widget.selectedBranch ?? "الفرع الرئيسي");

      // استدعاء خدمة الحفظ والمزامنة الموحدة
      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: serialToSend,
        treasury: _selectedTreasury!,
        amount: parsedAmount, // تمرير الرقم الآمن المحمي من الانهيار
        statement: _statementController.text,
        category: _selectedCategory!,
        date: _dateController.text,
        type: currentType,
        branch: targetBranch,
        employee: widget.userName ?? "غير معروف",
      );

      if (mounted) {
        if (widget.editItem != null) {
          Navigator.pop(context, true);
        } else {
          _showSnackBar("تم الحفظ بنجاح وتحديث الذاكرة المحلية والشبكية التراكمية", Colors.green);
          _amountController.clear();
          _statementController.clear();
          _loadInitialData(); // إعادة جلب الأرصدة التراكمية المحدثة فوراً
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar("خطأ: $e", Colors.red);
      }
    } finally {
      // 🌟 تأمين الواجهة: إيقاف مؤشر التحميل دائماً سواءً نجحت العملية أو فشلت لإتاحة المحاولة مجدداً
      if (mounted) {
        setState(() => _isLoading = false);
      }
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
    label: const Text("المعاينة", style: TextStyle(color: Colors.cyanAccent, fontFamily: 'Cairo')),
  );
}

  Future<void> _pickDate() async {
    DateTime? p = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2101));
    if (p != null) setState(() => _dateController.text = DateFormat('yyyy-MM-dd').format(p));
  }

  void _importFromExcel() async {
    // 1️⃣ إظهار رسالة منبثقة تنبيهية للتأكد من هيكلة ملف الإكسيل قبل الاختيار
    bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          "تنبيه قبل الاستيراد", 
          style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
          textAlign: TextAlign.right,
        ),
        content: const Text(
          "يرجى التأكد من احتواء ملف الإكسيل على الأعمدة التالية في الصف الأول بأي ترتيب:\n"
          " 🌟 ( المبلغ  -  البيان  -  التصنيف  -  التاريخ )\n\n"
          "💡 النظام ذكي بما يكفي لتجاهل أي أعمدة إضافية أخرى بالملف والتعرف التلقائي على الحقول المطلوبة.",
          style: TextStyle(fontFamily: 'Cairo', fontSize: 14),
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("إلغاء", style: TextStyle(fontFamily: 'Cairo', color: Colors.red)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade900),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("موافق واختيار الملف", style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );

    if (proceed != true) return;

    // 2️⃣ فتح مستعرض الملفات لاختيار ملف الـ Excel
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom, 
      allowedExtensions: ['xlsx'], 
      withData: true
    );

    if (result != null) {
      setState(() => _isLoading = true);
      try {
        var bytes = result.files.single.bytes;
        if (bytes == null && result.files.single.path != null) {
          bytes = File(result.files.single.path!).readAsBytesSync();
        }
        if (bytes == null) throw "تعذر قراءة بيانات الملف";

        var excel = excel_lib.Excel.decodeBytes(bytes);

        // جلب المسميات الفعلية للخزائن من القائمة بناءً على الأكواد المحددة لنضمن مرونة المسميات
        String cashTreasuryName = "الخزينة الرئيسية"; 
        String visaTreasuryName = "فيزا"; 

        var cashTreasuryObj = _treasuries.firstWhere(
          (t) => t['code']?.toString() == "1",
          orElse: () => {}
        );
        if (cashTreasuryObj.isNotEmpty && cashTreasuryObj.containsKey('name')) {
          cashTreasuryName = cashTreasuryObj['name'];
        }

        var visaTreasuryObj = _treasuries.firstWhere(
          (t) => t['code']?.toString() == "2",
          orElse: () => {}
        );
        if (visaTreasuryObj.isNotEmpty && visaTreasuryObj.containsKey('name')) {
          visaTreasuryName = visaTreasuryObj['name'];
        }

        for (var table in excel.tables.keys) {
          var rows = excel.tables[table]!.rows;
          if (rows.isEmpty) continue;

          // 🌟 [الترقية السحرية]: البحث عن فهارس الأعمدة ديناميكياً من الصف الأول
          int amountIdx = -1;
          int statementIdx = -1;
          int categoryIdx = -1;
          int dateIdx = -1;

          var headerRow = rows[0];
          for (int col = 0; col < headerRow.length; col++) {
            String headerVal = headerRow[col]?.value?.toString().trim() ?? "";
            if (headerVal == "المبلغ") amountIdx = col;
            if (headerVal == "البيان") statementIdx = col;
            if (headerVal == "التصنيف") categoryIdx = col;
            if (headerVal == "التاريخ") dateIdx = col;
          }

          // إذا لم يتم العثور على الأعمدة الأساسية نطلق تنبيهاً للمستخدم
          if (amountIdx == -1 || statementIdx == -1 || categoryIdx == -1 || dateIdx == -1) {
            throw "الملف لا يحتوي على الأعمدة الأساسية المطلوبة: (المبلغ، البيان، التصنيف، التاريخ). يرجى مراجعة عناوين الأعمدة بالصف الأول.";
          }

          // نبدأ من i = 1 لتخطي صف العناوين الرئيسي والبدء بالبيانات الفعلية
          for (int i = 1; i < rows.length; i++) {
            var row = rows[i];
            
            // جدار حماية: إذا كان السطر فارغاً أو خانة المبلغ خارج النطاق أو فارغة يتم تخطي السطر فوراً
            if (row.isEmpty || amountIdx >= row.length || row[amountIdx] == null || row[amountIdx]?.value == null) continue;

            // 1. قراءة المبلغ والتأكد من أنه رقم صالح وغير صفري بناءً على الفهرس الديناميكي
            double amount = double.tryParse(row[amountIdx]!.value.toString().trim()) ?? 0.0;
            if (amount == 0.0) continue; 

            // 2. قراءة البيان بأمان
            String statement = (statementIdx < row.length && row[statementIdx] != null && row[statementIdx]?.value != null) 
                ? row[statementIdx]!.value.toString().trim() 
                : "";

            // 3. قراءة التصنيف بأمان
            String categoryStr = (categoryIdx < row.length && row[categoryIdx] != null && row[categoryIdx]?.value != null) 
                ? row[categoryIdx]!.value.toString().trim() 
                : "عام";

            // 4. قراءة التاريخ وتنسيقه بأمان
            String rawDate = (dateIdx < row.length && row[dateIdx] != null && row[dateIdx]?.value != null) 
                ? row[dateIdx]!.value.toString().trim() 
                : DateFormat('yyyy-MM-dd').format(DateTime.now());
            String formattedDate = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
            
            // تحديد نوع الحركة (وارد / صادر) بناءً على جدول التصنيفات الفعلي بالبرنامج
            var match = _categories.firstWhere((c) => c['name']?.toString().trim() == categoryStr, orElse: () => {});
            String calculatedType = match.isNotEmpty ? (match['type'] ?? "وارد") : "وارد";

            // تحديد الخزينة ذكياً بناءً على اسم التصنيف
            String targetTreasury = cashTreasuryName; // الافتراضي نقدي (كود 1)
            if (categoryStr == "فيزا") {
              targetTreasury = visaTreasuryName; // فيزا (كود 2)
            }

            // حفظ الحركة كإذن منفصل ومكتمل البيانات التابعة للنظام
            await _dailyService.saveTransaction(
              companyCode: widget.companyCode,
              serial: 0, 
              treasury: targetTreasury,
              amount: amount,
              statement: statement,
              category: categoryStr,
              date: formattedDate,
              type: calculatedType,
              branch: widget.selectedBranch ?? "الفرع الرئيسي", 
              employee: widget.userName ?? "غير معروف", 
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