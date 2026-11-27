// frontend/lib/views/dashboard/admin_companies_screen.dart
import '../../services/cache_partitions.dart';
import '../../services/admin_cache_events.dart';
import 'company_policy_review_page.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/theme.dart';
import '../../services/company_service.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';

// شاشة إدارة الشركات للمدير العام
class AdminCompaniesScreen extends StatefulWidget {
  const AdminCompaniesScreen({super.key});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<AdminCompaniesScreen> createState() => _AdminCompaniesScreenState();
}

// حالة الويدجت AdminCompaniesScreen: تدير بيانات الشاشة وتفاعلاتها
class _AdminCompaniesScreenState extends State<AdminCompaniesScreen> {
  final CompanyService _service = CompanyService();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _editCodeController = TextEditingController();
  final _editNameController = TextEditingController();
  final _editFormKey = GlobalKey<FormState>();
  String? _currentCompanyCode;
  bool _isLoading = false;

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    PermissionsService().addListener(_scopeChanged);
    AdminCacheEvents.companies.addListener(_directoryChanged);
    _refresh();
  }

  // يستجيب لتغيّر دليل الشركات
  void _directoryChanged() {
    if (mounted && PermissionsService().isSuperAdmin) _loadFromHive();
  }

  // يستجيب لتغيّر النطاق أو الصلاحيات
  void _scopeChanged() {
    if (mounted) setState(() {});
  }

  // يحمّل الشركات من التخزين المحلي
  Future<void> _loadFromHive() async {
    return CachePartitions.run(() async {
      // لو Hive فاضي، جيب من السيرفر أول مرة
      if (!_service.hasSnapshot) {
        try {
          await _service.ensureCached();
          if (mounted) setState(() {});
        } catch (error) {
          if (mounted)
            _showSnackBar(error.toString(), AppTheme.dangerStrongFor(context));
        }
      }
    });
  }

  // يحدّث بيانات الشاشة
  Future<void> _refresh() async {
    return CachePartitions.run(() async {
      setState(() => _isLoading = true);
      try {
        await _service.fetchAllCompanies();
      } catch (e) {
        if (mounted) {
          _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    });
  }

  // يضيف شركة جديدة
  Future<void> _addCompany() async {
    return CachePartitions.run(() async {
      if (!_formKey.currentState!.validate()) return;
      setState(() => _isLoading = true);
      try {
        await _service.addCompany(
          code: _codeController.text.trim(),
          name: _nameController.text.trim(),
        );
        _codeController.clear();
        _nameController.clear();
        if (mounted) {
          _showSnackBar(
              '✅ تم إضافة الشركة بنجاح', AppTheme.successStrongFor(context));
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    });
  }

  // يعدّل بيانات الشركة
  Future<void> _updateCompany() async {
    return CachePartitions.run(() async {
      if (!_editFormKey.currentState!.validate()) return;
      setState(() => _isLoading = true);
      try {
        await _service.updateCompany(
          oldCode: _currentCompanyCode!,
          newCode: _editCodeController.text.trim(),
          newName: _editNameController.text.trim(),
        );
        if (mounted) {
          _showSnackBar(
              '✅ تم تعديل الشركة بنجاح', AppTheme.successStrongFor(context));
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    });
  }

  // يحذف شركة
  Future<void> _deleteCompany(String code) async {
    return CachePartitions.run(() async {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title:
              const Text('حذف الشركة', style: TextStyle(fontFamily: 'Cairo')),
          content: Text(
              'هل أنت متأكد من حذف شركة "$code"؟\nسيتم حذف جميع بياناتها بالكامل.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.dangerStrongFor(context)),
              child: Text('حذف',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary)),
            ),
          ],
        ),
      );
      if (confirm != true) return;

      setState(() => _isLoading = true);
      try {
        await _service.deleteCompany(code: code);
        if (mounted) {
          _showSnackBar(
              '🗑️ تم حذف الشركة بنجاح', AppTheme.warningOrangeFor(context));
        }
      } catch (e) {
        if (mounted) {
          _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    });
  }

  // يبدّل حالة تفعيل الشركة
  Future<void> _toggleCompany(String code, bool currentStatus) async {
    return CachePartitions.run(() async {
      setState(() => _isLoading = true);
      try {
        await _service.toggleCompanyStatus(
            code: code, isActive: !currentStatus);
        if (mounted) {
          _showSnackBar(
            !currentStatus ? '✅ تم تفعيل الشركة' : '⛔ تم إيقاف الشركة',
            AppTheme.warningOrangeFor(context),
          );
        }
      } catch (e) {
        if (mounted) {
          _showSnackBar(e.toString(), AppTheme.dangerStrongFor(context));
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    });
  }

  // يعرض نافذة إضافة شركة
  void _showAddCompanyDialog() {
    _codeController.clear();
    _nameController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة شركة جديدة',
            style: TextStyle(fontFamily: 'Cairo')),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _codeController,
                decoration:
                    const InputDecoration(labelText: 'كود الشركة (مثال: 02)'),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(onPressed: _addCompany, child: const Text('حفظ')),
        ],
      ),
    );
  }

  // يعرض نافذة تعديل شركة
  void _showEditCompanyDialog(String code, String name) {
    _currentCompanyCode = code;
    _editCodeController.text = code;
    _editNameController.text = name;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            const Text('تعديل الشركة', style: TextStyle(fontFamily: 'Cairo')),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(onPressed: _updateCompany, child: const Text('تحديث')),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteCompany(code);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.dangerStrongFor(context)),
            child: Text('حذف',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
          ),
        ],
      ),
    );
  }

  // يعرض رسالة سريعة بالنص واللون المحددين
  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    // ⭐ حماية: السوبر أدمن فقط
    if (!PermissionsService().isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('غير مصرح'),
          centerTitle: true,
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 64,
                color: AppTheme.textMutedFor(context),
              ),
              const SizedBox(height: 12),
              Text(
                'هذه الصفحة للسوبر أدمن فقط',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة الشركات'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _refresh,
            tooltip: 'تحديث',
          ),
        ],
      ),
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
          ValueListenableBuilder<Box>(
            valueListenable: _service.companiesListenable,
            builder: (context, box, _) {
              final companies = _service.getCompaniesFromHive();

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add_business),
                      label: const Text('إضافة شركة جديدة'),
                      onPressed: _isLoading ? null : _showAddCompanyDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentDeep,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  if (_isLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: LinearProgressIndicator(),
                    ),
                  Expanded(
                    child: companies.isEmpty
                        ? Center(
                            child: Text(
                              'لا توجد شركات',
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                color: AppTheme.textMutedFor(context),
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _refresh,
                            child: ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: companies.length,
                              itemBuilder: (ctx, index) {
                                final company = companies[index];
                                final code = company['code']?.toString() ?? '';
                                final name = company['name']?.toString() ?? '';
                                final isActive = company['is_active'] != false;

                                return GestureDetector(
                                  onTap: () =>
                                      _showEditCompanyDialog(code, name),
                                  child: GlassCard(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: isActive
                                            ? AppTheme.successStrongFor(context)
                                            : AppTheme.dangerStrongFor(context),
                                        child: Text(code),
                                      ),
                                      title: Text(
                                        name,
                                        style: TextStyle(
                                            color:
                                                AppTheme.textMainFor(context)),
                                      ),
                                      subtitle: Text(
                                        isActive ? '🟢 نشطة' : '🔴 موقوفة',
                                        style: TextStyle(
                                          color: isActive
                                              ? AppTheme.successFor(context)
                                              : AppTheme.dangerFor(context),
                                        ),
                                      ),
                                      trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                                tooltip:
                                                    'مراجعة صلاحيات الشركة',
                                                icon: const Icon(Icons
                                                    .admin_panel_settings_outlined),
                                                onPressed: _isLoading
                                                    ? null
                                                    : () => Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                            builder: (_) =>
                                                                CompanyPolicyReviewPage(
                                                                    companyCode:
                                                                        code,
                                                                    companyName:
                                                                        name)))),
                                            Switch(
                                              value: isActive,
                                              onChanged: _isLoading
                                                  ? null
                                                  : (_) => _toggleCompany(
                                                      code, isActive),
                                              activeThumbColor:
                                                  AppTheme.successStrongFor(
                                                      context),
                                            )
                                          ]),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    PermissionsService().removeListener(_scopeChanged);
    AdminCacheEvents.companies.removeListener(_directoryChanged);
    _codeController.dispose();
    _nameController.dispose();
    _editCodeController.dispose();
    _editNameController.dispose();
    super.dispose();
  }
}
