// frontend/lib/views/dashboard/permissions_page.dart
import '../../services/page_visibility.dart';
import '../../services/cache_partitions.dart';
import '../../services/permission_bulk_edit.dart';
import '../widgets/permission_bulk_actions.dart';
import '../../services/permission_catalog.dart';
import '../widgets/permission_action_switch.dart';
import '../widgets/permission_editor_state.dart';
import '../../services/permission_hierarchy.dart';
import '../../services/permission_editor_snapshot.dart';
import '../../services/read_authorization_snapshot.dart';
import '../../services/websocket_sync_service.dart';
import 'dart:async'; // ← NEW: للـ StreamSubscription
import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import '../../core/theme.dart';
import '../../services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/permissions_service.dart';
import '../../services/presence_service.dart'; // ← NEW

// صفحة إدارة الصلاحيات
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

// حالة الويدجت PermissionsPage: تدير بيانات الشاشة وتفاعلاتها
class _PermissionsPageState extends State<PermissionsPage> {
  String? selectedUserId;
  String? selectedUserJobCode;
  String currentCompanyCode = '';
  bool _isLoading = true;
  PermissionEditorSnapshot? _editor;
  ReadAuthorizationSnapshot? _editorScope;
  String? _editorError;
  bool _saving = false;
  bool _revalidating = false;
  bool _revalidateAgain = false;
  String _startupBranch = '';

  // يعيد الفروع المحددة
  List<String> get _draftBranches =>
      _allowAllBranches ? ['all'] : List<String>.from(_selectedBranchCodes);

  // يحدد هل المحرر جاهز
  bool get _editorReady =>
      _editor != null &&
      _editorError == null &&
      !_saving &&
      !_revalidating &&
      (_editorScope?.isCurrent ?? false);

  // يحدد هل يمكن تبديل الصلاحية
  bool _canToggle(String category, String key, bool next) =>
      _editorReady &&
      _editor!.canToggle(category, key, next, userPermissions, _draftBranches);

  // يحدد هل يمكن تعديل الفرع
  bool _canEditBranch(String code) =>
      _editorReady && _editor!.canEditBranch(code, userPermissions);

  // يحدد هل يمكن تعديل الموظفين
  bool get _canEditEmployees =>
      _editorReady &&
      _editor!.canEditEmployees(userPermissions, _draftBranches);

  // ✅ NEW: حالة is_active للمستخدم المختار (افتراضي = نشط)
  bool _selectedUserIsActive = true;

  // يحدد هل الحساب جذري ذاتي
  bool get _rootSelfStatus =>
      _editor?.root == true && _editor?.data['is_self'] == true;

  // ⭐ HR: فلترة الموظفين
  List<String>? _hrViewableEmployees; // null/empty = كل الموظفين
  bool _allowAllEmployees = true;
  List<Map<String, String>> _allEmployees = [];

  Map<String, Map<String, bool>> userPermissions = {};
  Map<String, Map<String, bool>> _displayedPermissions = {};

  List<Map<String, dynamic>> usersList = [];
  List<Map<String, String>> _allBranches = [];
  bool _allowAllBranches = true;
  List<String> _selectedBranchCodes = [];

  Future<List<Map<String, dynamic>>>? _targetsFuture;
  ReadAuthorizationSnapshot? _directoryScope;
  bool _targetsLoading = false;
  bool _reloadTargetsPending = false;
  int _loadUserRequestId = 0;
  int _contextRequestId = 0;
  ReadAuthorizationSnapshot? _pageContext;

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    PermissionsService().addListener(_actorScopeChanged);
    WebSocketSyncService.userDirectoryChanges.addListener(_directoryHint);
    _loadCompanyCode();
  }

  // يستجيب لتغيّر دليل المستخدمين
  void _directoryHint() {
    final company = WebSocketSyncService.userDirectoryChanges.value.company;
    if (!mounted ||
        (currentCompanyCode.isNotEmpty && company != currentCompanyCode))
      return;
    _refreshTargetDirectory(forceRefresh: true);
    _actorScopeChanged(force: true);
  }

  // يقرأ دليل المستخدمين المستهدف
  Future<List<Map<String, dynamic>>> _readTargetDirectory(
      {bool forceRefresh = false}) async {
    return CachePartitions.run(() async {
      try {
        final value = await PermissionsService().loadPermissionTargets(
            currentCompanyCode,
            forceRefresh: forceRefresh);
        value.readScope.check();
        if (mounted) {
          _directoryScope = value.readScope;
          if (_editor != null &&
              !value.users.any((row) => row['email'] == selectedUserId)) {
            _editorError =
                'الحساب المختار لم يعد متاحاً. أعد التحميل أو اختر حساباً آخر';
          }
        }
        return value.users;
      } finally {
        _targetsLoading = false;
        if (mounted && _reloadTargetsPending) {
          _reloadTargetsPending = false;
          scheduleMicrotask(_refreshTargetDirectory);
        }
      }
    });
  }

  // يحدّث دليل المستخدمين المستهدف
  void _refreshTargetDirectory({bool forceRefresh = false}) {
    if (!mounted) return;
    if (_targetsLoading) {
      _reloadTargetsPending = true;
      return;
    }
    _targetsLoading = true;
    _directoryScope = null;
    setState(() {
      _targetsFuture = _readTargetDirectory(forceRefresh: forceRefresh);
    });
  }

  // يستجيب لتغيّر نطاق المنفّذ
  Future<void> _actorScopeChanged({bool force = false}) async {
    return CachePartitions.run(() async {
      if (!mounted) return;
      if (_pageContext != null && !_pageContext!.sameContext) {
        ++_loadUserRequestId;
        setState(() {
          _pageContext = null;
          _editor = null;
          _editorScope = null;
          _editorError = null;
          _directoryScope = null;
          selectedUserId = null;
          selectedUserJobCode = null;
          usersList = [];
          userPermissions = {};
          _allBranches = [];
          _allEmployees = [];
          _selectedBranchCodes = [];
          _startupBranch = '';
          _hrViewableEmployees = null;
          _allowAllBranches = true;
          _allowAllEmployees = true;
        });
        await _loadCompanyCode();
        return;
      }
      if ((_directoryScope == null || !_directoryScope!.isCurrent) &&
          !_targetsLoading) _refreshTargetDirectory(forceRefresh: true);
      if (_saving || _revalidating) {
        if (force) _revalidateAgain = true;
        return;
      }
      if (_editor == null || (!force && (_editorScope?.isCurrent ?? false)))
        return;
      final original = _editor!;
      final requestId = _loadUserRequestId;
      _revalidating = true;
      setState(() {});
      try {
        final fresh =
            await PermissionsService().loadPermissionEditor(original.email);
        final scope = fresh.readScope!;
        scope.check();
        if (!mounted ||
            requestId != _loadUserRequestId ||
            selectedUserId != original.email) return;
        if (fresh.uid != original.uid ||
            fresh.version != original.version ||
            fresh.revision != original.revision) {
          setState(() => _editorError =
              'تغير نطاق الحساب أو سياسة الشركة. أعد التحميل قبل الحفظ');
        } else {
          setState(() {
            _editor = fresh;
            _editorScope = scope;
          });
        }
      } catch (e) {
        if (mounted && requestId == _loadUserRequestId)
          setState(() => _editorError = 'تعذر التحقق من الصلاحيات الحالية: $e');
      } finally {
        _revalidating = false;
        if (mounted) {
          setState(() {});
          if (_revalidateAgain) {
            _revalidateAgain = false;
            scheduleMicrotask(() => _actorScopeChanged(force: true));
          }
        }
      }
    });
  }

  // يحمّل رمز الشركة
  Future<void> _loadCompanyCode() async {
    return CachePartitions.run(() async {
      final request = ++_contextRequestId;
      try {
        final scope = await ReadAuthorizationSnapshot.capture();
        final prefs = await SharedPreferences.getInstance();
        scope.check();
        if (!mounted || request != _contextRequestId) return;
        setState(() {
          _pageContext = scope;
          currentCompanyCode = prefs.getString('company_code') ?? '';
          _isLoading = false;
        });
        _refreshTargetDirectory(forceRefresh: true);
        final email =
            (prefs.getString('user_email') ?? '').trim().toLowerCase();
        final job = prefs.getString('job_code') ?? '1';
        scope.check();
        if (email.isNotEmpty) {
          setState(() {
            selectedUserId = email;
            selectedUserJobCode = job;
          });
          await _loadUserPermissions(email, job);
        }
      } on ReadAuthorizationChanged {
        if (mounted && request == _contextRequestId)
          scheduleMicrotask(_loadCompanyCode);
      }
    });
  }

  // يؤكد إعادة تحميل المحرر
  Future<void> _confirmEditorReload() async {
    return CachePartitions.run(() async {
      if (selectedUserId == null || _saving) return;
      if (_editor != null) {
        final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('إعادة تحميل الصلاحيات'),
                    content: const Text(
                        'ستُستبدل التعديلات غير المحفوظة ببيانات الخادم الحالية.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('رجوع')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('إعادة التحميل'))
                    ]));
        if (approved != true || !mounted) return;
      }
      _refreshTargetDirectory(forceRefresh: true);
      await _loadUserPermissions(selectedUserId!, selectedUserJobCode ?? '1');
    });
  }

  // يحفظ الصلاحيات
  Future<void> savePermissions() async {
    return CachePartitions.run(() async {
      if (!_editorReady || selectedUserId == null) return;
      final editor = _editor!;
      final target = selectedUserId!;
      final requestId = _loadUserRequestId;
      final branches = _draftBranches;
      final employees = _allowAllEmployees
          ? <String>[]
          : List<String>.from(_hrViewableEmployees ?? []);
      if (branches.isEmpty || (!_allowAllEmployees && employees.isEmpty)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('اختر نطاق الفروع والموظفين أولاً'),
            backgroundColor: AppTheme.warningOrangeFor(context)));
        return;
      }
      setState(() => _saving = true);
      try {
        await PermissionsService().savePermissions(
            PageVisibility.forSave(
                userPermissions, editor.permissions, _displayedPermissions),
            targetEmail: target,
            allowedBranches:
                PermissionEditorSnapshot.sameSet(branches, editor.branches)
                    ? null
                    : branches,
            hrViewableEmployees:
                PermissionEditorSnapshot.sameSet(employees, editor.employees)
                    ? null
                    : employees,
            expectedTargetUid: editor.uid,
            expectedProfileVersion: editor.version,
            expectedPolicyRevision: editor.revision,
            startupBranchCode:
                _startupBranch == editor.startup ? null : _startupBranch);
        if (!mounted ||
            requestId != _loadUserRequestId ||
            selectedUserId != target) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('تم حفظ الصلاحيات على الخادم'),
            backgroundColor: AppTheme.successStrongFor(context)));
        await _loadUserPermissions(target, selectedUserJobCode ?? '1');
      } catch (e) {
        if (!mounted ||
            requestId != _loadUserRequestId ||
            selectedUserId != target) return;
        setState(() => _editorError =
            'لم يتم تأكيد الحفظ. أعد تحميل البيانات للتحقق قبل المحاولة مجدداً: $e');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_editorError!),
            backgroundColor: AppTheme.warningOrangeFor(context)));
      } finally {
        if (mounted) {
          setState(() => _saving = false);
          if (_revalidateAgain) {
            _revalidateAgain = false;
            scheduleMicrotask(() => _actorScopeChanged(force: true));
          }
        }
      }
    });
  }

  // ينشئ الصلاحيات الافتراضية
  Map<String, Map<String, bool>> _createDefaultPermissions(
    String jobCode,
  ) {
    var allPermissions = emptyPermissionCatalog();
    allPermissions['صلاحيات عامة']!['إظهار الإشعارات'] = true;

    if (jobCode == '99' || jobCode == '200') {
      allPermissions.forEach((category, perms) {
        perms.forEach((key, _) {
          allPermissions[category]![key] = true;
        });
      });
    }

    return allPermissions;
  }

  // يحمّل صلاحيات المستخدم
  Future<void> _loadUserPermissions(String userId, String jobCode) async {
    return CachePartitions.run(() async {
      final requestId = ++_loadUserRequestId;
      if (mounted)
        setState(() {
          _editor = null;
          _editorScope = null;
          _editorError = null;
          userPermissions = {};
        });
      try {
        final editor = await PermissionsService().loadPermissionEditor(userId);
        final scope = editor.readScope!;
        scope.check();
        if (!mounted ||
            requestId != _loadUserRequestId ||
            selectedUserId != userId) return;
        final values = _createDefaultPermissions('1');
        editor.permissions.forEach((category, perms) {
          (values[category] ??= {}).addAll(perms);
        });
        for (final key in PageVisibility.keys) {
          if (!(editor.permissions['صلاحيات عامة']?.containsKey(key) ??
              false)) {
            final label = key.substring('إظهار '.length);
            var fallback = true;
            final rights = editor.permissions;
            if (label == 'رصيد المخزون')
              fallback = rights['صلاحيات عامة']?['إظهار حركة الجرد'] == true;
            if (label == 'تحويلات الخزائن')
              fallback = ['إضافة', 'معاينة', 'تعديل']
                  .any((k) => rights['تحويلات الخزائن']?[k] == true);
            if (label == 'المبيعات والعملاء')
              fallback = [
                'المبيعات',
                'المرتجعات',
                'حسابات العملاء',
                'أرصدة خزائن المبيعات'
              ].any((c) => (rights[c] ?? {}).entries.any((e) =>
                  e.value &&
                  [
                    'إضافة',
                    'تعديل',
                    'معاينة',
                    'إضافة تحصيل',
                    'تعديل تحصيل',
                    'عرض الأرصدة'
                  ].contains(e.key)));
            values['صلاحيات عامة']![key] = fallback;
          }
        }
        _displayedPermissions =
            values.map((c, v) => MapEntry(c, Map<String, bool>.from(v)));
        setState(() {
          _editor = editor;
          _editorScope = scope;
          userPermissions = values;
          _allowAllBranches = editor.branches.contains('all');
          _selectedBranchCodes = _allowAllBranches ? [] : editor.branches;
          _selectedUserIsActive = editor.data['is_active'] != false;
          _hrViewableEmployees = editor.employees;
          _allowAllEmployees =
              editor.employees == null || editor.employees!.isEmpty;
          _startupBranch = editor.startup;
          _allBranches = editor.choices('branch_choices');
          _allEmployees = editor.choices('employee_choices');
        });
      } catch (e) {
        if (mounted &&
            requestId == _loadUserRequestId &&
            selectedUserId == userId) {
          setState(() => _editorError = 'تعذر تحميل الصلاحيات الحالية: $e');
        }
      }
    });
  }

  // يعالج إزالة المستخدم من الحضور
  Future<void> _handleRemoveFromPresence() async {
    return CachePartitions.run(() async {
      if (selectedUserId == null) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.dialogBackground(context),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          title: Text(
            '⚠️ حذف من قائمة الحضور',
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'سيتم إخفاء "$selectedUserId" من قائمة المستخدمين المتصلين.\n\n'
            'لن يتم حذف حسابه من النظام. لو سجل دخول تاني، هيرجع للقائمة.',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                  )),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('حذف',
                  style: TextStyle(
                    color: AppTheme.dangerFor(context),
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.bold,
                  )),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      final ok =
          await PresenceService.instance.removeUserByEmail(selectedUserId!);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'تم الحذف من قائمة الحضور' : 'المستخدم مش موجود في القائمة',
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          backgroundColor: ok
              ? AppTheme.successStrongFor(context)
              : AppTheme.warningOrangeFor(context),
        ),
      );
    });
  }

  // ============================================================
  // ✅ NEW: حظر / إلغاء حظر المستخدم (is_active في Firestore)
  // ============================================================
  // يعالج تبديل الحظر
  Future<void> _handleToggleBlock(bool newValue) async {
    return CachePartitions.run(() async {
      if (!_editorReady ||
          _editor!.active ||
          _rootSelfStatus ||
          selectedUserId == null) return;
      final editor = _editor!;
      final target = selectedUserId!;

      // newValue = true  → عايز يخليه نشط (يلغي الحظر)
      // newValue = false → عايز يحظره
      final willBlock = !newValue;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.dialogBackground(context),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          title: Text(
            willBlock ? '🚫 حظر المستخدم' : '✅ إلغاء الحظر',
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            willBlock
                ? 'سيتم منع "$selectedUserId" من تسجيل الدخول،\n'
                    'ولو كان داخل حاليًا، هيتم تسجيل خروجه تلقائيًا.'
                : 'سيتم السماح لـ "$selectedUserId" بتسجيل الدخول مرة أخرى.',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                  )),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                willBlock ? 'حظر' : 'إلغاء الحظر',
                style: TextStyle(
                  color: willBlock ? AppTheme.dangerFor(context) : Colors.green,
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );

      // لو المستخدم لغى → الـ switch بيرجع لحالته الأصلية تلقائيًا (مفيش setState)
      if (confirmed != true) return;

      try {
        if (!_editorReady ||
            !identical(_editor, editor) ||
            selectedUserId != target) return;
        editor.readScope!.check();
        setState(() => _saving = true);
        await ApiService().setLegacyEditorStatus(
            email: target,
            uid: editor.uid,
            version: editor.version,
            isActive: newValue);
        if (!mounted || selectedUserId != target) return;
        await _loadUserPermissions(target, selectedUserJobCode ?? '1');
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              willBlock ? 'تم حظر المستخدم' : 'تم إلغاء الحظر',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: willBlock
                ? AppTheme.warningOrangeFor(context)
                : AppTheme.successStrongFor(context),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('فشل: $e', style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: AppTheme.dangerStrongFor(context),
          ),
        );
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    });
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    PermissionsService().removeListener(_actorScopeChanged);
    WebSocketSyncService.userDirectoryChanges.removeListener(_directoryHint);
    super.dispose();
  }

  // يبني محدد المستخدم
  Widget _buildUserSelector() => FutureBuilder<List<Map<String, dynamic>>>(
      future: _targetsFuture,
      builder: (context, snapshot) {
        final style = TextStyle(
            color: AppTheme.textSoftFor(context), fontFamily: 'Cairo');
        if (snapshot.hasError)
          return Row(children: [
            Expanded(
                child: Text('تعذر تحميل المستخدمين الحاليين', style: style)),
            IconButton(
                tooltip: 'إعادة تحميل قائمة المستخدمين',
                onPressed: () => _refreshTargetDirectory(forceRefresh: true),
                icon: const Icon(Icons.refresh))
          ]);
        if (!snapshot.hasData || !(_directoryScope?.isCurrent ?? false))
          return Padding(
              padding: const EdgeInsets.all(12),
              child: Text('جارٍ تحميل المستخدمين...', style: style));
        usersList = snapshot.data!;
        if (usersList.isEmpty)
          return Padding(
              padding: const EdgeInsets.all(12),
              child: Text('لا يوجد مستخدمون متاحون', style: style));
        final selected = usersList.any((row) => row['email'] == selectedUserId)
            ? selectedUserId
            : null;
        return DropdownButtonHideUnderline(
            child: DropdownButton<String>(
                dropdownColor: AppTheme.dropdownBackground(context),
                isExpanded: true,
                hint: Text('اختر المستخدم', style: style),
                value: selected,
                icon: Icon(Icons.keyboard_arrow_down_rounded,
                    color: AppTheme.accentFor(context)),
                style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontSize: 16,
                    fontFamily: 'Cairo'),
                items: usersList.map((user) {
                  final name = user['name']?.toString() ?? 'بدون اسم';
                  final title = (user['job_title'] ?? '').toString();
                  final company =
                      (user['company_name'] ?? user['company_code'] ?? '')
                          .toString();
                  final suffix =
                      currentCompanyCode.isEmpty && company.isNotEmpty
                          ? ' - $company'
                          : (title.isEmpty ? '' : ' - $title');
                  return DropdownMenuItem<String>(
                      value: user['email'],
                      child: Text('$name$suffix',
                          overflow: TextOverflow.ellipsis));
                }).toList(),
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null ||
                            !(_directoryScope?.isCurrent ?? false)) return;
                        final user = usersList
                            .firstWhere((row) => row['email'] == value);
                        final job = (user['job_code'] ?? '1').toString();
                        setState(() {
                          selectedUserId = value;
                          selectedUserJobCode = job;
                          _selectedUserIsActive = user['is_active'] != false;
                        });
                        _loadUserPermissions(value, job);
                      }));
      });

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    // final isDark =
    //     Theme.of(context).brightness ==
    //         Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTabController(
        // عدد التبويبات يجب أن يطابق TabBar و TabBarView.
        length: 16,
        child: Scaffold(
          extendBodyBehindAppBar: true,
          body: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: AppTheme.permissionsGradient(context),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.accentFor(context),
                        ),
                      )
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(
                              16.0,
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  icon: Icon(
                                    Icons.arrow_back_ios_new_rounded,
                                    color: AppTheme.textMainFor(context),
                                  ),
                                  onPressed: () => Navigator.pop(
                                    context,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    'إدارة الصلاحيات',
                                    style: TextStyle(
                                      color: AppTheme.textMainFor(context),
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'Cairo',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                Container(
                                  decoration: BoxDecoration(
                                    color: GlassStyle.fill10For(context),
                                    borderRadius: BorderRadius.circular(
                                      10,
                                    ),
                                  ),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.save_rounded,
                                      color: AppTheme.accentFor(context),
                                    ),
                                    onPressed:
                                        _editorReady ? savePermissions : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20.0,
                              vertical: 8.0,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                color: GlassStyle.fill05For(context),
                                borderRadius: BorderRadius.circular(
                                  15,
                                ),
                                border: Border.all(
                                  color: GlassStyle.line10For(context),
                                ),
                              ),
                              child: _buildUserSelector(),
                            ),
                          ),

                          // ============================================================
                          // ✅ Switch + زر الحذف اتنقلوا لتبويب "صلاحيات عامة"
                          //    (جوه buildPermissionsTab)
                          // ============================================================

                          if (_editor?.data['role'] == 'super_admin')
                            const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text(
                                    'السوبر أدمن له وصول كامل بحكم دوره. هذه العلامات المحفوظة لا تقيد صلاحياته ولا تغير هويته.')),
                          if (_editor?.active == true &&
                              _editor?.data['role'] == 'admin')
                            const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text(
                                    'الحفظ يعدل صلاحيات استخدام المدير المفعلة ضمن سقف الشركة والتفويض المتاح لك. لا يغير التفويض أو مسودة الشركة المحفوظة.')),
                          PermissionEditorStatus(
                              loading:
                                  (_editor == null && _editorError == null) ||
                                      _revalidating,
                              saving: _saving,
                              error: _editorError,
                              onReload: selectedUserId == null || _saving
                                  ? null
                                  : _confirmEditorReload),
                          TabBar(
                            isScrollable: true,
                            indicatorColor: AppTheme.accentFor(context),
                            labelColor: AppTheme.accentFor(context),
                            unselectedLabelColor: AppTheme.textHintFor(context),
                            labelStyle: TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.bold,
                            ),
                            tabs: [
                              Tab(
                                text: 'حركة الخزينة',
                              ),
                              Tab(
                                text: 'التكويد',
                              ),
                              Tab(
                                text: 'حسابات الموردين',
                              ),
                              Tab(
                                text: 'تسويات الموردين',
                              ),
                              Tab(
                                text: 'حركة الجرد',
                              ),
                              const Tab(text: 'المبيعات'),
                              const Tab(text: 'المرتجعات'),
                              const Tab(text: 'حسابات العملاء'),
                              const Tab(text: 'التحويلات المخزنية'),
                              const Tab(text: 'تحويلات الخزائن'),
                              const Tab(text: 'أرصدة خزائن المبيعات'),
                              Tab(
                                text: 'التقارير',
                              ),
                              Tab(
                                text: 'رصيد المخزون',
                              ),
                              Tab(
                                text: 'صلاحيات عامة',
                              ),
                              Tab(
                                text: 'الموارد البشرية',
                              ),
                              Tab(text: 'إدارة المستخدمين'),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                buildPermissionsTab(
                                  'حركة الخزينة',
                                ),
                                buildPermissionsTab(
                                  'التكويد',
                                ),
                                buildPermissionsTab(
                                  'حسابات الموردين',
                                ),
                                buildPermissionsTab(
                                  'تسويات الموردين',
                                ),
                                buildPermissionsTab(
                                  'حركة الجرد',
                                ),
                                buildPermissionsTab('المبيعات'),
                                buildPermissionsTab('المرتجعات'),
                                buildPermissionsTab('حسابات العملاء'),
                                buildPermissionsTab('التحويلات المخزنية'),
                                buildPermissionsTab('تحويلات الخزائن'),
                                buildPermissionsTab('أرصدة خزائن المبيعات'),
                                buildPermissionsTab(
                                  'التقارير',
                                ),
                                buildPermissionsTab(
                                  'رصيد المخزون',
                                ),
                                buildPermissionsTab(
                                  'صلاحيات عامة',
                                ),
                                buildPermissionsTab(
                                  'الموارد البشرية',
                                ),
                                buildPermissionsTab('إدارة المستخدمين'),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // يبني أزرار الإجراءات الجماعية
  Widget _bulkActions(String category, Iterable<String> keys) {
    final group = keys.toList();
    Map<String, Map<String, bool>> plan(bool next) => bulkPermissionEdit(
        userPermissions,
        {category: group},
        next,
        (c, k, n, current) =>
            _editorReady &&
            _editor!.canToggle(c, k, n, current, _draftBranches));
    bool changed(Map<String, Map<String, bool>> result) => group.any(
        (key) => result[category]?[key] != userPermissions[category]?[key]);
    final selected = plan(true), cleared = plan(false);
    return PermissionBulkActions(
        selected: group
            .where((key) =>
                PermissionHierarchy.allows(userPermissions, category, key))
            .length,
        total: group.length,
        onSelect: changed(selected)
            ? () => setState(() => userPermissions = selected)
            : null,
        onClear: changed(cleared)
            ? () => setState(() => userPermissions = cleared)
            : null);
  }

  // يبني تبويب الصلاحيات
  Widget buildPermissionsTab(String tabName) {
    var permissionsMap = userPermissions[tabName] ?? {};

    if (tabName == 'رصيد المخزون') {
      permissionsMap = Map.of(permissionsMap)..remove('عرض قيمة الجملة');
    }

    if (tabName == 'صلاحيات عامة') {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _bulkActions(tabName, permissionsMap.keys),
          ...permissionsMap.entries.map((entry) {
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: GlassStyle.fill05For(context),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: GlassStyle.line10For(context)),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(15),
                child: SwitchListTile(
                  activeThumbColor: AppTheme.accentFor(context),
                  inactiveTrackColor: GlassStyle.switchTrackOffFor(context),
                  title: Text(
                    entry.key,
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontSize: 16,
                      fontFamily: 'Cairo',
                    ),
                  ),
                  value: entry.value,
                  onChanged: !_canToggle(tabName, entry.key, !entry.value)
                      ? null
                      : (newValue) {
                          setState(() {
                            userPermissions[tabName]![entry.key] = newValue;
                          });
                        },
                ),
              ),
            );
          }).toList(),
          Divider(color: GlassStyle.line24For(context)),

          // ============================================================
          // ✅ Switch: حالة الحساب (نشط / محظور)
          // + زر: حذف من قائمة الحضور
          // ============================================================
          if (selectedUserId != null) ...[
            // ✅ Switch: الحساب نشط / محظور
            Material(
              color: GlassStyle.fill05For(context),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
                side: BorderSide(
                  color: _selectedUserIsActive
                      ? Colors.green.withValues(alpha: 0.3)
                      : AppTheme.dangerFor(context).withValues(alpha: 0.3),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: SwitchListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                activeThumbColor: Colors.green,
                inactiveThumbColor: AppTheme.dangerFor(context),
                secondary: Icon(
                  _selectedUserIsActive
                      ? Icons.check_circle_rounded
                      : Icons.block_rounded,
                  color: _selectedUserIsActive
                      ? Colors.green
                      : AppTheme.dangerFor(context),
                  size: 22,
                ),
                title: Text(
                  _selectedUserIsActive ? 'الحساب نشط' : 'الحساب محظور',
                  style: TextStyle(
                    color: _selectedUserIsActive
                        ? Colors.green
                        : AppTheme.dangerFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  _rootSelfStatus
                      ? 'لا يمكن حظر حسابك كصاحب البرنامج'
                      : _selectedUserIsActive
                          ? 'المستخدم يقدر يسجل دخول'
                          : 'المستخدم ممنوع من الدخول',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 10,
                  ),
                ),
                value: _selectedUserIsActive,
                onChanged:
                    _editorReady && _editor?.active != true && !_rootSelfStatus
                        ? _handleToggleBlock
                        : null,
              ),
            ),

            const SizedBox(height: 12),

            // ✅ زر: حذف من قائمة الحضور
            OutlinedButton.icon(
              onPressed: _editorReady ? _handleRemoveFromPresence : null,
              icon: Icon(
                Icons.delete_sweep_rounded,
                color: AppTheme.dangerFor(context),
                size: 18,
              ),
              label: Text(
                'حذف من قائمة الحضور',
                style: TextStyle(
                  color: AppTheme.dangerFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.dangerFor(context)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 10),
                minimumSize: const Size(double.infinity, 0),
              ),
            ),
          ],
          // ============================================================

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'الفروع المسموح بها',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo',
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: GlassStyle.fill05For(context),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: GlassStyle.line10For(context)),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(15),
              child: CheckboxListTile(
                activeColor: AppTheme.accentFor(context),
                checkColor: AppTheme.onAccentFor(context),
                title: Text(
                  'كل الفروع',
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontSize: 16,
                    fontFamily: 'Cairo',
                  ),
                ),
                value: _allowAllBranches,
                onChanged: !_canEditBranch('all')
                    ? null
                    : (val) {
                        setState(() {
                          _allowAllBranches = val ?? false;
                          if (_allowAllBranches) {
                            _selectedBranchCodes = [];
                          }
                        });
                      },
              ),
            ),
          ),
          if (!_allowAllBranches)
            ..._allBranches.map((branch) {
              final isSelected = _selectedBranchCodes.contains(branch['code']);

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: GlassStyle.fill05For(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: GlassStyle.line10For(context)),
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: CheckboxListTile(
                    activeColor: AppTheme.accentFor(context),
                    checkColor: AppTheme.onAccentFor(context),
                    title: Text(
                      branch['name'] ?? '',
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontSize: 14,
                        fontFamily: 'Cairo',
                      ),
                    ),
                    value: isSelected,
                    onChanged: !_canEditBranch(branch['code']!)
                        ? null
                        : (val) {
                            setState(() {
                              if (val == true) {
                                _selectedBranchCodes.add(branch['code']!);
                              } else {
                                _selectedBranchCodes.remove(branch['code']);
                              }
                            });
                          },
                  ),
                ),
              );
            }).toList(),
          PermissionEditorStartup(
              value: _startupBranch,
              choices: _allBranches,
              allowed: _draftBranches,
              enabled: _editorReady,
              onChanged: (value) => setState(() => _startupBranch = value)),
          if (!_allowAllBranches && _selectedBranchCodes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '⚠️ يجب اختيار فرع واحد على الأقل',
                style: TextStyle(
                  color: AppTheme.warningOrangeSoftFor(context),
                  fontFamily: 'Cairo',
                ),
              ),
            ),
        ],
      );
    }
    if (tabName == 'الموارد البشرية') {
      return _buildHrPermissionsTab();
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: permissionsMap.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _bulkActions(tabName, permissionsMap.keys);
        final key = permissionsMap.keys.elementAt(index - 1);
        final higher = PermissionHierarchy.addToEdit[tabName]?[key];
        final included = higher != null && permissionsMap[higher] == true;
        final value = permissionsMap[key] == true || included;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: GlassStyle.fill05For(context),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: GlassStyle.line10For(context)),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            child: PermissionActionSwitch(
              label: key,
              value: value,
              included: included,
              onChanged: !_canToggle(tabName, key, !value)
                  ? null
                  : (newValue) {
                      setState(() {
                        userPermissions[tabName]![key] = newValue;
                      });
                    },
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // ⭐ HR: تبويب الموارد البشرية (6 مجموعات + فلترة)
  // ============================================================

  // يبني تبويب صلاحيات الموارد البشرية
  Widget _buildHrPermissionsTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _bulkActions(
            'الموارد البشرية', (userPermissions['الموارد البشرية'] ?? {}).keys),
        // ─── A. فتح الصفحات ───
        _buildHrSection(
          title: 'فتح الصفحات',
          icon: Icons.lock_open_rounded,
          color: AppTheme.infoFor(context),
          keys: [
            'canOpenAttendancePage',
            'canOpenVacationsPage',
            'canOpenReportPage',
          ],
        ),

        // ─── B. عمليات الحضور ───
        _buildHrSection(
          title: 'عمليات الحضور',
          icon: Icons.fingerprint_rounded,
          color: AppTheme.successFor(context),
          keys: [
            'canAddAttendance',
            'canEditAttendance',
            'canDeleteAttendance',
          ],
        ),

        // ─── C. عمليات الإجازات ───
        _buildHrSection(
          title: 'عمليات الإجازات',
          icon: Icons.beach_access_rounded,
          color: AppTheme.extraTealFor(context),
          keys: [
            'canAddVacation',
            'canEditVacation',
            'canDeleteVacation',
          ],
        ),

        // ─── D. التسويات (مكافأة/سلفة) ───
        _buildHrSection(
          title: 'التسويات (مكافأة / سلفة)',
          icon: Icons.attach_money_rounded,
          color: AppTheme.warningFor(context),
          keys: [
            'canViewAdjustments',
            'canAddBonus',
            'canAddLoan',
            'canEditAdjustment',
            'canDeleteAdjustment',
          ],
        ),

        // ─── E. الإعدادات ───
        _buildHrSection(
          title: 'الإعدادات',
          icon: Icons.settings_rounded,
          color: AppTheme.warningOrangeSoftFor(context),
          keys: [
            'canEditWeeklyDay',
            'canEditWorkSchedule',
            'canEditDelayRules',
          ],
        ),

        // ─── F. الخصم المباشر والراتب ───
        _buildHrSection(
          title: 'الخصم المباشر والراتب',
          icon: Icons.money_off_rounded,
          color: AppTheme.dangerFor(context),
          keys: [
            'canAddDirectDiscount',
            'canViewSalaryAmounts',
            'canExportReport',
          ],
        ),

        // ─── G. إدارة الموظفين ───
        _buildHrSection(
          title: 'إدارة الموظفين',
          icon: Icons.badge_rounded,
          color: AppTheme.extraBlueGreyFor(context),
          keys: [
            'canViewEmployees',
            'canManageEmployees',
          ],
        ),

        // ─── H. الموظف يشوف بياناته ───
        _buildHrSection(
          title: 'بيانات الموظف الشخصية',
          icon: Icons.person_pin_rounded,
          color: AppTheme.infoFor(context),
          keys: [
            'canViewOwnHRData',
          ],
        ),

        // ─── I. التقارير المجمعة ⭐ جديد ───
        _buildHrSection(
          title: 'التقارير المجمعة',
          icon: Icons.summarize_rounded,
          color: AppTheme.extraPurpleFor(context),
          keys: [
            'canViewBranchSalaryReport',
          ],
        ),

        // ─── J. فلترة الموظفين ───
        _buildHrEmployeesFilterSection(),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────
  // قسم HR واحد (Header + Switch لكل صلاحية)
  // ──────────────────────────────────────────────────────────

  // يبني قسم الموارد البشرية
  Widget _buildHrSection({
    required String title,
    required IconData icon,
    required Color color,
    required List<String> keys,
  }) {
    final hrPerms = userPermissions['الموارد البشرية'] ?? {};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ),
        ),

        _bulkActions('الموارد البشرية', keys),
        // Switch لكل صلاحية
        ...keys.map((key) {
          final higher = PermissionHierarchy.addToEdit['الموارد البشرية']?[key];
          final included = higher != null && hrPerms[higher] == true;
          final value = hrPerms[key] == true || included;
          final label = _hrPermissionLabel(key);

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: GlassStyle.fill05For(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: GlassStyle.line10For(context)),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: PermissionActionSwitch(
                label: label,
                value: value,
                included: included,
                activeColor: color,
                fontSize: 14,
                onChanged: !_canToggle('الموارد البشرية', key, !value)
                    ? null
                    : (newValue) {
                        setState(() {
                          userPermissions['الموارد البشرية'] ??= {};
                          userPermissions['الموارد البشرية']![key] = newValue;
                        });
                      },
              ),
            ),
          );
        }),

        const SizedBox(height: 15),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────
  // تسمية الصلاحية بالعربي
  // ──────────────────────────────────────────────────────────

  // يعيد اسم صلاحية الموارد البشرية
  String _hrPermissionLabel(String key) {
    const labels = {
      // A
      'canOpenAttendancePage': 'فتح صفحة الحضور',
      'canOpenVacationsPage': 'فتح صفحة الإجازات',
      'canOpenReportPage': 'فتح صفحة التقارير',
      // B
      'canAddAttendance': 'تسجيل حضور',
      'canEditAttendance': 'تعديل حضور',
      'canDeleteAttendance': 'حذف حضور',
      // C
      'canAddVacation': 'إضافة إجازة',
      'canEditVacation': 'تعديل إجازة',
      'canDeleteVacation': 'حذف إجازة',
      // D
      'canViewAdjustments': 'عرض التسويات',
      'canAddBonus': 'إضافة مكافأة',
      'canAddLoan': 'إضافة سلفة',
      'canEditAdjustment': 'تعديل تسوية',
      'canDeleteAdjustment': 'حذف تسوية',
      // E
      'canEditWeeklyDay': 'تعديل يوم الإجازة الأسبوعي',
      'canEditWorkSchedule': 'تعديل مواعيد العمل',
      'canEditDelayRules': 'تعديل إعدادات التأخير',
      // F
      'canAddDirectDiscount': 'إضافة خصم مباشر',
      'canViewSalaryAmounts': 'إظهار المبالغ المالية',
      'canExportReport': 'تصدير تقرير الراتب',
      // G
      'canViewEmployees': 'عرض الموظفين',
      'canManageEmployees': 'إدارة الموظفين (إضافة/تعديل/حذف)',
      // H
      'canViewOwnHRData': 'إظهار بيانات الموظف لنفسه (بروفايله + راتبه)',
      // I
      'canViewBranchSalaryReport': 'عرض تقرير إجمالي الرواتب لكل فرع',
    };
    return labels[key] ?? key;
  }

  // ──────────────────────────────────────────────────────────
  // قسم فلترة الموظفين
  // ──────────────────────────────────────────────────────────

  // يبني قسم تصفية الموظفين
  Widget _buildHrEmployeesFilterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppTheme.accentFor(context).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.filter_alt_rounded,
                  color: AppTheme.accentFor(context),
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'فلترة الموظفين المرئيين',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ),
        ),

        // Checkbox: كل الموظفين
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: GlassStyle.fill05For(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: GlassStyle.line10For(context)),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: CheckboxListTile(
              activeColor: AppTheme.accentFor(context),
              checkColor: AppTheme.onAccentFor(context),
              title: Text(
                'كل الموظفين (في الفروع المسموحة)',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 14,
                  fontFamily: 'Cairo',
                ),
              ),
              value: _allowAllEmployees,
              onChanged: !_canEditEmployees
                  ? null
                  : (val) {
                      setState(() {
                        _allowAllEmployees = val ?? false;
                        if (_allowAllEmployees) {
                          _hrViewableEmployees = null;
                        } else {
                          _hrViewableEmployees ??= [];
                        }
                      });
                    },
            ),
          ),
        ),

        // قائمة الموظفين (لو "كل الموظفين" = false)
        if (!_allowAllEmployees) ...[
          if (_allEmployees.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '⚠️ لا يوجد موظفون مسجلون في النظام',
                style: TextStyle(
                  color: AppTheme.warningOrangeSoftFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                ),
              ),
            )
          else
            ..._allEmployees.map((emp) {
              final code = emp['code'] ?? '';
              final name = emp['name'] ?? '';
              final isSelected = _hrViewableEmployees?.contains(code) ?? false;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: GlassStyle.fill05For(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: GlassStyle.line10For(context)),
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: CheckboxListTile(
                    activeColor: AppTheme.accentFor(context),
                    checkColor: AppTheme.onAccentFor(context),
                    title: Text(
                      '$name ($code)',
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontSize: 13,
                        fontFamily: 'Cairo',
                      ),
                    ),
                    value: isSelected,
                    onChanged: !_canEditEmployees
                        ? null
                        : (val) {
                            setState(() {
                              _hrViewableEmployees ??= [];
                              if (val == true) {
                                if (!_hrViewableEmployees!.contains(code)) {
                                  _hrViewableEmployees!.add(code);
                                }
                              } else {
                                _hrViewableEmployees!.remove(code);
                              }
                            });
                          },
                  ),
                ),
              );
            }),

          // تحذير لو مفيش اختيار
          if (_hrViewableEmployees?.isEmpty ?? true)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '⚠️ يجب اختيار موظف واحد على الأقل',
                style: TextStyle(
                  color: AppTheme.warningOrangeSoftFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ],
    );
  }
}
