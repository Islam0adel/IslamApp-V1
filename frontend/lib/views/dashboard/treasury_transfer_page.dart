import '../../services/cache_partitions.dart';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/treasury_transfer_service.dart';
import '../../services/permissions_service.dart';
// import '../../models/coding_model.dart';

class TreasuryTransferPage extends StatefulWidget {
  final String companyCode;
  final String? userName;
  final String? selectedBranchCode;
  final Map<String, dynamic>? editItem;

  const TreasuryTransferPage({
    super.key,
    required this.companyCode,
    this.userName,
    this.selectedBranchCode,
    this.editItem,
  });

  @override
  State<TreasuryTransferPage> createState() => _TreasuryTransferPageState();
}

class _TreasuryTransferPageState extends State<TreasuryTransferPage> {
  final TreasuryTransferService _transferService = TreasuryTransferService();
  late String _recordId;
  Map<String, dynamic>? _submittedPayload;
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _statementController = TextEditingController();

  List<String> _treasuriesList = ["الرئيسية"];
  String _fromTreasury = "الرئيسية";
  String _toTreasury = "الرئيسية";
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _recordId = widget.editItem?['id']?.toString() ?? _transferService.newId();
    _loadTreasuriesLocally();
    final edit = widget.editItem;
    if (edit != null) {
      _fromTreasury = edit['from_treasury'].toString();
      _toTreasury = edit['to_treasury'].toString();
      _treasuriesList = {..._treasuriesList, _fromTreasury, _toTreasury}.toList();
      _amountController.text = edit['amount'].toString();
      _statementController.text = edit['statement']?.toString() ?? '';
    }
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
      final box = CachePartitions.box('coding_box');
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
return CachePartitions.run(() async {

    final permission = PermissionsService();
    if (widget.editItem == null ? !permission.canAddTreasuryTransfer : !permission.canEditTreasuryTransfer) {
      _showSnackBar('ليس لديك صلاحية لهذه العملية', AppTheme.warningOrangeFor(context));
      return;
    }
    final amount = double.tryParse(_amountController.text) ?? 0;
    if (!amount.isFinite || amount <= 0) {
      _showSnackBar('الرجاء إدخال مبلغ صحيح أكبر من الصفر', AppTheme.warningOrangeFor(context));
      return;
    }
    if (_fromTreasury == _toTreasury) {
      _showSnackBar('لا يمكن التحويل لنفس الخزينة', AppTheme.warningOrangeFor(context));
      return;
    }
    final branch = widget.editItem?['branch_code']?.toString() ?? widget.selectedBranchCode;
    if (branch == null || {'', 'all', 'الكل', 'كل الفروع'}.contains(branch)) {
      _showSnackBar('اختر فرعاً محدداً من الصفحة الرئيسية أولاً', AppTheme.warningOrangeFor(context));
      return;
    }
    // An uncertain response retries the identical foreground intent and ID.
    _submittedPayload ??= {
      'id': _recordId, 'company_code': widget.companyCode, 'branch_code': branch,
      'serial': widget.editItem?['serial'] ?? 0,
      'from_treasury': _fromTreasury, 'to_treasury': _toTreasury, 'amount': amount,
      'statement': _statementController.text.trim().isEmpty ? 'تحويل مالي بين الخزائن' : _statementController.text.trim(),
      'employee': widget.editItem?['employee'] ?? widget.userName ?? 'غير معروف',
      'date': widget.editItem?['date'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now()),
      if (widget.editItem != null) 'base_updated_at': widget.editItem!['updated_at'],
    };
    setState(() => _isLoading = true);
    try {
      final result = await _transferService.save(_submittedPayload!);
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(result['refresh_pending'] == true
          ? 'تم حفظ التحويل، لكن تحديث الأرصدة لم يكتمل. اضغط تحديث في السجل.'
          : 'تم حفظ التحويل بنجاح', AppTheme.successStrongFor(context));
      await Future<void>.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      if (error is TreasuryTransferFailure && !error.uncertain) _submittedPayload = null;
      setState(() => _isLoading = false);
      _showSnackBar(error is TreasuryTransferFailure && !error.uncertain ? error.toString() : 'لم يتم تأكيد الحفظ. أعد المحاولة من نفس الصفحة بنفس البيانات، أو حدّث السجل للتحقق قبل إنشاء تحويل آخر.', AppTheme.dangerStrongFor(context));
    }
});
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
    return AnimatedBuilder(animation: PermissionsService(), builder: (context, _) {
      final permissions = PermissionsService();
      final allowed = widget.editItem == null ? permissions.canAddTreasuryTransfer :
          permissions.canEditTreasuryTransfer && permissions.canViewTreasuryTransfers;
      if (!allowed) return Scaffold(appBar: AppBar(title: const Text('تحويلات الخزائن')),
          body: const Center(child: Text('لم تعد لديك صلاحية عرض هذه العملية.')));
      return PopScope(canPop: !_isLoading, child: Scaffold(
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
                                    _submittedPayload != null ? 'إعادة تأكيد الحفظ' : widget.editItem != null ? 'حفظ التعديل' : 'تنفيذ التحويل',
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
    ));
    });
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
              onChanged: _isLoading || _submittedPayload != null ? null : onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({required BuildContext context, required TextEditingController controller, required String label, required IconData icon, bool isNumber = false}) {
    return TextField(
      enabled: !_isLoading && _submittedPayload == null,
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