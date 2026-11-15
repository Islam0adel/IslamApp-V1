// lib/views/dashboard/company_users_page.dart

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/theme.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';
import '../../services/permissions_service.dart';

// ============================================================
// Company Users Page — إدارة مستخدمي الشركة
//
// Roles:
//   - super_admin: يختار الشركة + يضيف admin/employee + تعديل/حذف
//   - admin: شركته فقط + يضيف employee + تعديل/حذف موظفين
// ============================================================

class CompanyUsersPage extends StatefulWidget {
  final String companyCode; // '' = super_admin (يختار)
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
  final ApiService _api = ApiService();

  List<dynamic> _companies = [];
  List<dynamic> _users = [];

  String _selectedCompanyCode = '';
  String _selectedCompanyName = '';

  bool _isLoading = true;
  String? _error;

  String _searchQuery = '';
  String? _filterStatus; // null=all, pending, active, suspended

  String _actorEmail = '';

  @override
  void initState() {
    super.initState();
    _selectedCompanyCode = widget.companyCode;
    _selectedCompanyName = widget.companyName;
    _loadActorEmail();
    _loadAll();
    _loadRequests();
  }

  Future<void> _loadActorEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _actorEmail = (prefs.getString('user_email') ?? '').toLowerCase().trim();
    } catch (_) {}
  }

  // ============================================================
  // Loading
  // ============================================================

  Future<void> _loadAll() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // 1. لو super_admin → جيب قائمة الشركات
      if (PermissionsService().isSuperAdmin) {
        try {
          _companies = await _api.getAllCompanies('99');
        } catch (e) {
          print('⚠️ load companies: $e');
          _companies = [];
        }

        // اختار أول شركة لو مش محدد
        if (_selectedCompanyCode.isEmpty && _companies.isNotEmpty) {
          _selectedCompanyCode =
              (_companies.first['code'] ?? '').toString();
          _selectedCompanyName =
              (_companies.first['name'] ?? '').toString();
        }
      }

      // 2. جيب المستخدمين
      if (_selectedCompanyCode.isNotEmpty) {
        _users = await _api.getCompanyUsers(
          companyCode: _selectedCompanyCode,
        );
      } else {
        _users = [];
      }

      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _onCompanyChanged(String? code) async {
    if (code == null || code == _selectedCompanyCode) return;
    final company = _companies.firstWhere(
      (c) => (c['code'] ?? '').toString() == code,
      orElse: () => {'code': code, 'name': ''},
    );
    setState(() {
      _selectedCompanyCode = code;
      _selectedCompanyName = (company['name'] ?? '').toString();
      _users = [];
    });
    await _loadAll();
    await _loadRequests();
  }

  // ============================================================
  // Filters
  // ============================================================

  List<dynamic> get _filteredUsers {
    List<dynamic> result = List.from(_users);

    if (_filterStatus != null && _filterStatus!.isNotEmpty) {
      result = result
          .where((u) => (u['status'] ?? 'active') == _filterStatus)
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
  // Branches Helper
  // ============================================================

  List<Map<String, String>> _branchesFor(String companyCode) {
    final branches = <Map<String, String>>[];
    if (companyCode.isEmpty) return branches;

    try {
      final box = Hive.box('coding_box');
      final raw = box.get(
        '${companyCode}_branches',
        defaultValue: [],
      ) as List? ?? [];

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

  // ============================================================
  // Add User
  // ============================================================

  Future<void> _showAddUserDialog() async {
    if (_selectedCompanyCode.isEmpty) {
      _showSnackBar(
        'اختر شركة أولاً',
        AppTheme.warningOrangeFor(context),
      );
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

    // ⭐ أضف "كل الفروع" في الأول
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
      await _api.adminAddUser(
        name: (result['name'] as String?) ?? '',
        phoneNumber: (result['phone_number'] as String?) ?? '',
        branchCode: result['branch_code'] as String,
        role: result['role'] as String,
        companyCode: _selectedCompanyCode,
        email: (result['email'] as String?) ?? '',
        username: result['username'] as String?,
      );
      if (!mounted) return;

      // ⭐ اسم بديل لو فاضي
      final displayName = (result['name'] as String?)?.trim().isNotEmpty == true
          ? result['name']
          : ((result['email'] as String?)?.trim().isNotEmpty == true
              ? result['email']
              : result['phone_number']);

      _showSnackBar(
        'تمت إضافة $displayName بنجاح ✅',
        AppTheme.successStrongFor(context),
      );
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
  }

  // ============================================================
  // Edit User
  // ============================================================

  Future<void> _showEditUserDialog(dynamic user) async {
    final email = (user['email'] ?? '').toString();
    if (email.isEmpty) {
      _showSnackBar(
        'المستخدم بدون بريد إلكتروني — لا يمكن تعديله',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final branches = _branchesFor(_selectedCompanyCode);
    final userRole = _userRole(user);
    final isSuperAdmin = PermissionsService().isSuperAdmin;
    final isSelf = _isCurrentUser(user);

    // ⭐ السوبر أدمن لا يقدر يغيّر دوره/حالته
    final canChangeRole = isSuperAdmin && userRole != 'super_admin';
    final canChangeStatus = isSuperAdmin && userRole != 'super_admin';

    // ⭐ قائمة الأدوار المسموحة
    Map<String, String> allowedRoles = {};
    if (canChangeRole) {
      allowedRoles = {
        'employee': 'موظف عادي',
        if (userRole != 'admin') 'admin': 'مدير شركة',
      };
    }

    if (!canChangeRole && !canChangeStatus && userRole == 'super_admin' && !isSuperAdmin) {
      _showSnackBar(
        'غير مسموح بتعديل هذا المستخدم',
        AppTheme.dangerFor(context),
      );
      return;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _EditUserDialog(
        user: user,
        branches: branches,
        allowedRoles: allowedRoles,
        canChangeRole: canChangeRole,
        canChangeStatus: canChangeStatus,
        isSelf: isSelf,
      ),
    );

    if (result == null || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await _api.adminEditUser(
        email: email,
        name: result['name'] as String?,
        phoneNumber: result['phone_number'] as String?,
        branchCode: result['branch_code'] as String?,
        role: result['role'] as String?,
        username: result['username'] as String?,
        status: result['status'] as String?,
      );
      if (!mounted) return;
      _showSnackBar(
        'تم التحديث بنجاح ✅',
        AppTheme.successStrongFor(context),
      );
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
  }

  // ============================================================
  // Delete User
  // ============================================================

  Future<void> _confirmDelete(dynamic user) async {
    final email = (user['email'] ?? '').toString();
    final name = (user['name'] ?? '').toString();
    if (email.isEmpty) {
      _showSnackBar(
        'لا يمكن حذف مستخدم بدون بريد',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Text(
          'حذف المستخدم',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMainFor(context),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'سيتم حذف "$name" نهائياً.\n'
          'سيتم حذف حسابه من Firebase والبيانات.',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMutedFor(context),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'إلغاء',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'حذف',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.dangerStrongFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await _api.adminDeleteUser(email: email);
      if (!mounted) return;
      _showSnackBar(
        'تم حذف $name',
        AppTheme.warningOrangeFor(context),
      );
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
  }

  // ============================================================
  // Reset Pending User
  // ============================================================

  Future<void> _confirmResetPending(dynamic user) async {
    final email = (user['email'] ?? '').toString();
    final name = (user['name'] ?? '').toString();
    if (email.isEmpty) {
      _showSnackBar(
        'لا يمكن إعادة التعيين بدون بريد',
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
        title: Text(
          'إعادة السماح بالتسجيل',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMainFor(context),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'سيتم إعادة تعيين "$name":\n'
          '• مسح الحساب من Firebase\n'
          '• مسح البريد وكلمة المرور\n'
          '• العودة لحالة "بانتظار إكمال التسجيل"\n\n'
          'المستخدم سيقدر يدخل رقمه من جديد ويكمل التسجيل.',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMutedFor(context),
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'إلغاء',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'إعادة تعيين',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.warningOrangeFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await _api.adminResetPendingUser(email: email);
      if (!mounted) return;
      _showSnackBar(
        'تم إعادة تعيين $name — يمكنه التسجيل من جديد',
        AppTheme.successStrongFor(context),
      );
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
  }

  // ============================================================
  // Helpers
  // ============================================================

  String _userRole(dynamic user) {
    final role = (user['role'] ?? '').toString().trim();
    if (role.isNotEmpty) return role;
    final jobCode = (user['job_code'] ?? '1').toString();
    switch (jobCode) {
      case '99':
        return 'super_admin';
      case '201':
        return 'admin';
      case '200':
      case '1':
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
      case 'employee':
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
      case 'employee':
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
      case 'employee':
      default:
        return AppTheme.accentFor(context);
    }
  }

    bool _isCurrentUser(dynamic user) {
    if (_actorEmail.isEmpty) return false;
    final userEmail = (user['email'] ?? '').toString().toLowerCase().trim();
    return userEmail.isNotEmpty && userEmail == _actorEmail;
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'pending':
        return 'بانتظار التسجيل';
      case 'suspended':
        return 'موقوف';
      case 'active':
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
      case 'active':
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
      case 'active':
      default:
        return Icons.check_circle_rounded;
    }
  }

  void _showSnackBar(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: color,
      ),
    );
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // حماية: مستخدم عادي ما يدخلش
    if (!PermissionsService().canManageUsers) {
      return _buildNoPermissionScreen();
    }

    final filtered = _filteredUsers;
    final pending = _users.where((u) => u['status'] == 'pending').length;
    final active = _users.where((u) => u['status'] == 'active').length;
    final suspended = _users.where((u) => u['status'] == 'suspended').length;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          _selectedCompanyName.isEmpty
              ? 'إدارة المستخدمين'
              : 'مستخدمو $_selectedCompanyName',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMainFor(context),
          ),
        ),
        centerTitle: true,
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: Icon(
              Icons.refresh_rounded,
              color: AppTheme.textMainFor(context),
            ),
            onPressed: _isLoading ? null : _loadAll,
          ),
        ],
      ),
      floatingActionButton: _isLoading
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTheme.accentFor(context),
              foregroundColor: Colors.white,
              onPressed: _showAddUserDialog,
              icon: const Icon(Icons.person_add_rounded),
              label: const Text(
                'إضافة مستخدم',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                ),
              ),
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
                  child: CircularProgressIndicator(
                    color: AppTheme.accentFor(context),
                  ),
                )
              : _error != null
                  ? _buildErrorState()
                  : _buildContent(pending, active, suspended, filtered),
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
            Icon(
              Icons.error_outline_rounded,
              size: 60,
              color: AppTheme.dangerFor(context),
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? 'حدث خطأ',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadAll,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text(
                'إعادة المحاولة',
                style: TextStyle(fontFamily: 'Cairo'),
              ),
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
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'إدارة المستخدمين',
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMainFor(context),
          ),
        ),
        centerTitle: true,
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
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
          child: Center(
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
                  'ليس لديك صلاحية إدارة المستخدمين',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    int pending,
    int active,
    int suspended,
    List<dynamic> filtered,
  ) {
    return Column(
      children: [
        // Company Selector (super_admin)
        if (PermissionsService().isSuperAdmin && _companies.isNotEmpty)
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
                    fontSize: 14,
                  ),
                  icon: Icon(
                    Icons.expand_more_rounded,
                    color: AppTheme.accentFor(context),
                  ),
                  items: _companies.map((c) {
                    final code = (c['code'] ?? '').toString();
                    final name = (c['name'] ?? '').toString();
                    return DropdownMenuItem<String>(
                      value: code,
                      child: Row(
                        children: [
                          Icon(
                            Icons.business_rounded,
                            color: AppTheme.accentFor(context),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$name ($code)',
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                color: AppTheme.textMainFor(context),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
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

        // Stats
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 15, 15, 8),
          child: GlassCard(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: _statChip(
                    'نشط',
                    '$active',
                    AppTheme.successStrongFor(context),
                    Icons.check_circle_rounded,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _statChip(
                    'معلق',
                    '$pending',
                    AppTheme.warningOrangeFor(context),
                    Icons.schedule_rounded,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _statChip(
                    'موقوف',
                    '$suspended',
                    AppTheme.dangerStrongFor(context),
                    Icons.block_rounded,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Search + Filter
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
                    color: AppTheme.textMainFor(context),
                  ),
                  decoration: InputDecoration(
                    hintText: 'بحث بالاسم / إيميل / موبايل',
                    hintStyle: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMutedFor(context),
                      fontSize: 13,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: AppTheme.accentFor(context),
                    ),
                    border: InputBorder.none,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 14),
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
        // ⭐ طلبات الانضمام
        _buildRequestsSection(),

        // List
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadAll,
                  color: AppTheme.accentFor(context),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(15, 8, 15, 80),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
                    itemBuilder: (_, i) =>
                        _buildUserCard(filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _statChip(
    String label,
    String value,
    Color color,
    IconData icon,
  ) {
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
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Cairo',
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMutedFor(context),
              fontSize: 10,
            ),
          ),
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
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            color: color,
            fontSize: 12,
            fontWeight:
                selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
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
            Icon(
              Icons.people_outline_rounded,
              size: 60,
              color: AppTheme.textMutedFor(context),
            ),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty || _filterStatus != null
                  ? 'لا توجد نتائج مطابقة'
                  : 'لا يوجد مستخدمون بعد',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
              ),
            ),
            if (_users.isEmpty) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _showAddUserDialog,
                icon: const Icon(Icons.person_add_rounded),
                label: const Text(
                  'إضافة أول مستخدم',
                  style: TextStyle(fontFamily: 'Cairo'),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentFor(context),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
    // ============================================================
  // طلبات الانضمام
  // ============================================================

  List<dynamic> _pendingRequests = [];
  bool _loadingRequests = false;

  Future<void> _loadRequests() async {
    setState(() => _loadingRequests = true);
    try {
      final requests = await _api.getRegistrationRequests(status: 'pending');
      if (!mounted) return;
      setState(() {
        _pendingRequests = requests;
        _loadingRequests = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRequests = false);
    }
  }

  Widget _buildRequestsSection() {
    if (_loadingRequests) return const SizedBox.shrink();
    if (_pendingRequests.isEmpty) return const SizedBox.shrink();

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
                Text(
                  'طلبات الانضمام المعلقة',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMainFor(context),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.warningOrangeFor(context)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_pendingRequests.length}',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.warningOrangeFor(context),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._pendingRequests.take(3).map((r) => _buildRequestRow(r)),
            if (_pendingRequests.length > 3) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _showAllRequests(),
                  child: Text(
                    'عرض الكل',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.accentFor(context),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRequestRow(dynamic r) {
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
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMainFor(context),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              if (phone.isNotEmpty)
                _infoChip(Icons.phone_rounded, phone),
              if (email.isNotEmpty)
                _infoChip(Icons.email_rounded, email),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _rejectRequest(id, name),
                child: Text(
                  'رفض',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppTheme.dangerFor(context),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _approveRequest(id, name),
                child: Text(
                  'موافقة',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppTheme.successStrongFor(context),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _approveRequest(String requestId, String name) async {
    // ابحث عن الطلب
    dynamic request;
    try {
      request = _pendingRequests.firstWhere(
        (r) => (r['id'] ?? '').toString() == requestId,
      );
    } catch (_) {
      _showSnackBar('الطلب غير موجود', AppTheme.dangerFor(context));
      return;
    }

    final requestCompanyCode = (request['company_code'] ?? '').toString();
    final isSuperAdmin = PermissionsService().isSuperAdmin;
    final needsCompany = requestCompanyCode.isEmpty && isSuperAdmin;

    // ⭐ لو الطلب مش محدد شركة والمستخدم admin عادي → مرفوض
    if (requestCompanyCode.isEmpty && !isSuperAdmin) {
      _showSnackBar(
        'الطلب غير مرتبط بشركة — يجب أن يوافق عليه السوبر أدمن',
        AppTheme.dangerFor(context),
      );
      return;
    }

    // ⭐ جيب قائمة الشركات لو محتاج
    List<dynamic> companies = [];
    if (needsCompany) {
      try {
        companies = await _api.getAllCompanies('99');
      } catch (_) {
        companies = [];
      }
    }

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
            title: Text(
              'موافقة على $name',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ⭐ Company dropdown (لو محتاج)
                  if (needsCompany) ...[
                    DropdownButtonFormField<String>(
                      initialValue: company.isEmpty ? null : company,
                      isExpanded: true,
                      dropdownColor: AppTheme.dropdownBackground(context),
                      decoration: const InputDecoration(
                        labelText: 'الشركة (مطلوب)',
                      ),
                      items: companies.map((c) {
                        final code = (c['code'] ?? '').toString();
                        final cname = (c['name'] ?? '').toString();
                        return DropdownMenuItem(
                          value: code,
                          child: Text('$cname ($code)',
                              style: const TextStyle(fontFamily: 'Cairo')),
                        );
                      }).toList(),
                      onChanged: (v) => setLocal(() => company = v ?? ''),
                    ),
                    const SizedBox(height: 10),
                  ],
                  // Role
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    decoration:
                        const InputDecoration(labelText: 'نوع المستخدم'),
                    items: allowedRoles.entries
                        .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value,
                                  style:
                                      const TextStyle(fontFamily: 'Cairo')),
                            ))
                        .toList(),
                    onChanged: (v) => setLocal(() => role = v ?? role),
                  ),
                  const SizedBox(height: 10),
                  // Branch
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
                        color: AppTheme.textMutedFor(context))),
              ),
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

    try {
      await _api.approveRegistrationRequest(
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
      _loadRequests();
      _loadAll();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
  }

  Future<void> _rejectRequest(String requestId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
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

    try {
      await _api.rejectRegistrationRequest(requestId: requestId);
      if (!mounted) return;
      _showSnackBar('تم الرفض', AppTheme.warningOrangeFor(context));
      _loadRequests();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(e.toString(), AppTheme.dangerFor(context));
    }
  }

  void _showAllRequests() {
    // فتح صفحة كاملة بقائمة الطلبات (اختياري)
    _showSnackBar(
      'عرض ${_pendingRequests.length} طلب — قم بالموافقة/الرفض من القائمة',
      AppTheme.infoFor(context),
    );
  }

  Widget _buildUserCard(dynamic user) {
    final name = (user['name'] ?? '').toString().trim();
    final email = (user['email'] ?? '').toString().trim();
    final phone = (user['phone_number'] ?? '').toString().trim();

    // ⭐ لو مفيش اسم → اعرض email أو phone
    final displayName = name.isNotEmpty
        ? name
        : (email.isNotEmpty
            ? email
            : (phone.isNotEmpty ? phone : '—'));

    final isAnonymous = name.isEmpty;
    final branchCode = (user['branch_code'] ?? '').toString();
    final status = (user['status'] ?? 'active').toString();
    final emailVerified = user['email_verified'] == true;
    final requiresVerification =
        user['requires_email_verification'] == true;
    final hasAccount = user['has_account'] == true;
    final username = (user['username'] ?? '').toString();

    final role = _userRole(user);
    final roleLabel = _roleLabel(role);
    final roleColor = _roleColor(role);
    final statusColor = _statusColor(status);

    // هل يمكن تعديل/حذف؟
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
                child: Icon(
                  _roleIcon(role),
                  color: roleColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        color: isAnonymous
                            ? AppTheme.textMutedFor(context)
                            : AppTheme.textMainFor(context),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        fontStyle: isAnonymous
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        Text(
                          roleLabel,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            color: roleColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 3,
                          height: 3,
                          decoration: BoxDecoration(
                            color: AppTheme.textMutedFor(context),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _statusIcon(status),
                                color: statusColor,
                                size: 10,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                _statusLabel(status),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  color: statusColor,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
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
              if (phone.isNotEmpty)
                _infoChip(Icons.phone_rounded, phone),
              if (email.isNotEmpty)
                _infoChip(Icons.email_rounded, email),
              if (username.isNotEmpty)
                _infoChip(Icons.alternate_email_rounded, '@$username'),
              if (branchCode.isNotEmpty)
                _infoChip(Icons.storefront_rounded, 'فرع $branchCode')
              else
                _infoChip(
                  Icons.public_rounded,
                  'كل الفروع (موظف عام)',
                  color: AppTheme.infoFor(context),
                ),
              if (status == 'active' &&
                  requiresVerification &&
                  !emailVerified)
                _infoChip(
                  Icons.mark_email_unread_rounded,
                  'بانتظار التحقق من البريد',
                  color: AppTheme.warningOrangeFor(context),
                ),
              if (status == 'pending')
                _infoChip(
                  Icons.info_outline_rounded,
                  'بانتظار إكمال التسجيل',
                  color: AppTheme.infoFor(context),
                ),
              if (status == 'active' && !hasAccount)
                _infoChip(
                  Icons.error_outline_rounded,
                  'بدون حساب',
                  color: AppTheme.dangerFor(context),
                ),
            ],
          ),

          // Actions
          if (canEditThis || canDeleteThis || canResetThis) ...[
            const SizedBox(height: 8),
            Divider(
              color: GlassStyle.line10For(context),
              height: 1,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (canResetThis)
                  TextButton.icon(
                    onPressed: () => _confirmResetPending(user),
                    icon: Icon(
                      Icons.restart_alt_rounded,
                      size: 14,
                      color: AppTheme.warningOrangeFor(context),
                    ),
                    label: Text(
                      'إعادة تعيين',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: AppTheme.warningOrangeFor(context),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (canEditThis)
                  TextButton.icon(
                    onPressed: () => _showEditUserDialog(user),
                    icon: Icon(
                      Icons.edit_rounded,
                      size: 14,
                      color: AppTheme.accentFor(context),
                    ),
                    label: Text(
                      'تعديل',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: AppTheme.accentFor(context),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (canDeleteThis)
                  TextButton.icon(
                    onPressed: () => _confirmDelete(user),
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 14,
                      color: AppTheme.dangerFor(context),
                    ),
                    label: Text(
                      'حذف',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: AppTheme.dangerFor(context),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _canEditUser(dynamic user) {
    final role = _userRole(user);
    // ⭐ Super Admin يقدر يعدل أي حد (حتى super_admin نفسه)
    if (PermissionsService().isSuperAdmin) return true;
    // Admin يقدر يعدل الموظفين فقط
    if (PermissionsService().currentRole == 'admin') {
      return role == 'employee';
    }
    return false;
  }

  bool _canDeleteUser(dynamic user) {
    final role = _userRole(user);
    // ⭐ Super Admin لا يمكن حذفه (حماية)
    if (role == 'super_admin') return false;

    if (PermissionsService().isSuperAdmin) return true;
    if (PermissionsService().currentRole == 'admin') {
      return role == 'employee';
    }
    return false;
  }

  bool _canResetUser(dynamic user) {
    final role = _userRole(user);
    // ⭐ Super Admin لا يمكن إعادة تعيينه (حماية — سيفقد حسابه)
    if (role == 'super_admin') return false;

    final status = (user['status'] ?? '').toString();
    final hasAccount = user['has_account'] == true;
    final isStuck = status == 'pending' || !hasAccount;

    if (!isStuck) return false;

    if (PermissionsService().isSuperAdmin) return true;
    if (PermissionsService().currentRole == 'admin') {
      return role == 'employee';
    }
    return false;
  }

  Widget _infoChip(IconData icon, String text, {Color? color}) {
    final c = color ?? AppTheme.textMutedFor(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: c),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontFamily: 'Cairo',
            color: c,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// Add User Dialog
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
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final email = _emailCtrl.text.trim().toLowerCase();

    // ⭐ phone OR email مطلوب
    if (phone.isEmpty && email.isEmpty) {
      return _error('رقم الموبايل أو الإيميل مطلوب (واحد على الأقل)');
    }

    // لو phone موجود، تحقق من الصيغة
    if (phone.isNotEmpty && !RegExp(r'^[0-9]{8,15}$').hasMatch(phone)) {
      return _error('رقم الموبايل غير صحيح');
    }

    // لو email موجود، تحقق من الصيغة
    if (email.isNotEmpty &&
        !RegExp(r'^[\w\.-]+@[\w\.-]+\.[a-zA-Z]{2,}$').hasMatch(email)) {
      return _error('صيغة البريد الإلكتروني غير صحيحة');
    }

    if (_branchCode.isEmpty) return _error('اختر الفرع');

    Navigator.pop(context, {
      'name': name, // ممكن يكون فاضي
      'phone_number': phone, // ممكن يكون فاضي
      'email': email, // ممكن يكون فاضي
      'branch_code': _branchCode,
      'role': _role,
      'username': _usernameCtrl.text.trim(),
    });
  }

  void _error(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: AppTheme.dangerFor(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
      ),
      title: Row(
        children: [
          Icon(Icons.person_add_rounded,
              color: AppTheme.accentFor(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'إضافة مستخدم — ${widget.companyName}',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(
                controller: _nameCtrl,
                label: 'الاسم الكامل (اختياري)',
                icon: Icons.person_rounded,
                hint: 'اتركه فاضي لو مش عايز',
              ),
              const SizedBox(height: 10),
              // ⭐ تنبيه: phone OR email
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.warningOrangeFor(context).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.warningOrangeFor(context).withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: AppTheme.warningOrangeFor(context),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'رقم الموبايل أو الإيميل — واحد على الأقل',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.warningOrangeFor(context),
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _field(
                controller: _phoneCtrl,
                label: 'رقم الموبايل',
                icon: Icons.phone_rounded,
                keyboardType: TextInputType.phone,
                hint: '01xxxxxxxxx',
              ),
              const SizedBox(height: 10),
              _dropdown<String>(
                label: 'الفرع',
                icon: Icons.storefront_rounded,
                value: _branchCode,
                items: widget.branches
                    .map((b) => DropdownMenuItem<String>(
                          value: b['code'] ?? '',
                          child: Text(
                            b['name'] ?? b['code']!,
                            style:
                                const TextStyle(fontFamily: 'Cairo'),
                          ),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _branchCode = v ?? ''),
              ),
              const SizedBox(height: 10),
              _dropdown<String>(
                label: 'نوع المستخدم',
                icon: Icons.badge_rounded,
                value: _role,
                items: widget.allowedRoles.entries
                    .map((e) => DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(
                            e.value,
                            style:
                                const TextStyle(fontFamily: 'Cairo'),
                          ),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _role = v ?? 'employee'),
              ),
              const SizedBox(height: 10),
              _field(
                controller: _emailCtrl,
                label: 'البريد الإلكتروني',
                icon: Icons.email_rounded,
                keyboardType: TextInputType.emailAddress,
                hint: 'user@example.com',
              ),
              const SizedBox(height: 10),
              _field(
                controller: _usernameCtrl,
                label: 'اسم المستخدم (اختياري)',
                icon: Icons.alternate_email_rounded,
                hint: 'user_2024',
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color:
                      AppTheme.infoFor(context).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.infoFor(context)
                        .withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: AppTheme.infoFor(context),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'المستخدم هيكمل التسجيل بنفسه بعد ما يدخل رقمه. '
                        'حالته هتظهر "بانتظار إكمال التسجيل".',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppTheme.infoFor(context),
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'إلغاء',
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMutedFor(context),
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentFor(context),
            foregroundColor: Colors.white,
          ),
          child: const Text(
            'إضافة',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: TextStyle(
        fontFamily: 'Cairo',
        color: AppTheme.textMainFor(context),
      ),
      decoration: InputDecoration(
        prefixIcon:
            Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMutedFor(context),
          fontSize: 11,
        ),
        labelStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textSoftFor(context),
          fontSize: 12,
        ),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _dropdown<T>({
    required String label,
    required IconData icon,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      items: items,
      onChanged: onChanged,
      style: TextStyle(
        fontFamily: 'Cairo',
        color: AppTheme.textMainFor(context),
        fontSize: 13,
      ),
      dropdownColor: AppTheme.dropdownBackground(context),
      decoration: InputDecoration(
        prefixIcon:
            Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        labelStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textSoftFor(context),
          fontSize: 12,
        ),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ============================================================
// Edit User Dialog
// ============================================================
class _EditUserDialog extends StatefulWidget {
  final dynamic user;
  final List<Map<String, String>> branches;
  final Map<String, String> allowedRoles;
  final bool canChangeRole;
  final bool canChangeStatus;
  final bool isSelf;

  const _EditUserDialog({
    required this.user,
    required this.branches,
    required this.allowedRoles,
    required this.canChangeRole,
    required this.canChangeStatus,
    this.isSelf = false,
  });

  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  late final _nameCtrl;
  late final _phoneCtrl;
  late final _usernameCtrl;
  late String _branchCode;
  late String _role;
  late String _status;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
      text: (widget.user['name'] ?? '').toString(),
    );
    _phoneCtrl = TextEditingController(
      text: (widget.user['phone_number'] ?? '').toString(),
    );
    _usernameCtrl = TextEditingController(
      text: (widget.user['username'] ?? '').toString(),
    );
    _branchCode = (widget.user['branch_code'] ?? '').toString();
    if (widget.allowedRoles.isNotEmpty) {
      _role = widget.allowedRoles.containsKey(
              (widget.user['role'] ?? '').toString())
          ? (widget.user['role'] ?? '').toString()
          : widget.allowedRoles.keys.first;
    } else {
      _role = (widget.user['role'] ?? 'employee').toString();
    }
    _status = (widget.user['status'] ?? 'active').toString();

    // لو الفرع مش في القائمة، اتركه فاضي
    if (!widget.branches.any((b) => b['code'] == _branchCode)) {
      _branchCode = widget.branches.isNotEmpty
          ? (widget.branches.first['code'] ?? '')
          : '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();

    if (name.isEmpty) return _error('الاسم مطلوب');
    if (phone.isNotEmpty &&
        !RegExp(r'^[0-9]{8,15}$').hasMatch(phone)) {
      return _error('رقم الموبايل غير صحيح');
    }

    Navigator.pop(context, {
      'name': name,
      'phone_number': phone,
      'branch_code': _branchCode,
      if (widget.canChangeRole) 'role': _role,
      'username': _usernameCtrl.text.trim(),
      if (widget.canChangeStatus) 'status': _status,
    });
  }

  void _error(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: AppTheme.dangerFor(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = (widget.user['email'] ?? '').toString();

    return AlertDialog(
      backgroundColor: AppTheme.dialogBackground(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
      ),
      title: Row(
        children: [
          Icon(Icons.edit_rounded, color: AppTheme.accentFor(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'تعديل المستخدم',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMainFor(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Text(
                  email,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppTheme.textMutedFor(context),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(
                controller: _nameCtrl,
                label: 'الاسم الكامل',
                icon: Icons.person_rounded,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _phoneCtrl,
                label: 'رقم الموبايل',
                icon: Icons.phone_rounded,
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 10),
              if (widget.branches.isNotEmpty)
                _dropdown<String>(
                  label: 'الفرع',
                  icon: Icons.storefront_rounded,
                  value: _branchCode,
                  items: widget.branches
                      .map((b) => DropdownMenuItem<String>(
                            value: b['code'] ?? '',
                            child: Text(
                              b['name'] ?? b['code']!,
                              style:
                                  const TextStyle(fontFamily: 'Cairo'),
                            ),
                          ))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _branchCode = v ?? ''),
                ),
              if (widget.branches.isNotEmpty)
                const SizedBox(height: 10),
              if (widget.canChangeRole && widget.allowedRoles.isNotEmpty)
                _dropdown<String>(
                  label: 'نوع المستخدم',
                  icon: Icons.badge_rounded,
                  value: _role,
                  items: widget.allowedRoles.entries
                      .map((e) => DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(e.value,
                                style: const TextStyle(fontFamily: 'Cairo')),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _role = v ?? 'employee'),
                ),
              if (widget.canChangeRole && widget.allowedRoles.isNotEmpty)
                const SizedBox(height: 10),
              if (widget.canChangeStatus)
                _dropdown<String>(
                  label: 'الحالة',
                  icon: Icons.verified_user_rounded,
                  value: _status,
                  items: const [
                    DropdownMenuItem<String>(
                      value: 'active',
                      child: Text('نشط',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    DropdownMenuItem<String>(
                      value: 'suspended',
                      child: Text('موقوف',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                  ],
                  onChanged: (v) => setState(() => _status = v ?? 'active'),
                ),
              if (widget.canChangeStatus) const SizedBox(height: 10),
              const SizedBox(height: 10),
              _field(
                controller: _usernameCtrl,
                label: 'اسم المستخدم',
                icon: Icons.alternate_email_rounded,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'إلغاء',
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMutedFor(context),
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentFor(context),
            foregroundColor: Colors.white,
          ),
          child: const Text(
            'حفظ',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: TextStyle(
        fontFamily: 'Cairo',
        color: AppTheme.textMainFor(context),
      ),
      decoration: InputDecoration(
        prefixIcon:
            Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMutedFor(context),
          fontSize: 11,
        ),
        labelStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textSoftFor(context),
          fontSize: 12,
        ),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _dropdown<T>({
    required String label,
    required IconData icon,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      items: items,
      onChanged: onChanged,
      style: TextStyle(
        fontFamily: 'Cairo',
        color: AppTheme.textMainFor(context),
        fontSize: 13,
      ),
      dropdownColor: AppTheme.dropdownBackground(context),
      decoration: InputDecoration(
        prefixIcon:
            Icon(icon, color: AppTheme.textSoftFor(context), size: 18),
        labelText: label,
        labelStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textSoftFor(context),
          fontSize: 12,
        ),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}