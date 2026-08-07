// frontend/lib/views/dashboard/reset_page.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/reset_data_service.dart';

class ResetPage extends StatefulWidget {
  const ResetPage({super.key});

  @override
  State<ResetPage> createState() => _ResetPageState();
}

class _ResetPageState extends State<ResetPage> {
  bool _isLoading = false;
  String _companyCode = '';
  final ResetDataService _resetService = ResetDataService();

  @override
  void initState() {
    super.initState();
    _loadCompanyCode();
  }

  Future<void> _loadCompanyCode() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _companyCode = prefs.getString('company_code') ?? '';
    });
  }

  Future<void> _resetWithConfirmation(
    String title,
    Future<void> Function() resetAction,
  ) async {
    if (_companyCode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'لم يتم العثور على كود الشركة',
            style: TextStyle(fontFamily: 'Cairo'),
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: const Text(
          'سيتم حذف جميع البيانات المحلية وإعادة تحميلها من الخادم. هل أنت متأكد؟',
          style: TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'إلغاء',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'تأكيد',
              style: TextStyle(
                color: Colors.white,
                fontFamily: 'Cairo',
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      await resetAction();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تم إعادة التعيين بنجاح',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'فشل إعادة التعيين: $e',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'إعادة تعيين البيانات',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Cairo',
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.indigo.shade900,
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
              : Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      _buildResetButton(
                        icon: Icons.account_balance_wallet,
                        label: 'إعادة تعيين اليوميات والخزائن',
                        color: Colors.cyan,
                        onPressed: () => _resetWithConfirmation(
                          'إعادة تعيين اليوميات',
                          () => _resetService.resetDailyTransactions(
                            _companyCode,
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      _buildResetButton(
                        icon: Icons.code,
                        label: 'إعادة تعيين التكويد',
                        color: Colors.cyan,
                        onPressed: () => _resetWithConfirmation(
                          'إعادة تعيين التكويد',
                          () => _resetService.resetCoding(_companyCode),
                        ),
                      ),
                      const SizedBox(height: 15),
                      _buildResetButton(
                        icon: Icons.inventory_2,
                        label: 'إعادة تعيين الجرد والمخازن',
                        color: Colors.cyan,
                        onPressed: () => _resetWithConfirmation(
                          'إعادة تعيين الجرد',
                          () => _resetService.resetInventory(_companyCode),
                        ),
                      ),
                      const SizedBox(height: 15),
                      _buildResetButton(
                        icon: Icons.people,
                        label: 'إعادة تعيين الموردين',
                        color: Colors.cyan,
                        onPressed: () => _resetWithConfirmation(
                          'إعادة تعيين الموردين',
                          () => _resetService.resetSupplier(_companyCode),
                        ),
                      ),
                      const SizedBox(height: 25),
                      const Divider(color: Colors.white24),
                      const SizedBox(height: 25),
                      _buildResetButton(
                        icon: Icons.delete_forever,
                        label: 'إعادة تعيين الكل (جميع البيانات)',
                        color: Colors.red,
                        onPressed: () => _resetWithConfirmation(
                          'إعادة تعيين جميع البيانات',
                          () => _resetService.resetAll(_companyCode),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildResetButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withOpacity(0.2),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(color: color, width: 1),
        ),
        onPressed: onPressed,
        icon: Icon(icon, color: color),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontFamily: 'Cairo',
          ),
        ),
      ),
    );
  }
}