import '../../services/cache_partitions.dart';
import '../../services/admin_cache_events.dart';
// lib/views/dashboard/company_users_page.dart

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/company_service.dart';
import '../../services/permissions_service.dart';
import '../../services/user_service.dart';
import '../../services/account_editor_snapshot.dart';
import '../../services/read_authorization_snapshot.dart';

class CompanyUsersPage extends StatefulWidget {
  final String companyCode; // '' = super_admin
  final String companyName;

  const CompanyUsersPage({
    super.key,
    required this.companyCode,
    required this.companyName,
  });

  @override
  State<CompanyUsersPage> createState() => _CompanyUsersPageState();
}

class _CompanyUsersPageState extends State<CompanyUsersPage> {
  final UserService _service = UserService();
  final CompanyService _companyService = CompanyService();

  String _selectedCompanyCode = '';
  String _selectedCompanyName = '';
  bool _isLoading = false;
  String? _error;
  String _searchQuery = '';
  String? _filterStatus;
  String _actorEmail = '';

  @override
  void initState() {
    super.initState();
    PermissionsService().addListener(_scopeChanged);
    _selectedCompanyCode = widget.companyCode;
    _selectedCompanyName = widget.companyName;
    AdminCacheEvents.users.addListener(_directoryChanged);
    AdminCacheEvents.companies.addListener(_companiesChanged);
    _loadActorEmail();
    _loadInitialData(forceRefresh: true);
  }

  @override
  void dispose() {
    PermissionsService().removeListener(_scopeChanged);
    AdminCacheEvents.users.removeListener(_directoryChanged);
    AdminCacheEvents.companies.removeListener(_companiesChanged);
    super.dispose();
  }
  void _directoryChanged() {
    if (!mounted || !PermissionsService().canOpenUserManagement) return;
    final company = AdminCacheEvents.users.value.company;
    if (company == _selectedCompanyCode ||
        (PermissionsService().isSuperAdmin && _selectedCompanyCode.isEmpty)) {
      _loadInitialData();
    } else if (PermissionsService().isSuperAdmin && PermissionsService().canReviewUserRequests) {
      _service.ensureRequests().then((_) { if (mounted) setState(() {}); }).catchError((Object error) {
        if (mounted) setState(() => _error = 'تعذر تحديث الطلبات. اضغط تحديث للمحاولة.');
      });
    }
  }
  void _companiesChanged() {
    if (mounted && PermissionsService().isSuperAdmin) _loadInitialData();
  }

  void _scopeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadActorEmail() async {
return CachePartitions.run(() async {

    try {
      final prefs = await SharedPreferences.getInstance();
      _actorEmail =
          (prefs.getString('user_email') ?? '').toLowerCase().trim();
    } catch (_) {}
});
}

  Future<void> _loadInitialData({bool forceRefresh = false}) async {
return CachePartitions.run(() async {

    setState(() => _isLoading = true);
    try {
      // تحميل الشركات (لو super_admin)
      if (PermissionsService().isSuperAdmin) {
        if (forceRefresh) {
        await _companyService.fetchAllCompanies();
      } else if (!_companyService.hasSnapshot) {
          await _companyService.ensureCached();
        }
        // اختار أول شركة لو مفيش شركة محددة
        if (_selectedCompanyCode.isEmpty) {
          final companies = _companyService.getCompaniesFromHive();
          if (companies.isNotEmpty) {
            _selectedCompanyCode =
                companies.first['code']?.toString() ?? '';
            _selectedCompanyName =
                companies.first['name']?.toString() ?? '';
          }
        }
      }

      // تحميل المستخدمين (من Hive أولاً)
      final hasUsers = _service.hasUsersSnapshot(
        companyCode: PermissionsService().isSuperAdmin
            ? (_selectedCompanyCode.isEmpty ? null : _selectedCompanyCode)
            : _selectedCompanyCode,
      );

      // لو Hive فاضي، جيب من السيرفر
      if (forceRefresh) {
      await _service.fetchAllUsers(companyCode: _selectedCompanyCode.isEmpty ? null : _selectedCompanyCode);
    } else if (!hasUsers) {
        await _service.ensureUsers(
          companyCode: PermissionsService().isSuperAdmin
              ? (_selectedCompanyCode.isEmpty ? null : _selectedCompanyCode)
              : _selectedCompanyCode,
        );
      }

      // تحميل الطلبات المعلقة (للـ admin + super_admin فقط)
      if (PermissionsService().canReviewUserRequests) {
        if (forceRefresh) {
          await _service.fetchPendingRequests();
        } else {
          await _service.ensureRequests();
        }
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
});
}

  Future<void> _refresh() async {
return CachePartitions.run(() async {

    setState(() => _isLoading = true);
    try {
      await _service.fetchAllUsers(
        companyCode: PermissionsService().isSuperAdmin
            ? (_selectedCompanyCode.isEmpty ? null : _selectedCompanyCode)
            : _selectedCompanyCode,
      );
      if (PermissionsService().canReviewUserRequests) {
        await _service.fetchPendingRequests();
      }
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar(e.toString(), AppTheme.dangerFor(context));
      }
    }
});
}

  Future<void> _onCompanyChanged(String? code) async {
return CachePartitions.run(() async {

    if (code == null || code == _selectedCompanyCode) return;
    final companies = _companyService.getCompaniesFromHive();
    final company = companies.firstWhere(
      (c) => c['code']?.toString() == code,
      orElse: () => {'code': code, 'name': ''},
    );

    setState(() {
      _selectedCompanyCode = code;
      _selectedCompanyName = company['name']?.toString() ?? '';
      _isLoading = true;
    });

    try {
      // جلب مستخدمين الشركة الجديدة
      await _service.ensureUsers(companyCode: code);
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar(e.toString(), AppTheme.dangerFor(context));
      }
    }
});
}

  // ============================================================
  // Helpers
  // ============================================================

  List<Map<String, String>> _branchesFor(String companyCode) {
    final branches = <Map<String, String>>[];
    if (companyCode.isEmpty) return branches;

    try {
      final box = CachePartitions.box('coding_box');
      final raw = box.get('${companyCode}_branches', defaultValue: []) as List? ?? [];
      for (final item in raw) {
        if (item is! Map) continue;
        final code = item['code']?.toString() ?? '';
        final name = item['name']?.toString() ?? '';
        if (code.isEmpty) continue;
        branches.add({'code': code, 'name': name});
      }
    } catch (e) {
      print('⚠️ branches load: $e');
    }

    return branches;
  }

  List<Map<String, dynamic>> get _filteredUsers {
    final allUsers = _service.getUsersFromHive(
      companyCode: PermissionsService().isSuperAdmin
          ? (_selectedCompanyCode.isEmpty ? null : _selectedCompanyCode)
          : _selectedCompanyCode,
    );

    var result = List<Map<String, dynamic>>.from(allUsers);

    if (_filterStatus != null && _filterStatus!.isNotEmpty) {
      result = result
          .where((u) => _accountStatus(u) == _filterStatus)
          .toList();
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      result = result.where((u) {
        final name = (u['name'] ?? '').toString().toLowerCase();
        final email = (u['email'] ?? '').toString().toLowerCase();
        final phone = (u['phone_number'] ?? '').toString();
        final username = (u['username'] ?? '').toString().toLowerCase();
        return name.contains(q) ||
            email.contains(q) ||
            phone.contains(q) ||
            username.contains(q);
      }).toList();
    }

    return result;
  }

  // ============================================================
  // Add User
  // ============================================================

  Future<void> _showAddUserDialog() async {
return CachePartitions.run(() async {

    if (_selectedCompanyCode.isEmpty) {
      _showSnackBar('اختر شركة أولاً', AppTheme.warningOrangeFor(context));
      return;
    }

    final branches = _branchesFor(_selectedCompanyCode);
    if (branches.isEmpty) {
      _showSnackBar(
        'لا توجد فروع مسجلة لهذه الشركة. أضف فرعاً أولاً من صفحة التكويد.',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final branchesWithAll = [
      {'code': 'all', 'name': 'كل الفروع (موظف عام)'},
      ...branches,
    ];

    final allowedRoles = PermissionsService().isSuperAdmin
        ? {'admin': 'مدير شركة', 'employee': 'موظف عادي'}
        : {'employee': 'موظف عادي'};

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AddUserDialog(
        branches: branchesWithAll,
        allowedRoles: allowedRoles,
        companyName: _selectedCompanyName,
      ),
    );

    if (result == null || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await _service.addUser(
        name: (result['name'] as String?) ?? '',
        phoneNumber: (result['phone_number'] as String?) ?? '',
        branchCode: result['branch_code'] as String,
        role: result['role'] as String,
        companyCode: _selectedCompanyCode,
        email: (result['email'] as String?) ?? '',
        username: result['username'] as String?,
      );

      if (!mounted) return;
      final displayName =
          (result['name'] as String?)?.trim().isNotEmpty == true
              ? result['name']
              : ((result['email'] as String?)?.trim().isNotEmpty == true
                  ? result['email']
                  : result['phone_number']);

      _showSnackBar('تمت إضافة $displayName بنجاح ✅',
          AppTheme.successStrongFor(context));
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
});
}

  // ============================================================
  // Edit User
  // ============================================================

  Future<void> _showEditUserDialog(Map<String, dynamic> user) async {
return CachePartitions.run(() async {

    final email = (user['email'] ?? '').toString();
    if (email.isEmpty) {
      _showSnackBar('المستخدم بدون بريد إلكتروني — لا يمكن تعديله',
          AppTheme.warningOrangeFor(context));
      return;
    }

    AccountEditorSnapshot editor;
    setState(() => _isLoading = true);
    try {
      editor = await _service.loadAccountEditor(email);
      if (!mounted) return;
      if (_selectedCompanyCode.isNotEmpty && editor.companyCode != _selectedCompanyCode) {
        throw StateError('تغيرت الشركة المحددة. أعد فتح المستخدم');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
      return;
    }
    setState(() => _isLoading = false);
    final userRole = editor.data['role'];
    final canChangeRole = editor.canChangeRole && userRole != 'super_admin';
    final canChangeStatus = editor.canChangeStatus && userRole != 'super_admin';
    final allowedRoles = canChangeRole
        ? {'employee': 'موظف عادي', 'admin': 'مدير شركة'}
        : <String, String>{};

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => CompanyUserEditDialog(
        user: editor.data,
        authorization: editor,
        branches: editor.branches,
        allowedRoles: allowedRoles,
        canChangeRole: canChangeRole,
        canChangeStatus: canChangeStatus,
        isSelf: _isCurrentUser(editor.data),
        canEditMetadata: editor.canEdit,
      ),
    );

    if (result == null || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await _service.editUser(
        email: email,
        editor: editor,
        name: result['name'] as String?,
        invitationEmail: result['invitation_email'] as String?,
        phoneNumber: result['phone_number'] as String?,
        branchCode: result['branch_code'] as String?,
        role: result['role'] as String?,
        username: result['username'] as String?,
        status: result['status'] as String?,
        isActive: result['is_active'] as bool?,
        companyCode: _selectedCompanyCode,
      );
      if (!mounted) return;
      if (!editor.isCurrent) {
        setState(() => _isLoading = false);
        return;
      }
      _showSnackBar('تم التحديث بنجاح ✅', AppTheme.successStrongFor(context));
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), e is UserSavedRefreshFailed
          ? AppTheme.warningOrangeFor(context) : AppTheme.dangerFor(context));
    }
});
}

  // ============================================================
  // Delete User
  // ============================================================

  Future<void> _confirmDelete(Map<String, dynamic> user) async {
return CachePartitions.run(() async {

    final email = (user['email'] ?? '').toString();
    final name = (user['name'] ?? '').toString();
    if (email.isEmpty) {
      _showSnackBar('لا يمكن حذف مستخدم بدون بريد',
          AppTheme.warningOrangeFor(context));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text('حذف المستخدم',
            style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold)),
        content: Text(
          'سيتم حذف "$name" نهائياً.\nسيتم حذف حسابه من Firebase والبيانات.',
          style: TextStyle(
              fontFamily: 'Cairo', color: AppTheme.textMutedFor(context)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMutedFor(context)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('حذف',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.dangerStrongFor(context),
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await _service.deleteUser(
        email: email,
        companyCode: _selectedCompanyCode,
      );
      if (!mounted) return;
      _showSnackBar('تم حذف $name', AppTheme.warningOrangeFor(context));
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
});
}

  // ============================================================
  // Reset Pending User
  // ============================================================

  Future<void> _confirmResetPending(Map<String, dynamic> user) async {
return CachePartitions.run(() async {

    final email = (user['email'] ?? '').toString();
    final name = (user['name'] ?? '').toString();
    if (email.isEmpty) {
      _showSnackBar('لا يمكن إعادة التعيين بدون بريد',
          AppTheme.warningOrangeFor(context));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text('إعادة السماح بالتسجيل',
            style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold)),
        content: Text(
          'سيتم إعادة تعيين "$name":\n'
          '• مسح الحساب من Firebase\n'
          '• مسح البريد وكلمة المرور\n'
          '• العودة لحالة "بانتظار إكمال التسجيل"\n\n'
          'المستخدم سيقدر يدخل رقمه من جديد ويكمل التسجيل.',
          style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMutedFor(context),
              height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMutedFor(context)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('إعادة تعيين',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.warningOrangeFor(context),
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await _service.resetPendingUser(
        email: email,
        companyCode: _selectedCompanyCode,
      );
      if (!mounted) return;
      _showSnackBar('تم إعادة تعيين $name — يمكنه التسجيل من جديد',
          AppTheme.successStrongFor(context));
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
});
}

  // ============================================================
  // Approve/Reject Requests
  // ============================================================

  Future<void> _approveRequest(String requestId, String name) async {
return CachePartitions.run(() async {

    final requests = _service.getRequestsFromHive();
    Map<String, dynamic>? request;
    try {
      request = requests.firstWhere(
        (r) => (r['id'] ?? '').toString() == requestId,
      );
    } catch (_) {
      _showSnackBar('الطلب غير موجود', AppTheme.dangerFor(context));
      return;
    }

    final requestCompanyCode = (request['company_code'] ?? '').toString();
    final isSuperAdmin = PermissionsService().isSuperAdmin;
    final needsCompany = requestCompanyCode.isEmpty && isSuperAdmin;

    if (requestCompanyCode.isEmpty && !isSuperAdmin) {
      _showSnackBar(
        'الطلب غير مرتبط بشركة — يجب أن يوافق عليه السوبر أدمن',
        AppTheme.dangerFor(context),
      );
      return;
    }

    // ⭐ الشركات من Hive (بدل الـ API)
    final companies = _companyService.getCompaniesFromHive();

    final branches = _branchesFor(_selectedCompanyCode);
    final branchesWithAll = [
      {'code': 'all', 'name': 'كل الفروع (موظف عام)'},
      ...branches,
    ];

    final allowedRoles = isSuperAdmin
        ? {'admin': 'مدير شركة', 'employee': 'موظف عادي'}
        : {'employee': 'موظف عادي'};

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        String role = allowedRoles.keys.first;
        String branch = branchesWithAll.isNotEmpty
            ? branchesWithAll.first['code']!
            : 'all';
        String company = requestCompanyCode.isNotEmpty
            ? requestCompanyCode
            : (companies.isNotEmpty
                ? (companies.first['code'] ?? '').toString()
                : '');

        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            backgroundColor: AppTheme.dialogBackground(context),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15)),
            title: Text('موافقة على $name',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMainFor(context),
                    fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (needsCompany) ...[
                    DropdownButtonFormField<String>(
                      initialValue: company.isEmpty ? null : company,
                      isExpanded: true,
                      dropdownColor: AppTheme.dropdownBackground(context),
                      decoration:
                          const InputDecoration(labelText: 'الشركة (مطلوب)'),
                      items: companies.map((c) {
                        final code = (c['code'] ?? '').toString();
                        final cname = (c['name'] ?? '').toString();
                        return DropdownMenuItem(
                          value: code,
                          child: Text('$cname ($code)',
                              style:
                                  const TextStyle(fontFamily: 'Cairo')),
                        );
                      }).toList(),
                      onChanged: (v) => setLocal(() => company = v ?? ''),
                    ),
                    const SizedBox(height: 10),
                  ],
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    decoration:
                        const InputDecoration(labelText: 'نوع المستخدم'),
                    items: allowedRoles.entries
                        .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value,
                                  style: const TextStyle(fontFamily: 'Cairo')),
                            ))
                        .toList(),
                    onChanged: (v) => setLocal(() => role = v ?? role),
                  ),
                  const SizedBox(height: 10),
                  if (branchesWithAll.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: branch,
                      decoration: const InputDecoration(labelText: 'الفرع'),
                      items: branchesWithAll
                          .map((b) => DropdownMenuItem(
                                value: b['code'],
                                child: Text(b['name']!,
                                    style: const TextStyle(
                                        fontFamily: 'Cairo')),
                              ))
                          .toList(),
                      onChanged: (v) => setLocal(() => branch = v ?? branch),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('إلغاء',
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.textMutedFor(context)))),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, {
                  'role': role,
                  'branch_code': branch,
                  'company_code': company,
                }),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.successStrongFor(context),
                  foregroundColor: Colors.white,
                ),
                child: const Text('موافقة',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
    );

    if (result == null) return;

    setState(() => _isLoading = true);
    try {
      await _service.approveRequest(
        requestId: requestId,
        role: result['role'] as String,
        branchCode: result['branch_code'] as String?,
        companyCode: (result['company_code'] as String?)?.isEmpty == true
            ? null
            : result['company_code'] as String?,
      );
      if (!mounted) return;
      _showSnackBar('تمت الموافقة على $name ✅',
          AppTheme.successStrongFor(context));
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
});
}

  Future<void> _rejectRequest(String requestId, String name) async {
return CachePartitions.run(() async {

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text('رفض الطلب',
            style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold)),
        content: Text('رفض طلب انضمام $name؟',
            style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMutedFor(context)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('رفض',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.dangerStrongFor(context),
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await _service.rejectRequest(requestId: requestId);
      if (!mounted) return;
      _showSnackBar('تم الرفض', AppTheme.warningOrangeFor(context));
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
});
}

  // ============================================================
  // Helpers (بدون تغيير)
  // ============================================================

  String _userRole(Map<String, dynamic> user) {
    final role = (user['role'] ?? '').toString().trim();
    if (role.isNotEmpty) return role;
    final jobCode = (user['job_code'] ?? '1').toString();
    switch (jobCode) {
      case '99':
        return 'super_admin';
      case '201':
        return 'admin';
      default:
        return 'employee';
    }
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'super_admin':
        return 'صاحب البرنامج';
      case 'admin':
        return 'مدير شركة';
      default:
        return 'موظف عادي';
    }
  }

  IconData _roleIcon(String role) {
    switch (role) {
      case 'super_admin':
        return Icons.workspace_premium_rounded;
      case 'admin':
        return Icons.admin_panel_settings_rounded;
      default:
        return Icons.person_rounded;
    }
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'super_admin':
        return AppTheme.extraPurpleFor(context);
      case 'admin':
        return AppTheme.infoFor(context);
      default:
        return AppTheme.accentFor(context);
    }
  }

  bool _isCurrentUser(Map<String, dynamic> user) {
    if (_actorEmail.isEmpty) return false;
    final userEmail = (user['email'] ?? '').toString().toLowerCase().trim();
    return userEmail.isNotEmpty && userEmail == _actorEmail;
  }

  String _accountStatus(Map<String, dynamic> user) =>
      user['is_active'] == false ? 'suspended' : (user['status'] ?? 'active').toString();

  String _statusLabel(String status) {
    switch (status) {
      case 'pending':
        return 'بانتظار التسجيل';
      case 'suspended':
        return 'موقوف';
      default:
        return 'نشط';
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'pending':
        return AppTheme.warningOrangeFor(context);
      case 'suspended':
        return AppTheme.dangerStrongFor(context);
      default:
        return AppTheme.successStrongFor(context);
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'pending':
        return Icons.schedule_rounded;
      case 'suspended':
        return Icons.block_rounded;
      default:
        return Icons.check_circle_rounded;
    }
  }

  void _showSnackBar(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: color,
      ),
    );
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canOpenUserManagement) {
      return _buildNoPermissionScreen();
    }

    final companies = PermissionsService().isSuperAdmin
        ? _companyService.getCompaniesFromHive()
        : <Map<String, dynamic>>[];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          _selectedCompanyName.isEmpty
              ? 'إدارة المستخدمين'
              : 'مستخدمو $_selectedCompanyName',
          style: TextStyle(
              fontFamily: 'Cairo', color: AppTheme.textMainFor(context)),
        ),
        centerTitle: true,
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: Icon(Icons.refresh_rounded,
                color: AppTheme.textMainFor(context)),
            onPressed: _isLoading ? null : _refresh,
          ),
        ],
      ),
      floatingActionButton: _isLoading || !PermissionsService().canUserManagementAction('إضافة')
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTheme.accentFor(context),
              foregroundColor: AppTheme.onAccentFor(context),
              onPressed: _showAddUserDialog,
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('إضافة مستخدم',
                  style: TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
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
          child: _isLoading && _service.getUsersFromHive().isEmpty
              ? Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.accentFor(context)))
              : _error != null
                  ? _buildErrorState()
                  : ValueListenableBuilder<Box>(
                      valueListenable: _service.usersListenable,
                      builder: (context, box, _) {
                        final filtered = _filteredUsers;
                        final allUsers = _service.getUsersFromHive(
                          companyCode: PermissionsService().isSuperAdmin
                              ? (_selectedCompanyCode.isEmpty
                                  ? null
                                  : _selectedCompanyCode)
                              : _selectedCompanyCode,
                        );
                        final pending =
                            allUsers.where((u) => _accountStatus(u) == 'pending').length;
                        final active =
                            allUsers.where((u) => _accountStatus(u) == 'active').length;
                        final suspended = allUsers
                            .where((u) => _accountStatus(u) == 'suspended')
                            .length;

                        return _buildContent(
                            companies, pending, active, suspended, filtered);
                      },
                    ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 60, color: AppTheme.dangerFor(context)),
            const SizedBox(height: 12),
            Text(_error ?? 'حدث خطأ',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context))),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة',
                  style: TextStyle(fontFamily: 'Cairo')),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentFor(context),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoPermissionScreen() {
    return Scaffold(
      appBar: AppBar(
        title: Text('إدارة المستخدمين',
            style: TextStyle(
                fontFamily: 'Cairo', color: AppTheme.textMainFor(context))),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 64, color: AppTheme.textMutedFor(context)),
            const SizedBox(height: 12),
            Text('ليس لديك صلاحية إدارة المستخدمين',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context))),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    List<Map<String, dynamic>> companies,
    int pending,
    int active,
    int suspended,
    List<Map<String, dynamic>> filtered,
  ) {
    return Column(
      children: [
        if (PermissionsService().isSuperAdmin && companies.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 15, 15, 0),
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedCompanyCode.isEmpty
                      ? null
                      : _selectedCompanyCode,
                  isExpanded: true,
                  dropdownColor: AppTheme.dropdownBackground(context),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMainFor(context),
                      fontSize: 14),
                  icon: Icon(Icons.expand_more_rounded,
                      color: AppTheme.accentFor(context)),
                  items: companies.map((c) {
                    final code = (c['code'] ?? '').toString();
                    final name = (c['name'] ?? '').toString();
                    return DropdownMenuItem<String>(
                      value: code,
                      child: Row(
                        children: [
                          Icon(Icons.business_rounded,
                              color: AppTheme.accentFor(context), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('$name ($code)',
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: _onCompanyChanged,
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 15, 15, 8),
          child: GlassCard(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                    child: _statChip(
                        'نشط', '$active',
                        AppTheme.successStrongFor(context),
                        Icons.check_circle_rounded)),
                const SizedBox(width: 6),
                Expanded(
                    child: _statChip(
                        'معلق', '$pending',
                        AppTheme.warningOrangeFor(context),
                        Icons.schedule_rounded)),
                const SizedBox(width: 6),
                Expanded(
                    child: _statChip(
                        'موقوف', '$suspended',
                        AppTheme.dangerStrongFor(context),
                        Icons.block_rounded)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 4, 15, 8),
          child: Column(
            children: [
              GlassCard(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMainFor(context)),
                  decoration: InputDecoration(
                    hintText: PermissionsService().canUserManagementAction('معاينة')
                        ? 'بحث بالاسم / إيميل / موبايل' : 'بحث بالاسم / إيميل',
                    hintStyle: TextStyle(
                        fontFamily: 'Cairo',
                        color: AppTheme.textMutedFor(context),
                        fontSize: 13),
                    prefixIcon: Icon(Icons.search_rounded,
                        color: AppTheme.accentFor(context)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('الكل', null),
                    const SizedBox(width: 6),
                    _filterChip('نشط', 'active'),
                    const SizedBox(width: 6),
                    _filterChip('معلق', 'pending'),
                    const SizedBox(width: 6),
                    _filterChip('موقوف', 'suspended'),
                  ],
                ),
              ),
            ],
          ),
        ),
        _buildRequestsSection(),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _refresh,
                  color: AppTheme.accentFor(context),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(15, 8, 15, 80),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _buildUserCard(filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _statChip(String label, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  color: color,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          Text(label,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                  fontSize: 10)),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String? value) {
    final selected = _filterStatus == value;
    final color = selected
        ? AppTheme.accentFor(context)
        : AppTheme.textMutedFor(context);
    return InkWell(
      onTap: () => setState(() => _filterStatus = value),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentFor(context).withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppTheme.accentFor(context)
                : GlassStyle.line10For(context),
          ),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                color: color,
                fontSize: 12,
                fontWeight:
                    selected ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline_rounded,
                size: 60, color: AppTheme.textMutedFor(context)),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty || _filterStatus != null
                  ? 'لا توجد نتائج مطابقة'
                  : (PermissionsService().companyPolicyActive &&
                      !PermissionsService().canUserManagementAction('معاينة'))
                      ? 'لا توجد حسابات للعرض ضمن صلاحياتك الحالية'
                      : 'لا يوجد مستخدمون بعد',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestsSection() {
    if (!PermissionsService().canReviewUserRequests) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<Box>(
      valueListenable: _service.usersListenable,
      builder: (context, box, _) {
        final requests = _service.getRequestsFromHive();
        if (requests.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(15, 4, 15, 8),
          child: GlassCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.inbox_rounded,
                        color: AppTheme.warningOrangeFor(context), size: 18),
                    const SizedBox(width: 8),
                    Text('طلبات الانضمام المعلقة',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            color: AppTheme.textMainFor(context),
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.warningOrangeFor(context)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${requests.length}',
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              color: AppTheme.warningOrangeFor(context),
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...requests.take(3).map((r) => _buildRequestRow(r)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRequestRow(Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    final phone = (r['phone_number'] ?? '').toString();
    final email = (r['email'] ?? '').toString();
    final id = (r['id'] ?? '').toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMainFor(context),
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              if (phone.isNotEmpty) _infoChip(Icons.phone_rounded, phone),
              if (email.isNotEmpty) _infoChip(Icons.email_rounded, email),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (PermissionsService().canUserManagementAction('رفض طلب')) TextButton(
                onPressed: () => _rejectRequest(id, name),
                child: Text('رفض',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: AppTheme.dangerFor(context))),
              ),
              if (PermissionsService().canUserManagementAction('الموافقة على طلب')) TextButton(
                onPressed: () => _approveRequest(id, name),
                child: Text('موافقة',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: AppTheme.successStrongFor(context),
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final name = (user['name'] ?? '').toString().trim();
    final email = (user['email'] ?? '').toString().trim();
    final phone = (user['phone_number'] ?? '').toString().trim();
    final displayName = name.isNotEmpty
        ? name
        : (email.isNotEmpty ? email : (phone.isNotEmpty ? phone : '—'));
    final isAnonymous = name.isEmpty;
    final branchCode = (user['branch_code'] ?? '').toString();
    final status = _accountStatus(user);
    final emailVerified = user['email_verified'] == true;
    final requiresVerification = user['requires_email_verification'] == true;
    final hasAccount = user['has_account'] == true;
    final username = (user['username'] ?? '').toString();

    final role = _userRole(user);
    final roleLabel = _roleLabel(role);
    final roleColor = _roleColor(role);
    final statusColor = _statusColor(status);

    final canEditThis = _canEditUser(user);
    final canDeleteThis = _canDeleteUser(user);
    final canResetThis = _canResetUser(user);

    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(_roleIcon(role), color: roleColor, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            color: isAnonymous
                                ? AppTheme.textMutedFor(context)
                                : AppTheme.textMainFor(context),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            fontStyle: isAnonymous
                                ? FontStyle.italic
                                : FontStyle.normal),
                        overflow: TextOverflow.ellipsis),
                    Row(
                      children: [
                        Text(roleLabel,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                color: roleColor,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: statusColor.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_statusIcon(status),
                                  color: statusColor, size: 10),
                              const SizedBox(width: 3),
                              Text(_statusLabel(status),
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      color: statusColor,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              if (phone.isNotEmpty) _infoChip(Icons.phone_rounded, phone),
              if (email.isNotEmpty) _infoChip(Icons.email_rounded, email),
              if (username.isNotEmpty)
                _infoChip(Icons.alternate_email_rounded, '@$username'),
              if (user['directory_summary_only'] != true && branchCode.isNotEmpty)
                _infoChip(Icons.storefront_rounded, 'فرع $branchCode')
              else if (user['directory_summary_only'] != true)
                _infoChip(Icons.public_rounded, 'كل الفروع (موظف عام)',
                    color: AppTheme.infoFor(context)),
              if (status == 'active' &&
                  requiresVerification &&
                  !emailVerified)
                _infoChip(Icons.mark_email_unread_rounded,
                    'بانتظار التحقق من البريد',
                    color: AppTheme.warningOrangeFor(context)),
              if (status == 'pending')
                _infoChip(Icons.info_outline_rounded,
                    'بانتظار إكمال التسجيل',
                    color: AppTheme.infoFor(context)),
              if (status == 'active' && !hasAccount)
                _infoChip(Icons.error_outline_rounded, 'بدون حساب',
                    color: AppTheme.dangerFor(context)),
            ],
          ),
          if (canEditThis || canDeleteThis || canResetThis) ...[
            const SizedBox(height: 8),
            Divider(color: GlassStyle.line10For(context), height: 1),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (canResetThis)
                  TextButton.icon(
                    onPressed: () => _confirmResetPending(user),
                    icon: Icon(Icons.restart_alt_rounded,
                        size: 14,
                        color: AppTheme.warningOrangeFor(context)),
                    label: Text('إعادة تعيين',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: AppTheme.warningOrangeFor(context),
                            fontWeight: FontWeight.bold)),
                  ),
                if (canEditThis)
                  TextButton.icon(
                    onPressed: () => _showEditUserDialog(user),
                    icon: Icon(Icons.edit_rounded,
                        size: 14, color: AppTheme.accentFor(context)),
                    label: Text('تعديل',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: AppTheme.accentFor(context),
                            fontWeight: FontWeight.bold)),
                  ),
                if (canDeleteThis)
                  TextButton.icon(
                    onPressed: () => _confirmDelete(user),
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 14, color: AppTheme.dangerFor(context)),
                    label: Text('حذف',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: AppTheme.dangerFor(context),
                            fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _canEditUser(Map<String, dynamic> user) {
    final permissions = PermissionsService();
    if (!permissions.canUserManagementAction('تعديل') &&
        !permissions.canUserManagementAction('تغيير حالة الحساب')) return false;
    return permissions.isSuperAdmin || _userRole(user) != 'super_admin';
  }

  bool _canDeleteUser(Map<String, dynamic> user) {
    if (!PermissionsService().canUserManagementAction('حذف') ||
        _userRole(user) == 'super_admin') return false;
    return PermissionsService().isSuperAdmin || _userRole(user) == 'employee';
  }

  bool _canResetUser(Map<String, dynamic> user) {
    if (!PermissionsService().canUserManagementAction('إعادة تهيئة حساب') ||
        _userRole(user) == 'super_admin') return false;
    final stuck = user['status'] == 'pending' || user['has_account'] != true;
    return stuck && (PermissionsService().isSuperAdmin || _userRole(user) == 'employee');
  }

  Widget _infoChip(IconData icon, String text, {Color? color}) {
    final c = color ?? AppTheme.textMutedFor(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: c),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(fontFamily: 'Cairo', color: c, fontSize: 11)),
      ],
    );
  }
}

// ============================================================
// Add User Dialog + Edit User Dialog (احتفظ بالكود الأصلي)
// ============================================================

class _AddUserDialog extends StatefulWidget {
  final List<Map<String, String>> branches;
  final Map<String, String> allowedRoles;
  final String companyName;

  const _AddUserDialog({
    required this.branches,
    required this.allowedRoles,
    required this.companyName,
  });

  @override
  State<_AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends State<_AddUserDialog> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  late String _branchCode;
  late String _role;

  @override
  void initState() {
    super.initState();
    _role = widget.allowedRoles.keys.first;
    _branchCode = widget.branches.first['code'] ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final phone = _phoneCtrl.text.trim();
    final email = _emailCtrl.text.trim().toLowerCase();

    if (email.isEmpty) {
      return _error('بريد الدعوة مطلوب');
    }
    if (phone.isNotEmpty && !RegExp(r'^[0-9]{8,15}$').hasMatch(phone)) {
      return _error('رقم الموبايل غير صحيح');
    }
    if (email.isNotEmpty &&
        !RegExp(r'^[\w\.-]+@[\w\.-]+\.[a-zA-Z]{2,}$').hasMatch(email)) {
      return _error('صيغة البريد غير صحيحة');
    }

    Navigator.pop(context, {
      'name': _nameCtrl.text.trim(),
      'phone_number': phone,
      'email': email,
      'branch_code': _branchCode,
      'role': _role,
      'username': _usernameCtrl.text.trim(),
    });
  }

  void _error(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.dangerFor(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Text('إضافة مستخدم — ${widget.companyName}',
          style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMainFor(context),
              fontWeight: FontWeight.bold,
              fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(_nameCtrl, 'الاسم الكامل (اختياري)', Icons.person_rounded),
              const SizedBox(height: 10),
              _field(_phoneCtrl, 'رقم الموبايل', Icons.phone_rounded,
                  keyboardType: TextInputType.phone),
              const SizedBox(height: 10),
              _dropdown('الفرع', Icons.storefront_rounded, _branchCode,
                  widget.branches
                      .map((b) => DropdownMenuItem<String>(
                          value: b['code'] ?? '',
                          child: Text(b['name'] ?? b['code']!,
                              style: const TextStyle(fontFamily: 'Cairo'))))
                      .toList(),
                  (v) => setState(() => _branchCode = v ?? '')),
              const SizedBox(height: 10),
              _dropdown('نوع المستخدم', Icons.badge_rounded, _role,
                  widget.allowedRoles.entries
                      .map((e) => DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(e.value,
                              style: const TextStyle(fontFamily: 'Cairo'))))
                      .toList(),
                  (v) => setState(() => _role = v ?? 'employee')),
              const SizedBox(height: 10),
              _field(_emailCtrl, 'بريد الدعوة (مطلوب)', Icons.email_rounded,
                  keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 10),
              _field(_usernameCtrl, 'اسم المستخدم (اختياري)',
                  Icons.alternate_email_rounded),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('إلغاء',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context)))),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentFor(context),
            foregroundColor: Colors.white,
          ),
          child: const Text('إضافة',
              style: TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {TextInputType? keyboardType}) {
    return TextField(
      controller: c,
      keyboardType: keyboardType,
      style: TextStyle(
          fontFamily: 'Cairo', color: AppTheme.textMainFor(context)),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        labelStyle: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textSoftFor(context),
            fontSize: 12),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
      ),
    );
  }

  Widget _dropdown<T>(String label, IconData icon, T value,
      List<DropdownMenuItem<T>> items, ValueChanged<T?> onChanged) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      items: items,
      onChanged: onChanged,
      dropdownColor: AppTheme.dropdownBackground(context),
      style: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMainFor(context),
          fontSize: 13),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        labelStyle: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textSoftFor(context),
            fontSize: 12),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
      ),
    );
  }
}

class CompanyUserEditDialog extends StatefulWidget {
  final Map<String, dynamic> user;
  final List<Map<String, String>> branches;
  final Map<String, String> allowedRoles;
  final bool canChangeRole;
  final bool canChangeStatus;
  final bool isSelf;
  final bool canEditMetadata;
  final AccountEditorSnapshot? authorization;

  const CompanyUserEditDialog({
    super.key,
    required this.user,
    required this.branches,
    required this.allowedRoles,
    required this.canChangeRole,
    required this.canChangeStatus,
    this.isSelf = false,
    this.canEditMetadata = true,
    this.authorization,
  });

  @override
  State<CompanyUserEditDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<CompanyUserEditDialog> {
  late String _initialBranchCode;
  bool _authorityLost = false;

  void _authorizationChanged() {
    if (_authorityLost || widget.authorization == null ||
        widget.authorization!.isCurrent) return;
    _authorityLost = true;
    // Remove the exact dialog route, never a newer route above it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nameCtrl.clear();
      _phoneCtrl.clear();
      _usernameCtrl.clear();
      _invitationEmailCtrl.clear();
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _authorizationChanged();
  }


  List<Map<String, String>> get _startupBranches {
    final scope = widget.user['allowed_branches'];
    final all = scope == null ||
        (scope is List && (scope.isEmpty || scope.any((v) => v.toString().toLowerCase() == 'all'))) ||
        (scope is String && scope.toLowerCase() == 'all');
    final result = <Map<String, String>>[
      {'code': 'all', 'name': 'كل الفروع المسموحة'},
    ];
    final seen = <String>{'all'};
    for (final branch in widget.branches) {
      final code = branch['code'] ?? '';
      if (code.isNotEmpty && seen.add(code) &&
          (all || (scope is List && scope.contains(code)) || scope == code)) {
        result.add(branch);
      }
    }
    if (!result.any((branch) => branch['code'] == _initialBranchCode)) {
      result.add({'code': _initialBranchCode,
        'name': '$_initialBranchCode (غير متاح حالياً)', 'unavailable': 'true'});
    }
    return result;
  }

  late final _nameCtrl;
  late final TextEditingController _invitationEmailCtrl;
  late final _phoneCtrl;
  late final _usernameCtrl;
  late String _branchCode;
  late String _role;
  late String _status;
  late String _initialStatus;

  @override
  void initState() {
    super.initState();
    _invitationEmailCtrl = TextEditingController(text: (widget.user['invitation_email'] ?? '').toString());
    _nameCtrl =
        TextEditingController(text: (widget.user['name'] ?? '').toString());
    _phoneCtrl = TextEditingController(
        text: (widget.user['phone_number'] ?? '').toString());
    _usernameCtrl = TextEditingController(
        text: (widget.user['username'] ?? '').toString());
    _branchCode = (widget.user['startup_branch_code'] ?? widget.user['branch_code'] ?? '').toString();
    if (_branchCode.isEmpty) _branchCode = 'all';
    _role = widget.allowedRoles.containsKey(
            (widget.user['role'] ?? '').toString())
        ? (widget.user['role'] ?? '').toString()
        : (widget.allowedRoles.isNotEmpty
            ? widget.allowedRoles.keys.first
            : 'employee');
    _initialStatus = (widget.user['status'] ?? 'active').toString();
    _status = widget.user['is_active'] == false ? 'blocked' : _initialStatus;

    _initialBranchCode = _branchCode;
    ReadAuthorizationEpoch.changes.addListener(_authorizationChanged);
    _authorizationChanged();
  }

  @override
  void dispose() {
    ReadAuthorizationEpoch.changes.removeListener(_authorizationChanged);
    _invitationEmailCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    _authorizationChanged();
    if (_authorityLost) return;
    final name = _nameCtrl.text.trim();
    if (widget.canEditMetadata && name.isEmpty) return _error('الاسم مطلوب');
    Navigator.pop(context, {
      if (widget.canEditMetadata) 'name': name,
      if (widget.canEditMetadata && widget.user['can_set_invitation_email'] == true)
        'invitation_email': _invitationEmailCtrl.text.trim(),
      if (widget.canEditMetadata) 'phone_number': _phoneCtrl.text.trim(),
      if (widget.canEditMetadata && _branchCode != _initialBranchCode)
        'branch_code': _branchCode == 'all' ? '' : _branchCode,
      if (widget.canChangeRole) 'role': _role,
      if (widget.canEditMetadata) 'username': _usernameCtrl.text.trim(),
      if (widget.canChangeStatus && _status != 'blocked') 'status': _status,
      if (widget.canChangeStatus) 'is_active': _status != 'blocked',
    });
  }

  void _error(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppTheme.dangerFor(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_authorityLost) return const SizedBox.shrink();
    final email = (widget.user['email'] ?? '').toString();
    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: Text('تعديل المستخدم ($email)',
          style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMainFor(context),
              fontWeight: FontWeight.bold,
              fontSize: 14)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.canEditMetadata) ...[
              if (widget.user['can_set_invitation_email'] == true) ...[
                _field(_invitationEmailCtrl, 'بريد الدعوة (مطلوب)', Icons.email_rounded, keyboardType: TextInputType.emailAddress),
                const SizedBox(height: 10),
              ],
              _field(_nameCtrl, 'الاسم الكامل', Icons.person_rounded),
              const SizedBox(height: 10),
              _field(_phoneCtrl, 'رقم الموبايل', Icons.phone_rounded,
                  keyboardType: TextInputType.phone),
              const SizedBox(height: 10),
              _dropdown('فرع بداية الاستخدام', Icons.storefront_rounded, _branchCode,
                    _startupBranches
                        .map((b) => DropdownMenuItem<String>(
                            enabled: b['unavailable'] != 'true',
                            value: b['code'] ?? '',
                            child: Text(b['name'] ?? b['code']!,
                                style:
                                    const TextStyle(fontFamily: 'Cairo'))))
                        .toList(),
                    (v) => setState(() => _branchCode = v ?? 'all')),
              const SizedBox(height: 6),
              Text('لا يغيّر الفروع المسموحة أو فرع العمل.',
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 11,
                      color: AppTheme.textMutedFor(context))),
              ],
              if (widget.canChangeRole && widget.allowedRoles.isNotEmpty) ...[
                const SizedBox(height: 10),
                _dropdown('نوع المستخدم', Icons.badge_rounded, _role,
                    widget.allowedRoles.entries
                        .map((e) => DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(e.value,
                                style:
                                    const TextStyle(fontFamily: 'Cairo'))))
                        .toList(),
                    (v) => setState(() => _role = v ?? 'employee')),
              ],
              if (widget.canChangeStatus) ...[
                const SizedBox(height: 10),
                _dropdown('الحالة', Icons.verified_user_rounded, _status,
                    [
                      if (_initialStatus == 'pending' || _status == 'pending')
                        const DropdownMenuItem(value: 'pending', child: Text('معلق', style: TextStyle(fontFamily: 'Cairo'))),
                      const DropdownMenuItem(
                          value: 'active',
                          child: Text('نشط',
                              style: TextStyle(fontFamily: 'Cairo'))),
                      const DropdownMenuItem(value: 'blocked', child: Text('محظور', style: TextStyle(fontFamily: 'Cairo'))),
                      const DropdownMenuItem(
                          value: 'suspended',
                          child: Text('موقوف',
                              style: TextStyle(fontFamily: 'Cairo'))),
                    ],
                    (v) => setState(() => _status = v ?? 'active')),
              ],
              if (widget.canEditMetadata) ...[
                const SizedBox(height: 10),
                _field(_usernameCtrl, 'اسم المستخدم', Icons.alternate_email_rounded),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('إلغاء',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context)))),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentFor(context),
            foregroundColor: AppTheme.onAccentFor(context),
          ),
          child: const Text('حفظ',
              style: TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {TextInputType? keyboardType}) {
    return TextField(
      controller: c,
      keyboardType: keyboardType,
      style: TextStyle(
          fontFamily: 'Cairo', color: AppTheme.textMainFor(context)),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        labelStyle: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textSoftFor(context),
            fontSize: 12),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
      ),
    );
  }

  Widget _dropdown<T>(String label, IconData icon, T value,
      List<DropdownMenuItem<T>> items, ValueChanged<T?> onChanged) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      items: items,
      onChanged: onChanged,
      dropdownColor: AppTheme.dropdownBackground(context),
      style: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMainFor(context),
          fontSize: 13),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        labelStyle: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textSoftFor(context),
            fontSize: 12),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
      ),
    );
  }
}