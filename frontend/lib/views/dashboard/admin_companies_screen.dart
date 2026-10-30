import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_service.dart';
import '../../views/widgets/glass_card.dart';

class AdminCompaniesScreen extends StatefulWidget {
  const AdminCompaniesScreen({super.key});

  @override
  State<AdminCompaniesScreen> createState() => _AdminCompaniesScreenState();
}

class _AdminCompaniesScreenState extends State<AdminCompaniesScreen> {
  late final ApiService _api;
  List<dynamic> _companies = [];
  bool _isLoading = true;
  String? _adminJobCode;

  // controllers للإضافة
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // controllers للتعديل
  final TextEditingController _editCodeController = TextEditingController();
  final TextEditingController _editNameController = TextEditingController();
  final _editFormKey = GlobalKey<FormState>();
  String? _currentCompanyCode;  // ✅ مستخدم (يحتوي على الكود القديم)

  @override
  void initState() {
    super.initState();
    _api = ApiService();
    _loadAdminCode();
  }

  Future<void> _loadAdminCode() async {
    final prefs = await SharedPreferences.getInstance();
    _adminJobCode = prefs.getString('job_code');
    if (_adminJobCode == '99') {
      await _fetchCompanies();
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchCompanies() async {
    setState(() => _isLoading = true);
    try {
      final data = await _api.getAllCompanies('99');
      setState(() {
        _companies = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
    }
  }

  Future<void> _addCompany() async {
    if (_formKey.currentState!.validate()) {
      try {
        await _api.addCompany(
          _codeController.text.trim(),
          _nameController.text.trim(),
          '99',
        );
        _codeController.clear();
        _nameController.clear();
        await _fetchCompanies();
        _showSnackBar('✅ تم إضافة الشركة بنجاح', AppTheme.successStrongFor(context));
        Navigator.pop(context);
      } catch (e) {
        _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
      }
    }
  }

  Future<void> _updateCompany() async {
    if (_editFormKey.currentState!.validate()) {
      try {
        await _api.updateCompany(
          oldCode: _currentCompanyCode!,
          newCode: _editCodeController.text.trim(),
          newName: _editNameController.text.trim(),
          adminJobCode: '99',
        );
        await _fetchCompanies();
        _showSnackBar('✅ تم تعديل الشركة بنجاح', AppTheme.successStrongFor(context));
        Navigator.pop(context);
      } catch (e) {
        _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
      }
    }
  }

  Future<void> _deleteCompany(String code) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الشركة', style: TextStyle(fontFamily: 'Cairo')),
        content: Text('هل أنت متأكد من حذف شركة "$code"؟\nسيتم حذف جميع بياناتها بالكامل.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.dangerStrongFor(context)),
            child: Text('حذف', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _api.deleteCompany(code, '99');
      await _fetchCompanies();
      _showSnackBar('🗑️ تم حذف الشركة بنجاح', AppTheme.warningOrangeFor(context));
    } catch (e) {
      _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
    }
  }

  void _toggleCompany(String code, bool currentStatus) async {
    try {
      await _api.toggleCompanyStatus(code, !currentStatus, '99');
      await _fetchCompanies();
      _showSnackBar(
        !currentStatus ? '✅ تم تفعيل الشركة' : '⛔ تم إيقاف الشركة',
        AppTheme.warningOrangeFor(context),
      );
    } catch (e) {
      _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
    }
  }

  void _showAddCompanyDialog() {
    _codeController.clear();
    _nameController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة شركة جديدة', style: TextStyle(fontFamily: 'Cairo')),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _codeController,
                decoration: const InputDecoration(labelText: 'كود الشركة (مثال: 02)'),
                validator: (v) => v!.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'اسم الشركة'),
                validator: (v) => v!.trim().isEmpty ? 'مطلوب' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(onPressed: _addCompany, child: const Text('حفظ')),
        ],
      ),
    );
  }

  void _showEditCompanyDialog(String code, String name) {
    _currentCompanyCode = code;
    _editCodeController.text = code;
    _editNameController.text = name;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل الشركة', style: TextStyle(fontFamily: 'Cairo')),
        content: Form(
          key: _editFormKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _editCodeController,
                decoration: const InputDecoration(labelText: 'كود الشركة'),
                validator: (v) => v!.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _editNameController,
                decoration: const InputDecoration(labelText: 'اسم الشركة'),
                validator: (v) => v!.trim().isEmpty ? 'مطلوب' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(onPressed: _updateCompany, child: const Text('تحديث')),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteCompany(code);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.dangerStrongFor(context)),
            child: Text('حذف', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_adminJobCode != '99') {
      return Scaffold(
        appBar: AppBar(title: const Text('غير مصرح')),
        body: const Center(child: Text("هذة الصفحة خاصة بفريق IslamApp فقط")),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('إدارة الشركات'), centerTitle: true),
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: AppTheme.dashGradientIndigo(context),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.add_business),
                        label: const Text('إضافة شركة جديدة'),
                        onPressed: _showAddCompanyDialog,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentDeep,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _companies.length,
                        itemBuilder: (ctx, index) {
                          final company = _companies[index];
                          final code = company['code'];
                          final name = company['name'];
                          final isActive = company['is_active'] ?? true;
                          return GestureDetector(
                            onTap: () => _showEditCompanyDialog(code, name),
                            child: GlassCard(
                              margin: const EdgeInsets.only(bottom: 12),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isActive ? AppTheme.successStrongFor(context) : AppTheme.dangerStrongFor(context),
                                  child: Text(code ?? '??'),
                                ),
                                title: Text(
                                  name ?? 'بدون اسم',
                                  style: TextStyle(color: AppTheme.textMainFor(context)),
                                ),
                                subtitle: Text(
                                  isActive ? '🟢 نشطة' : '🔴 موقوفة',
                                  style: TextStyle(
                                    color: isActive ? AppTheme.successFor(context) : AppTheme.dangerFor(context),
                                  ),
                                ),
                                trailing: Switch(
                                  value: isActive,
                                  onChanged: (_) => _toggleCompany(code, isActive),
                                  activeThumbColor: AppTheme.successStrongFor(context),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _editCodeController.dispose();
    _editNameController.dispose();
    super.dispose();
  }
}