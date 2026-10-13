import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/daily_service.dart'; // مسار الخدمة التي تحفظ الإذن
// import '../../models/coding_model.dart';

class TreasuryTransferPage extends StatefulWidget {
  final String companyCode;
  final String? userName;
  final String? selectedBranchCode;

  const TreasuryTransferPage({
    super.key,
    required this.companyCode,
    this.userName,
    this.selectedBranchCode,
  });

  @override
  State<TreasuryTransferPage> createState() => _TreasuryTransferPageState();
}

class _TreasuryTransferPageState extends State<TreasuryTransferPage> {
  final DailyService _dailyService = DailyService();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _statementController = TextEditingController();

  List<String> _treasuriesList = ["الرئيسية"];
  String _fromTreasury = "الرئيسية";
  String _toTreasury = "الرئيسية";
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadTreasuriesLocally();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _statementController.dispose();
    super.dispose();
  }

  // 🌟 قراءة الخزائن من الـ Hive محلياً بمرونة عالية تناسب أي هيكل بيانات
  // 🌟 قراءة الخزائن من الـ Hive محلياً بنفس الطريقة المطابقة لصفحة اليومية
  void _loadTreasuriesLocally() {
    try {
      final box = Hive.box('coding_box');
      List<String> activeTreasuries = [];

      // 1. استخدام المفتاح الدقيق الذي تستخدمه صفحة اليومية لجلب الخزائن
      String safesKey = "${widget.companyCode}_safes";
      
      if (box.containsKey(safesKey)) {
        var localSafes = box.get(safesKey);
        
        if (localSafes is List) {
          for (var safe in localSafes) {
            // استخراج اسم الخزينة من الماب
            if (safe is Map && safe.containsKey('name') && safe['name'] != null) {
              String safeName = safe['name'].toString().trim();
              if (safeName.isNotEmpty) {
                activeTreasuries.add(safeName);
              }
            }
          }
        }
      }

      if (activeTreasuries.isNotEmpty) {
        setState(() {
          _treasuriesList = activeTreasuries.toSet().toList(); // إزالة التكرار إن وجد
          _fromTreasury = _treasuriesList.first;
          
          // اختيار الخزينة الثانية كقيمة افتراضية لـ (إلى) لو كان فيه أكتر من خزينة
          _toTreasury = _treasuriesList.length > 1 ? _treasuriesList[1] : _treasuriesList.first;
        });
      } else {
        // في حالة عدم العثور عليها نهائياً
        setState(() {
          _treasuriesList = ["لا توجد خزائن متكودة"];
          _fromTreasury = "لا توجد خزائن متكودة";
          _toTreasury = "لا توجد خزائن متكودة";
        });
      }
    } catch (e) {
      debugPrint("خطأ في قراءة الخزائن محلياً: $e");
    }
  }

  Future<void> _executeTransfer() async {
    final double amount = double.tryParse(_amountController.text) ?? 0.0;
    
    if (amount <= 0) {
      _showSnackBar("الرجاء إدخال مبلغ صحيح أكبر من الصفر", AppTheme.warningOrangeFor(context));
      return;
    }
    if (_fromTreasury == _toTreasury) {
      _showSnackBar("لا يمكن التحويل لنفس الخزينة!", AppTheme.warningOrangeFor(context));
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 🌟 1. تعديل الفرع ليتطابق مع طريقتك في صفحة اليومية
      String branch = widget.selectedBranchCode ?? "all"; 
      
      // 🌟 2. تعديل التاريخ ليكون (يوم-شهر-سنة) فقط بدون وقت لتنجح الفلترة في صفحة المعاينة
      String date = DateFormat('yyyy-MM-dd').format(DateTime.now()); 
      
      String statement = _statementController.text.trim().isEmpty 
          ? "تحويل مالي بين الخزائن" 
          : _statementController.text.trim();

      // حركة الصادر (خصم من الخزينة الأولى)
      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: 0,
        treasury: _fromTreasury,
        amount: amount,
        statement: "$statement (إلى $_toTreasury)",
        category: "تحويل خزائن", // 🌟 3. اسم تصنيف مقروء واحترافي
        date: date,
        type: "صادر", // خصم
        branchCode: branch, // 🌟 تم التعديل إلى branchCode
        employee: widget.userName ?? "غير معروف",
      );

      // تأخير بسيط لمنع تداخل السيريالات
      await Future.delayed(const Duration(milliseconds: 500));

      // حركة الوارد (إضافة للخزينة الثانية)
      await _dailyService.saveTransaction(
        companyCode: widget.companyCode,
        serial: 0,
        treasury: _toTreasury,
        amount: amount,
        statement: "$statement (من $_fromTreasury)",
        category: "تحويل خزائن", // 🌟 نفس التصنيف
        date: date,
        type: "وارد", // إضافة
        branchCode: branch, // 🌟 تم التعديل إلى branchCode
        employee: widget.userName ?? "غير معروف",
      );

      if (mounted) {
        setState(() {
          _isLoading = false;
          _amountController.clear();
          _statementController.clear();
        });
        _showSnackBar("تم التحويل بنجاح!", AppTheme.successStrongFor(context));
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar("حدث خطأ أثناء التحويل: $e", AppTheme.dangerStrongFor(context));
      }
    }
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("تحويل بين الخزائن", style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: AppTheme.appBarBgTint,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientBlue(context),
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sync_alt, color: AppTheme.accentFor(context), size: 50),
                        const SizedBox(height: 15),
                        Text(
                          "تحويل مالي داخلي",
                          style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
                        ),
                        const SizedBox(height: 25),

                        // من خزينة
                        _buildDropdownField(context, "تحويل مـن", _fromTreasury, (val) {
                          setState(() => _fromTreasury = val!);
                        }),
                        const SizedBox(height: 15),

                        // إلى خزينة
                        _buildDropdownField(context, "تحويل إلـى", _toTreasury, (val) {
                          setState(() => _toTreasury = val!);
                        }),
                        const SizedBox(height: 15),

                        // المبلغ
                        _buildTextField(
                          context: context,
                          controller: _amountController,
                          label: "المبلغ المحول",
                          icon: Icons.monetization_on_outlined,
                          isNumber: true,
                        ),
                        const SizedBox(height: 15),

                        // البيان
                        _buildTextField(
                          context: context,
                          controller: _statementController,
                          label: "البيان / ملاحظات",
                          icon: Icons.edit_note,
                        ),
                        const SizedBox(height: 30),

                        // زر التنفيذ
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.successDeepFor(context),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                            ),
                            onPressed: _isLoading ? null : _executeTransfer,
                            child: _isLoading
                                ? CircularProgressIndicator(color: Theme.of(context).colorScheme.onPrimary)
                                : Text(
                                    "تنفيذ التحويل",
                                    style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== دوال بناء الحقول ====================
  Widget _buildDropdownField(BuildContext context, String label, String value, void Function(String?) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppTheme.accentFor(context), fontSize: 12, fontFamily: 'Cairo')),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: GlassStyle.fill05For(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: GlassStyle.line20For(context)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _treasuriesList.contains(value) ? value : null,
              dropdownColor: AppTheme.dropdownBackground(context),
              isExpanded: true,
              style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo', fontSize: 14),
              icon: Icon(Icons.arrow_drop_down, color: AppTheme.textSoftFor(context)),
              items: _treasuriesList.map((String t) {
                return DropdownMenuItem(value: t, child: Text(t));
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({required BuildContext context, required TextEditingController controller, required String label, required IconData icon, bool isNumber = false}) {
    return TextField(
      controller: controller,
      keyboardType: isNumber ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo'),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppTheme.textHintFor(context), fontFamily: 'Cairo', fontSize: 12),
        prefixIcon: Icon(icon, color: AppTheme.accentFor(context), size: 20),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GlassStyle.line20For(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppTheme.accentFor(context)),
        ),
      ),
    );
  }
}