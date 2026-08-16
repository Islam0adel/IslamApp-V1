import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
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

  const SupplierSettlementPage({
    super.key,
    required this.companyCode,
    this.selectedBranchCode,
    this.userName,
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

  final _amountController =
      TextEditingController();

  final _statementController =
      TextEditingController();

  final _dateController =
      TextEditingController();

  String? _selectedSupplier;
  String? _selectedTreasury;
  String _selectedPaymentMethod = 'نقدي';

  List<Map<String, String>> _suppliers = [];
  List<Map<String, String>> _treasuries = [];
  List<Map<String, String>> _paymentMethods = [];

  double _supplierBalance = 0.0;
  double _expectedBalance = 0.0;



  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();

    _dateController.text =
        DateFormat('yyyy-MM-dd')
            .format(DateTime.now());

    _loadData();

    _amountController.addListener(
      _updateExpectedBalance,
    );
  }

  Future<void> _loadData() async {
    try {
      final box = Hive.box('coding_box');

      final suppliers =
          box.get(
                '${widget.companyCode}_suppliers',
              ) as List? ??
              [];

      final treasuries =
          box.get(
                '${widget.companyCode}_safes',
              ) as List? ??
              [];

      final paymentMethods =
          box.get(
                '${widget.companyCode}_payment_methods',
              ) as List? ??
              [];

      _suppliers = suppliers
          .whereType<Map>()
          .map(
            (e) => {
              'code': e['code'].toString(),
              'name': e['name'].toString(),
            },
          )
          .toList();

      _treasuries = treasuries
          .whereType<Map>()
          .map(
            (e) => {
              'code': e['code'].toString(),
              'name': e['name'].toString(),
            },
          )
          .toList();

      _paymentMethods = paymentMethods
          .whereType<Map>()
          .map(
            (e) => {
              'code': e['code'].toString(),
              'name': e['name'].toString(),
            },
          )
          .toList();

      if (_treasuries.isNotEmpty) {
        _selectedTreasury =
            _treasuries.first['name'];
      }

      if (_paymentMethods.isNotEmpty) {
        _selectedPaymentMethod =
            _paymentMethods.first['name'] ??
                'نقدي';
      }

      if (_suppliers.length == 1) {
        _selectedSupplier =
            _suppliers.first['name'];

        await _loadBalance();
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      print('❌ خطأ في تحميل التسوية: $e');

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadBalance() async {
    if (_selectedSupplier == null ||
        _selectedSupplier!.isEmpty) {
      return;
    }

    final balance =
    await _supplierService.getSupplierBalance(
  widget.companyCode,
  widget.selectedBranchCode ?? 'all',
  _selectedSupplier!,
);

    if (!mounted) return;

    setState(() {
      _supplierBalance = balance;
      _expectedBalance =
          balance -
          (double.tryParse(
                _amountController.text,
              ) ??
              0.0);
    });
  }

  void _updateExpectedBalance() {
    final amount =
        double.tryParse(
              _amountController.text,
            ) ??
            0.0;

    setState(() {
      _expectedBalance =
          _supplierBalance - amount;
    });
  }

  Future<void> _handleSave() async {
    if (!PermissionsService()
        .canAddSupplierSettlement) {
      _showSnackBar(
        'ليس لديك صلاحية إضافة دفعة',
        Colors.orange,
      );
      return;
    }

    if (_selectedSupplier == null ||
        _selectedSupplier!.isEmpty) {
      _showSnackBar(
        'اختر المورد',
        Colors.orange,
      );
      return;
    }

    final amount =
        double.tryParse(
              _amountController.text.trim(),
            ) ??
            0.0;

    if (amount <= 0) {
      _showSnackBar(
        'أدخل مبلغ الدفعة',
        Colors.orange,
      );
      return;
    }

    if (amount > _supplierBalance) {
      _showSnackBar(
        'مبلغ الدفعة أكبر من رصيد المورد',
        Colors.orange,
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final model =
          SupplierSettlementModel(
        companyCode: widget.companyCode,
        branchCode:
            widget.selectedBranchCode ??
                'all',
        supplierName:
            _selectedSupplier!,
        date: _dateController.text,
        serial: 0,
        amount: amount,
        paymentMethod:
            _selectedPaymentMethod,
        treasury:
            _selectedTreasury ??
                '',
        statement:
            _statementController.text,
        employee:
            widget.userName ??
                'غير محدد',
      );

      final result =
          await _service.saveSettlement(
        model,
      );

      if (result['success'] == true) {
        _showSnackBar(
          'تم حفظ الدفعة بنجاح',
          Colors.green,
        );

        _amountController.clear();
        _statementController.clear();

        await _loadBalance();
      } else {
        _showSnackBar(
          'فشل الحفظ: ${result['error']}',
          Colors.red,
        );
      }
    } catch (e) {
      _showSnackBar(
        'خطأ: $e',
        Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _showSnackBar(
    String message,
    Color color,
  ) {
    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style:
              const TextStyle(
            fontFamily: 'Cairo',
          ),
        ),
        backgroundColor: color,
      ),
    );
  }

  @override
Widget build(BuildContext context) {
  if (!PermissionsService().canShowSupplierSettlements) {
    return Scaffold(
      body: const Center(
        child: Text(
          'ليس لديك صلاحية لعرض التسويات',
          style: TextStyle(
            color: Colors.white70,
            fontFamily: 'Cairo',
          ),
        ),
      ),
    );
  }

  return Scaffold(
    appBar: AppBar(
      title: const Text(
        'تسويات الموردين',
        style: TextStyle(
          color: Colors.white,
          fontFamily: 'Cairo',
        ),
      ),
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.black,
            Color(0xFF1A237E),
            Colors.black,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _buildBalanceCard(),

                    const SizedBox(height: 10),

                    _buildForm(),

                    const SizedBox(height: 12),

                    // ============================
                    // زر حفظ الدفعة
                    // ============================

                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed:
                            _isSaving ? null : _handleSave,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              Colors.greenAccent,
                          foregroundColor:
                              Colors.black,
                        ),
                        child: Text(
                          _isSaving
                              ? 'جاري الحفظ...'
                              : 'حفظ الدفعة',
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight:
                                FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    // ============================
                    // زر معاينة التسويات
                    // ============================

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
                                companyCode:
                                    widget.companyCode,
                                selectedBranchCode:
                                    widget.selectedBranchCode,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(
                          Icons.history_rounded,
                          color: Colors.cyanAccent,
                        ),
                        label: const Text(
                          'معاينة التسويات',
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontFamily: 'Cairo',
                            fontWeight:
                                FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                            color: Colors.cyanAccent,
                          ),
                          shape:
                              RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(10),
                          ),
                          backgroundColor:
                              Colors.white.withOpacity(
                            0.03,
                          ),
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

  Widget _buildBalanceCard() {
    return GlassCard(
      child: Padding(
        padding:
            const EdgeInsets.all(12),
        child: Column(
          children: [
            const Text(
              'رصيد المورد',
              style: TextStyle(
                color: Colors.white70,
                fontFamily: 'Cairo',
              ),
            ),
            const SizedBox(
              height: 4,
            ),
            Text(
              _supplierBalance
                  .toStringAsFixed(2),
              style:
                  const TextStyle(
                color: Colors.amber,
                fontSize: 24,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            const Divider(
              color: Colors.white24,
            ),
            const Text(
              'الرصيد بعد الدفعة',
              style: TextStyle(
                color: Colors.white70,
                fontFamily: 'Cairo',
              ),
            ),
            Text(
              _expectedBalance
                  .toStringAsFixed(2),
              style:
                  const TextStyle(
                color: Colors.greenAccent,
                fontSize: 20,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return GlassCard(
      child: Padding(
        padding:
            const EdgeInsets.all(10),
        child: Column(
          children: [
            DropdownButtonFormField<
                String>(
              value:
                  _selectedSupplier,
              dropdownColor:
                  Colors.indigo.shade900,
              style:
                  const TextStyle(
                color: Colors.white,
              ),
              decoration:
                  const InputDecoration(
                labelText: 'المورد',
                labelStyle:
                    TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
              items: _suppliers
                  .map(
                    (s) =>
                        DropdownMenuItem<
                            String>(
                      value:
                          s['name'],
                      child: Text(
                        s['name'] ??
                            '',
                      ),
                    ),
                  )
                  .toList(),
              onChanged:
                  (value) async {
                setState(() {
                  _selectedSupplier =
                      value;
                });

                await _loadBalance();
              },
            ),
            const SizedBox(
              height: 10,
            ),
            TextFormField(
              controller:
                  _amountController,
              keyboardType:
                  const TextInputType
                      .numberWithOptions(
                decimal: true,
              ),
              style:
                  const TextStyle(
                color: Colors.white,
              ),
              decoration:
                  const InputDecoration(
                labelText:
                    'مبلغ الدفعة',
                labelStyle:
                    TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
            ),
            const SizedBox(
              height: 10,
            ),
            Row(
              children: [
                Expanded(
                  child:
                      DropdownButtonFormField<
                          String>(
                    value:
                        _selectedPaymentMethod,
                    dropdownColor:
                        Colors.indigo.shade900,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                    ),
                    decoration:
                        const InputDecoration(
                      labelText:
                          'طريقة الدفع',
                    ),
                    items:
                        _paymentMethods
                            .map(
                              (s) =>
                                  DropdownMenuItem<
                                      String>(
                                value:
                                    s['name'],
                                child:
                                    Text(
                                  s['name'] ??
                                      '',
                                ),
                              ),
                            )
                            .toList(),
                    onChanged:
                        (v) {
                      if (v != null) {
                        setState(
                          () =>
                              _selectedPaymentMethod =
                                  v,
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(
                    width: 8),
                Expanded(
                  child:
                      DropdownButtonFormField<
                          String>(
                    value:
                        _selectedTreasury,
                    dropdownColor:
                        Colors.indigo.shade900,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                    ),
                    decoration:
                        const InputDecoration(
                      labelText:
                          'الخزينة',
                    ),
                    items:
                        _treasuries
                            .map(
                              (s) =>
                                  DropdownMenuItem<
                                      String>(
                                value:
                                    s['name'],
                                child:
                                    Text(
                                  s['name'] ??
                                      '',
                                ),
                              ),
                            )
                            .toList(),
                    onChanged:
                        (v) {
                      setState(
                        () =>
                            _selectedTreasury =
                                v,
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(
              height: 10,
            ),
            TextFormField(
              controller:
                  _statementController,
              style:
                  const TextStyle(
                color: Colors.white,
              ),
              decoration:
                  const InputDecoration(
                labelText:
                    'البيان',
                labelStyle:
                    TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
            ),
            const SizedBox(
              height: 10,
            ),
            TextFormField(
              controller:
                  _dateController,
              readOnly: true,
              style:
                  const TextStyle(
                color: Colors.white,
              ),
              decoration:
                  const InputDecoration(
                labelText:
                    'التاريخ',
                suffixIcon:
                    Icon(
                  Icons.calendar_today,
                  color:
                      Colors.amber,
                ),
              ),
              onTap:
                  _pickDate,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked =
        await showDatePicker(
      context: context,
      initialDate:
          DateTime.tryParse(
                _dateController.text,
              ) ??
              DateTime.now(),
      firstDate:
          DateTime(2020),
      lastDate:
          DateTime(2101),
    );

    if (picked != null) {
      setState(() {
        _dateController.text =
            DateFormat(
          'yyyy-MM-dd',
        ).format(picked);
      });
    }
  }

  @override
  void dispose() {
    _amountController
        .removeListener(
      _updateExpectedBalance,
    );
    _amountController.dispose();
    _statementController.dispose();
    _dateController.dispose();
    super.dispose();
  }
}