// lib/views/dashboard/supplier_settlement_page.dart

import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/supplier_settlement_model.dart';
import '../../services/supplier_service.dart';
import '../../services/supplier_settlement_service.dart';
import '../../services/permissions_service.dart';
import '../../views/widgets/glass_card.dart';
import 'supplier_settlement_history_page.dart';

class SupplierSettlementPage extends StatefulWidget {
  final String companyCode;
  final String? selectedBranchCode;
  final String? userName;
  final SupplierSettlementModel? editItem; // ✅ بيانات الإذن في حالة التعديل

  const SupplierSettlementPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.userName,
    this.editItem,
  });

  @override
  State<SupplierSettlementPage> createState() =>
      _SupplierSettlementPageState();
}

class _SupplierSettlementPageState
    extends State<SupplierSettlementPage> {
  final SupplierSettlementService _service =
      SupplierSettlementService();
  final SupplierService _supplierService =
      SupplierService();

  // ============================================================
  // Controllers
  // ============================================================

  final _amountController = TextEditingController();
  final _statementController = TextEditingController();
  final _dateController = TextEditingController();

  // ============================================================
  // الاختيارات
  // ============================================================

  String? _selectedSupplier;
  String? _selectedTreasury;
  String _selectedPaymentMethod = 'نقدي';
  String _currentUserName = 'غير محدد';

  // ============================================================
  // القوائم
  // ============================================================

  List<Map<String, String>> _suppliers = [];
  List<Map<String, String>> _treasuries = [];
  List<Map<String, String>> _paymentMethods = [];

  // ============================================================
  // الأرصدة
  // ============================================================

  double _supplierBalance = 0.0;
  double _expectedBalance = 0.0;

  // ============================================================
  // رقم الإذن وحالة الصفحة
  // ============================================================

  int _currentSerial = 0;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();

    _dateController.text =
        DateFormat('yyyy-MM-dd').format(DateTime.now());

    _amountController.addListener(_updateExpectedBalance);
    _loadData();
  }

  // ============================================================
  // تحميل البيانات
  // ============================================================

  Future<void> _loadData() async {
  try {
    // جلب اسم المستخدم من SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    _currentUserName = prefs.getString('user_name') ?? 'غير محدد';

    final box = Hive.box('coding_box');

    // الموردين
    final suppliers = box.get('${widget.companyCode}_suppliers') as List? ?? [];
    _suppliers = suppliers
        .whereType<Map>()
        .map((e) => {
              'code': e['code']?.toString() ?? '',
              'name': e['name']?.toString() ?? '',
            })
        .where((e) => e['code']!.isNotEmpty && e['name']!.isNotEmpty)
        .toList();

    // الخزائن
    final treasuries = box.get('${widget.companyCode}_safes') as List? ?? [];
    _treasuries = treasuries
        .whereType<Map>()
        .map((e) => {
              'code': e['code']?.toString() ?? '',
              'name': e['name']?.toString() ?? '',
            })
        .where((e) => e['code']!.isNotEmpty && e['name']!.isNotEmpty)
        .toList();

    // طرق الدفع
    final paymentMethods = box.get('${widget.companyCode}_payment_methods') as List? ?? [];
    _paymentMethods = paymentMethods
        .whereType<Map>()
        .map((e) => {
              'code': e['code']?.toString() ?? '',
              'name': e['name']?.toString() ?? '',
            })
        .where((e) => e['code']!.isNotEmpty && e['name']!.isNotEmpty)
        .toList();

    // القيم الافتراضية
    if (_treasuries.isNotEmpty) {
      _selectedTreasury = _treasuries.first['name'];
    }

    if (_paymentMethods.isNotEmpty) {
      _selectedPaymentMethod = _paymentMethods.first['name'] ?? 'نقدي';
    }

    // ✅ في حالة التعديل نحمّل بيانات الإذن أولاً
    if (widget.editItem != null) {
      _loadEditData(widget.editItem!);
    } else {
      // ✅ مورد واحد فقط
      if (_suppliers.length == 1) {
        _selectedSupplier = _suppliers.first['name'];
        await _loadBalance();
      }

      // ✅ رقم الإذن الجديد
      _currentSerial = _getNextSerial();
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  } catch (e) {
    print('❌ خطأ في تحميل التسوية: $e');
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }
}

  // ============================================================
  // تحميل بيانات الإذن في وضع التعديل
  // ============================================================

  Future<void> _loadEditData(
    SupplierSettlementModel item,
  ) async {
    _currentSerial = item.serial;
    _selectedSupplier = item.supplierName;
    _selectedTreasury = item.treasury;
    _selectedPaymentMethod = item.paymentMethod;
    _amountController.text = item.amount.toString();
    _statementController.text = item.statement;
    _dateController.text = item.date;

    await _loadBalance();

    // ✅ الرصيد بعد الدفعة أثناء التعديل:
    // نعيد مبلغ الإذن القديم للرصيد قبل حساب الدفعة الجديدة.
    if (mounted) {
      setState(() {
        _expectedBalance =
            _supplierBalance + item.amount - item.amount;
      });
    }
  }

  // ============================================================
  // حساب رقم الإذن التالي
  // لكل شركة + فرع بشكل مستقل
  // ============================================================

  int _getNextSerial() {
    final box = Hive.box('supplier_settlement_box');
    final branchCode = widget.selectedBranchCode ?? 'all';
    int maxSerial = 0;

    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! List) continue;

      for (final item in raw) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);

        if (map['is_deleted'] == true) continue;
        if (map['company_code']?.toString() != widget.companyCode) continue;
        if (map['branch_code']?.toString() != branchCode) continue;

        final serial =
            int.tryParse(map['serial']?.toString() ?? '0') ?? 0;

        if (serial > maxSerial) maxSerial = serial;
      }
    }

    return maxSerial + 1;
  }

  // ============================================================
  // رصيد المورد
  // ============================================================

  Future<void> _loadBalance() async {
    if (_selectedSupplier == null || _selectedSupplier!.isEmpty) {
      if (mounted) {
        setState(() {
          _supplierBalance = 0.0;
          _expectedBalance = 0.0;
        });
      }
      return;
    }

    try {
      final balance = await _supplierService.getSupplierBalance(
        widget.companyCode,
        widget.selectedBranchCode ?? 'all',
        _selectedSupplier!,
      );

      if (!mounted) return;

      final enteredAmount =
          double.tryParse(_amountController.text) ?? 0.0;

      // ✅ أثناء التعديل الرصيد الحالي يحتوي بالفعل على الدفعة القديمة
      // لذلك نضيفها قبل طرح المبلغ الجديد.
      final oldAmount =
          widget.editItem?.amount ?? 0.0;

      setState(() {
        _supplierBalance = balance;
        _expectedBalance =
            balance + oldAmount - enteredAmount;
      });
    } catch (e) {
      print('❌ خطأ في تحميل رصيد المورد: $e');
    }
  }

  // ============================================================
  // تحديث الرصيد المتوقع
  // ============================================================

  void _updateExpectedBalance() {
  final amount = double.tryParse(_amountController.text) ?? 0.0;
  final oldAmount = widget.editItem?.amount ?? 0.0;

  double newBalance = _supplierBalance + oldAmount - amount;
  // تصحيح الصفر السالب
  if (newBalance.abs() < 0.0001) {
    newBalance = 0.0;
  }

  if (mounted) {
    setState(() {
      _expectedBalance = newBalance;
    });
  }
}

  // ============================================================
  // حفظ / تعديل الدفعة
  // ============================================================

  Future<void> _handleSave() async {
  final isEdit = widget.editItem != null;

  // ✅ الإضافة لها صلاحية مستقلة عن التعديل
  if (isEdit) {
    if (!PermissionsService().canEditSupplierSettlement) {
      _showSnackBar('ليس لديك صلاحية تعديل الدفعة', AppTheme.warningOrangeFor(context));
      return;
    }
  } else {
    if (!PermissionsService().canAddSupplierSettlement) {
      _showSnackBar('ليس لديك صلاحية إضافة دفعة', AppTheme.warningOrangeFor(context));
      return;
    }
  }

  // المورد
  if (_selectedSupplier == null || _selectedSupplier!.isEmpty) {
    _showSnackBar('اختر المورد', AppTheme.warningOrangeFor(context));
    return;
  }

  // المبلغ
  final amount = double.tryParse(_amountController.text.trim()) ?? 0.0;
  if (amount <= 0) {
    _showSnackBar('أدخل مبلغ الدفعة', AppTheme.warningOrangeFor(context));
    return;
  }

  // ✅ في الإضافة نتحقق من الرصيد. في التعديل نسمح باستخدام الرصيد + مبلغ الدفعة القديمة.
  // final availableBalance = _supplierBalance + (widget.editItem?.amount ?? 0.0);
  // if (amount > availableBalance) {
  //   _showSnackBar('مبلغ الدفعة أكبر من رصيد المورد', AppTheme.warningOrangeFor(context));
  //   return;
  // }

  setState(() => _isSaving = true);

  try {
    if (_currentSerial <= 0) {
      _currentSerial = _getNextSerial();
    }

    // ✅ استخدم اسم المستخدم الحالي (من SharedPreferences أو من widget.userName)
    final employeeName = widget.userName != null && widget.userName!.trim().isNotEmpty
        ? widget.userName!.trim()
        : _currentUserName;

    final model = SupplierSettlementModel(
      companyCode: widget.companyCode,
      branchCode: widget.selectedBranchCode ?? 'all',
      supplierName: _selectedSupplier!,
      date: _dateController.text,
      serial: _currentSerial,
      amount: amount,
      paymentMethod: _selectedPaymentMethod,
      treasury: _selectedTreasury ?? '',
      statement: _statementController.text,
      employee: employeeName,
      docId: widget.editItem?.docId,
    );

    final result = await _service.saveSettlement(model);

    if (result['success'] == true) {
      final savedSerial = result['serial'] is num
          ? (result['serial'] as num).toInt()
          : model.serial;

      _showSnackBar(
        isEdit ? 'تم تعديل الدفعة رقم $savedSerial بنجاح' : 'تم حفظ الدفعة رقم $savedSerial بنجاح',
        AppTheme.successStrongFor(context),
      );

      // ✅ في وضع التعديل نرجع للمعاينة بعد الحفظ
      if (isEdit) {
        if (mounted) Navigator.pop(context, true);
        return;
      }

      // ✅ تنظيف بعد الإضافة
      _amountController.clear();
      _statementController.clear();

      await _loadBalance();

      if (mounted) {
        setState(() {
          _currentSerial = _getNextSerial();
        });
      }
    } else {
      _showSnackBar('فشل الحفظ: ${result['error']}', AppTheme.dangerStrongFor(context));
    }
  } catch (e) {
    _showSnackBar('خطأ: $e', AppTheme.dangerStrongFor(context));
  } finally {
    if (mounted) {
      setState(() => _isSaving = false);
    }
  }
}

  // ============================================================
  // SnackBar
  // ============================================================

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: color,
      ),
    );
  }

  // ============================================================
  // اسم الفرع
  // ============================================================

  String _getBranchName(String? code) {
    if (code == null || code.isEmpty || code == 'all') {
      return 'كل الفروع';
    }

    final box = Hive.box('coding_box');
    final raw = box.get(
      '${widget.companyCode}_branches',
      defaultValue: [],
    );

    if (raw is List) {
      for (final item in raw) {
        if (item is Map && item['code']?.toString() == code) {
          return item['name']?.toString() ?? 'فرع غير معروف';
        }
      }
    }

    return 'فرع غير معروف';
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.editItem != null;

    if (!PermissionsService().canShowSupplierSettlements) {
      return Scaffold(
        body: Center(
          child: Text(
            'ليس لديك صلاحية لعرض التسويات',
            style: TextStyle(
              color: AppTheme.textSoftFor(context),
              fontFamily: 'Cairo',
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isEdit ? 'تعديل تسوية مورد' : 'تسويات الموردين',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'إذن رقم: $_currentSerial',
              style: TextStyle(
                color: AppTheme.accentFor(context),
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              _getBranchName(widget.selectedBranchCode),
              style: TextStyle(
                color: AppTheme.textSoftFor(context),
                fontFamily: 'Cairo',
                fontSize: 10,
              ),
            ),
          ],
        ),
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        centerTitle: true,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientMain(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? Center(
                  child: CircularProgressIndicator(color: AppTheme.textMainFor(context)),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _buildBalanceCard(),
                      const SizedBox(height: 10),
                      _buildForm(),
                      const SizedBox(height: 12),

                      // ✅ زر الحفظ / التعديل
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed:
                              _isSaving ? null : _handleSave,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                isEdit
                                    ? AppTheme.warningOrangeSoftFor(context)
                                    : AppTheme.successFor(context),
                            foregroundColor: AppTheme.onAccentFor(context),
                          ),
                          child: Text(
                            _isSaving
                                ? 'جاري الحفظ...'
                                : isEdit
                                    ? 'تعديل الدفعة'
                                    : 'حفظ الدفعة',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // ✅ المعاينة تظهر في الوضع العادي فقط
                      if (!isEdit)
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (c) =>
                                      SupplierSettlementHistoryPage(
                                    companyCode: widget.companyCode,
                                    selectedBranchCode:
                                        widget.selectedBranchCode,
                                  ),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.history_rounded,
                              color: AppTheme.accentFor(context),
                            ),
                            label: Text(
                              'معاينة التسويات',
                              style: TextStyle(
                                color: AppTheme.accentFor(context),
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: AppTheme.accentFor(context),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(10),
                              ),
                              backgroundColor:
                                  GlassStyle.fill03For(context),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  // ============================================================
  // بطاقة الرصيد
  // ============================================================

  Widget _buildBalanceCard() {
  double balance = _supplierBalance.abs() < 0.0001 ? 0.0 : _supplierBalance;
  double expected = _expectedBalance.abs() < 0.0001 ? 0.0 : _expectedBalance;

  return GlassCard(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Text(
            'رصيد المورد',
            style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo'),
          ),
          const SizedBox(height: 4),
          Text(
            balance.toStringAsFixed(2),
            style: TextStyle(color: AppTheme.warningFor(context), fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Divider(color: GlassStyle.line24For(context)),
          Text(
            'الرصيد بعد الدفعة',
            style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo'),
          ),
          Text(
            expected.toStringAsFixed(2),
            style: TextStyle(color: AppTheme.successFor(context), fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    ),
  );
}

  // ============================================================
  // الفورم
  // ============================================================

  Widget _buildForm() {
    final isEdit = widget.editItem != null;
    final canEdit = PermissionsService().canEditSupplierSettlement;
    final canAdd = PermissionsService().canAddSupplierSettlement;
    final enabled = isEdit ? canEdit : canAdd;

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            // المورد
            DropdownButtonFormField<String>(
              value: _selectedSupplier,
              dropdownColor: AppTheme.dropdownBackground(context),
              style: TextStyle(color: AppTheme.textMainFor(context)),
              decoration: InputDecoration(
                labelText: 'المورد',
                labelStyle: TextStyle(color: AppTheme.textSoftFor(context)),
              ),
              items: _suppliers.map(
                (s) => DropdownMenuItem<String>(
                  value: s['name'],
                  child: Text(s['name'] ?? ''),
                ),
              ).toList(),
              onChanged: enabled
                  ? (value) async {
                      setState(() => _selectedSupplier = value);
                      await _loadBalance();
                    }
                  : null,
            ),

            const SizedBox(height: 10),

            // مبلغ الدفعة
            TextFormField(
              controller: _amountController,
              enabled: enabled,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(color: AppTheme.textMainFor(context)),
              decoration: InputDecoration(
                labelText: 'مبلغ الدفعة',
                labelStyle: TextStyle(color: AppTheme.textSoftFor(context)),
              ),
            ),

            const SizedBox(height: 10),

            // طريقة الدفع + الخزينة
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedPaymentMethod,
                    dropdownColor: AppTheme.dropdownBackground(context),
                    style: TextStyle(color: AppTheme.textMainFor(context)),
                    decoration: const InputDecoration(
                      labelText: 'طريقة الدفع',
                    ),
                    items: _paymentMethods.map(
                      (s) => DropdownMenuItem<String>(
                        value: s['name'],
                        child: Text(s['name'] ?? ''),
                      ),
                    ).toList(),
                    onChanged: enabled
                        ? (v) {
                            if (v != null) {
                              setState(
                                () => _selectedPaymentMethod = v,
                              );
                            }
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedTreasury,
                    dropdownColor: AppTheme.dropdownBackground(context),
                    style: TextStyle(color: AppTheme.textMainFor(context)),
                    decoration:
                        const InputDecoration(labelText: 'الخزينة'),
                    items: _treasuries.map(
                      (s) => DropdownMenuItem<String>(
                        value: s['name'],
                        child: Text(s['name'] ?? ''),
                      ),
                    ).toList(),
                    onChanged: enabled
                        ? (v) => setState(() => _selectedTreasury = v)
                        : null,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // البيان
            TextFormField(
              controller: _statementController,
              enabled: enabled,
              style: TextStyle(color: AppTheme.textMainFor(context)),
              decoration: InputDecoration(
                labelText: 'البيان',
                labelStyle: TextStyle(color: AppTheme.textSoftFor(context)),
              ),
            ),

            const SizedBox(height: 10),

            // التاريخ
            TextFormField(
              controller: _dateController,
              readOnly: true,
              enabled: enabled,
              style: TextStyle(color: AppTheme.textMainFor(context)),
              decoration: InputDecoration(
                labelText: 'التاريخ',
                suffixIcon:
                    Icon(Icons.calendar_today, color: AppTheme.warningFor(context)),
              ),
              onTap: enabled ? _pickDate : null,
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // اختيار التاريخ
  // ============================================================

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate:
          DateTime.tryParse(_dateController.text) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2101),
    );

    if (picked == null || !mounted) return;

    setState(() {
      _dateController.text =
          DateFormat('yyyy-MM-dd').format(picked);
    });
  }

  // ============================================================
  // Dispose
  // ============================================================

  @override
  void dispose() {
    _amountController.removeListener(_updateExpectedBalance);
    _amountController.dispose();
    _statementController.dispose();
    _dateController.dispose();
    super.dispose();
  }
}