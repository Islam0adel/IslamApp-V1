// frontend/lib/views/dashboard/company_policy_review_page.dart
import '../../services/cache_partitions.dart';
import '../../services/permission_bulk_edit.dart';
import '../widgets/permission_bulk_actions.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/auth_http.dart';
import '../../services/permission_catalog.dart';
import '../../services/company_permission_policy.dart';
import '../../services/permissions_service.dart';
import '../../services/read_authorization_snapshot.dart';
import '../widgets/permission_action_switch.dart';
import 'company_users_page.dart';

// صفحة مراجعة سياسة الشركة
class CompanyPolicyReviewPage extends StatefulWidget {
  const CompanyPolicyReviewPage(
      {super.key, required this.companyCode, required this.companyName});
  final String companyCode, companyName;

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<CompanyPolicyReviewPage> createState() =>
      _CompanyPolicyReviewPageState();
}

// حالة الويدجت CompanyPolicyReviewPage: تدير بيانات الشاشة وتفاعلاتها
class _CompanyPolicyReviewPageState extends State<CompanyPolicyReviewPage> {
  Map<String, dynamic>? _review;
  Map<String, dynamic> _configuration = {
    'company_permissions': <String, dynamic>{},
    'admin_profiles': <String, dynamic>{}
  };
  ReadAuthorizationSnapshot? _scope;
  bool _busy = false, _dirty = false;
  String? _error;

  // يعيد عنوان واجهة السياسة
  String get _base =>
      '${ApiConstants.baseUrl}/auth/companies/${Uri.encodeComponent(widget.companyCode)}/permission-policy';

  // يحدد هل الشاشة جاهزة للتعديل
  bool get _ready =>
      !_busy &&
      _review != null &&
      (_scope?.isCurrent ?? false) &&
      PermissionsService().isSuperAdmin;

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    ReadAuthorizationEpoch.changes.addListener(_authorityChanged);
    PermissionsService().addListener(_authorityChanged);
    _load();
  }

  // يحرّر الموارد المستخدمة عند إغلاق الشاشة
  @override
  void dispose() {
    ReadAuthorizationEpoch.changes.removeListener(_authorityChanged);
    PermissionsService().removeListener(_authorityChanged);
    super.dispose();
  }

  // يستجيب لتغيّر الصلاحيات
  void _authorityChanged() {
    if (!mounted ||
        (_scope?.isCurrent == true && PermissionsService().isSuperAdmin))
      return;
    setState(() {
      _review = null;
      _configuration = {
        'company_permissions': <String, dynamic>{},
        'admin_profiles': <String, dynamic>{}
      };
      _error = 'تغير نطاق الحساب. أعد تحميل المراجعة';
    });
  }

  // يحوّل القيمة إلى خريطة
  Map<String, dynamic> _object(dynamic value) =>
      Map<String, dynamic>.from(value as Map);

  // يفك استجابة الخادم
  Future<Map<String, dynamic>> _decode(dynamic response) async {
    return CachePartitions.run(() async {
      final value = jsonDecode(response.body);
      if (response.statusCode != 200)
        throw value is Map
            ? value['detail'] ?? 'تعذر حفظ المراجعة'
            : 'تعذر حفظ المراجعة';
      if (value is! Map) throw const FormatException('Invalid review response');
      return _object(value);
    });
  }

  // يسأل عن تجاهل التغييرات
  Future<bool> _discardChanges() async {
    return CachePartitions.run(() async {
      if (!_dirty) return true;
      final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('تعديلات غير محفوظة'),
                  content: const Text(
                      'سيتم تجاهل تعديلات المسودة غير المحفوظة. هل تريد المتابعة؟'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('البقاء في المراجعة')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('تجاهل التعديلات'))
                  ]));
      return discard == true && mounted;
    });
  }

  // يحمّل بيانات الشاشة
  Future<void> _load() async {
    return CachePartitions.run(() async {
      if (_busy) return;
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        if (!PermissionsService().isSuperAdmin)
          throw StateError('هذه المراجعة خاصة بصاحب البرنامج');
        final scope = await ReadAuthorizationSnapshot.capture();
        final value =
            await _decode(await AuthHttp.get(Uri.parse('$_base/review')));
        scope.check();
        if (!mounted) return;
        final configuration = value['draft'] ??
            value['active'] ??
            {
              'company_permissions': <String, dynamic>{},
              'admin_profiles': <String, dynamic>{}
            };
        setState(() {
          _scope = scope;
          _review = value;
          _configuration = _object(jsonDecode(jsonEncode(configuration)));
          _dirty = false;
        });
      } catch (error) {
        if (mounted)
          setState(() {
            _review = null;
            _error = error.toString();
          });
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
  }

  // يبني مقارنة بين نسختي السياسة
  Widget _policyComparison(String title, dynamic value) {
    final map = _object(value);
    final admins = _object(map['admin_profiles']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      for (final admin in admins.entries) ...[
        Text('المدير: ${admin.key}'),
        for (final category
            in _object(_object(admin.value)['operating_permissions']).entries)
          Text(
              '${category.key}: ${_object(category.value).entries.where((entry) => entry.value == true).map((entry) => entry.key).join('، ')}'),
      ],
    ]);
  }

  // يتحقق من البيانات ويحفظها
  Future<void> _save() async {
    return CachePartitions.run(() async {
      if (!_ready) return;
      int? reconciled;
      if (_review!['draft_requires_reconciliation'] == true) {
        final yes = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title:
                        const Text('راجع اختلاف المسودة عن الصلاحيات الحالية'),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          const Text(
                              'تغيرت صلاحيات استخدام مدير بعد حفظ هذه المسودة. حفظها ثم تفعيلها قد يستبدل التغييرات الحالية. قارن القيم وعدل المسودة عند الحاجة. لم نغير اختياراتك تلقائياً.'),
                          _policyComparison('استخدام المديرين المفعل حالياً',
                              _review!['active']),
                          const Divider(),
                          _policyComparison(
                              'استخدام المديرين في المسودة المراد حفظها',
                              _configuration),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('رجوع لتعديل المسودة')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text(
                              'راجعت الاختلافات وأوافق على حفظ اختيارات المسودة'))
                    ]));
        if (yes != true || !mounted || !_ready) return;
        reconciled = _review!['active_revision'];
      }
      final scope = _scope!;
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        scope.check();
        await _decode(await AuthHttp.put(Uri.parse('$_base/draft'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'expected_revision': _review!['revision'],
              if (reconciled != null) 'reconciled_active_revision': reconciled,
              'configuration': _configuration
            })));
        scope.check();
        if (!mounted) return;
        setState(() {
          _busy = false;
        });
        await _load();
      } catch (error) {
        if (mounted)
          setState(() => _error =
              'لم يتأكد حفظ المسودة. أعد تحميل المراجعة قبل إعادة الحفظ: $error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
  }

  // يفعّل السياسة
  Future<void> _activate() async {
    return CachePartitions.run(() async {
      if (!_ready || _dirty || _review!['draft'] == null) return;
      final original = _scope!;
      final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('تفعيل السياسة المراجعة'),
                  content: const Text(
                      'سيطبق سقف الشركة ونطاق كل مدير معاً. تنتهي صلاحيات المدير المفتوحة القديمة، وأي صلاحية غير محددة لن تصبح مسموحة. هل راجعت الحسابات والفروع وصلاحيات الاستخدام والتفويض؟'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('رجوع للمراجعة')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('راجعت وأوافق على التفعيل'))
                  ]));
      if (yes != true || !mounted || !original.isCurrent || !_ready) return;
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        await _decode(await AuthHttp.post(Uri.parse('$_base/activate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'expected_revision': _review!['revision'],
              'source_review_token': _review!['source_review_token'],
              'confirmed_review': true
            })));
        if (!mounted) return;
        setState(() {
          _busy = false;
        });
        await _load();
      } catch (error) {
        if (mounted)
          setState(() => _error =
              'لم يتأكد التفعيل. أعد تحميل المراجعة للتحقق قبل تكراره: $error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
  }

  // يعيد سقف صلاحيات الشركة
  Map<String, dynamic> get _ceiling =>
      _object(_configuration['company_permissions']);

  // يعيد ملفات المديرين
  Map<String, dynamic> get _admins => _object(_configuration['admin_profiles']);

  // يسجّل تغييرًا في الإعدادات
  void _change(void Function() update) {
    if (!_ready) return;
    setState(() {
      update();
      _dirty = true;
    });
  }

  // يبني محرر الصلاحيات
  Widget _mapEditor(String title, Map<String, dynamic> values,
      void Function(Map<String, dynamic>) update,
      {bool bounded = false}) {
    final catalog = emptyPermissionCatalog();
    values.forEach((category, section) {
      if (section is Map) {
        for (final key in section.keys) {
          (catalog[category] ??= {})[key.toString()] = false;
        }
      }
    });
    Widget bulk(Map<String, Iterable<String>> groups) {
      final original = <String, Map<String, bool>>{
        for (final entry in values.entries)
          entry.key: Map<String, bool>.from(entry.value as Map)
      };
      Map<String, Map<String, bool>> plan(bool next) => bulkPermissionEdit(
          original,
          groups,
          next,
          (category, key, next, current) =>
              _ready &&
              (!bounded ||
                  CompanyPermissionPolicy.grants(_ceiling)
                      .contains((category: category, key: key)) ||
                  (current[category]?[key] == true)));
      bool changed(Map<String, Map<String, bool>> result) =>
          groups.entries.any((group) => group.value.any((key) =>
              (result[group.key]?[key] == true) !=
              (original[group.key]?[key] == true)));
      final selected = plan(true),
          cleared = plan(false),
          effective = CompanyPermissionPolicy.grants(values);
      final total =
          groups.values.fold<int>(0, (sum, keys) => sum + keys.length);
      final count = groups.entries.fold<int>(
          0,
          (sum, group) =>
              sum +
              group.value
                  .where((key) =>
                      effective.contains((category: group.key, key: key)))
                  .length);
      return PermissionBulkActions(
          selected: count,
          total: total,
          onSelect:
              changed(selected) ? () => _change(() => update(selected)) : null,
          onClear:
              changed(cleared) ? () => _change(() => update(cleared)) : null);
    }

    return ExpansionTile(title: Text(title), children: [
      bulk({for (final entry in catalog.entries) entry.key: entry.value.keys}),
      ...catalog.entries
          .map(
              (category) => ExpansionTile(title: Text(category.key), children: [
                    bulk({category.key: category.value.keys}),
                    ...category.value.keys.map((key) {
                      final right = (category: category.key, key: key);
                      final included = CompanyPermissionPolicy.grants(values)
                              .contains(right) &&
                          (values[category.key] as Map?)?[key] != true;
                      final available = !bounded ||
                          CompanyPermissionPolicy.grants(_ceiling)
                              .contains(right) ||
                          (values[category.key] as Map?)?[key] == true;
                      return PermissionActionSwitch(
                          label: permissionDisplayLabel(category.key, key),
                          value: (values[category.key] as Map?)?[key] == true,
                          included: included,
                          onChanged: !_ready || !available
                              ? null
                              : (next) => _change(() {
                                    final copy =
                                        _object(jsonDecode(jsonEncode(values)));
                                    (copy[category.key] ??=
                                        <String, dynamic>{})[key] = next;
                                    update(copy);
                                  }));
                    }).toList()
                  ]))
          .toList()
    ]);
  }

  // يبني بطاقة المدير
  Widget _admin(Map<String, dynamic> account) {
    final uid = account['uid']?.toString() ?? '';
    final profiles = _admins;
    final selected = profiles.containsKey(uid);
    final eligible = uid.isNotEmpty &&
        account['is_active'] != false &&
        account['lifecycle_pending'] != true;
    final profile = selected ? _object(profiles[uid]) : <String, dynamic>{};
    void patch(String key, dynamic value) {
      final all = _admins;
      final next = _object(all[uid]);
      next[key] = value;
      all[uid] = next;
      _configuration['admin_profiles'] = all;
    }

    return Card(
        child: Column(children: [
      CheckboxListTile(
          title: Text('${account['name']} (${account['email']})'),
          subtitle: Text(eligible
              ? 'هوية مرتبطة: $uid'
              : 'يجب ربط هوية الدعوة قبل إسناد الصلاحيات'),
          value: selected,
          onChanged: !_ready || !eligible
              ? null
              : (value) => _change(() {
                    final all = _admins;
                    if (value == true) {
                      all[uid] = {
                        'operating_permissions': <String, dynamic>{},
                        'delegable_permissions': <String, dynamic>{},
                        'delegable_branches': <String>[]
                      };
                    } else {
                      all.remove(uid);
                    }
                    _configuration['admin_profiles'] = all;
                  })),
      if (selected) ...[
        _mapEditor(
            'صلاحيات الاستخدام',
            _object(profile['operating_permissions']),
            (value) => patch('operating_permissions', value),
            bounded: true),
        _mapEditor(
            'صلاحيات يمكنه منحها للموظفين',
            _object(profile['delegable_permissions']),
            (value) => patch('delegable_permissions', value),
            bounded: true),
        ExpansionTile(
            title: const Text('الفروع التي يمكنه إسنادها'),
            children: [
              for (final branch in [
                {'code': 'all', 'name': 'كل الفروع الحالية والمستقبلية'},
                ...(_review!['branches'] as List).map((value) => _object(value))
              ])
                CheckboxListTile(
                    title: Text(branch['name'].toString()),
                    value: (profile['delegable_branches'] as List? ?? [])
                        .contains(branch['code']),
                    onChanged: !_ready
                        ? null
                        : (value) => _change(() {
                              final current = List<String>.from(
                                  profile['delegable_branches'] as List? ?? []);
                              final code = branch['code'].toString();
                              if (value == true) {
                                if (code == 'all') {
                                  current
                                    ..clear()
                                    ..add('all');
                                } else {
                                  current.remove('all');
                                  current.add(code);
                                }
                              } else {
                                current.remove(code);
                              }
                              patch('delegable_branches', current);
                            }))
            ]),
      ]
    ]));
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, result) async {
        return CachePartitions.run(() async {
          if (didPop || _busy) return;
          if (await _discardChanges()) {
            setState(() => _dirty = false);
            if (context.mounted) Navigator.pop(context);
          }
        });
      },
      child: Scaffold(
          appBar: AppBar(
              title: Text('مراجعة صلاحيات ${widget.companyName}'),
              actions: [
                IconButton(
                    tooltip: 'إعادة تحميل المراجعة',
                    onPressed: _busy
                        ? null
                        : () async {
                            return CachePartitions.run(() async {
                              if (await _discardChanges()) await _load();
                            });
                          },
                    icon: const Icon(Icons.refresh))
              ]),
          body: Directionality(
              textDirection: TextDirection.rtl,
              child: _busy && _review == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(padding: const EdgeInsets.all(16), children: [
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(_error!,
                                style: TextStyle(
                                    color: AppTheme.dangerFor(context)))),
                      if (_review != null) ...[
                        Text(
                            _review!['status'] == 'active'
                                ? 'السياسة المراجعة مفعلة'
                                : 'لم تفعل السياسة المراجعة بعد. الشركة القديمة تحتفظ بسياستها الحالية حتى التأكيد.',
                            style: TextStyle(
                                color: AppTheme.textMainFor(context))),
                        if (_review!['requires_permission_review'] == true)
                          const Text(
                              'الشركة الجديدة مغلقة للعمل حتى المراجعة. يمكن إعداد دعوة المدير وربط هويته أولاً.'),
                        ExpansionTile(
                            title: const Text(
                                'الوصول الحالي للحسابات قبل التغيير'),
                            children: [
                              for (final item in _review!['accounts'] as List)
                                ExpansionTile(
                                    title: Text(
                                        '${item['name']} (${item['email']})'),
                                    subtitle: Text(
                                        'الدور: ${item['role']} | الحالة: ${item['status']} | الفروع: ${item['allowed_branches']}'),
                                    children: [
                                      if (item['role'] == 'admin' &&
                                          _review!['active'] == null)
                                        const ListTile(
                                            title: Text(
                                                'مدير بالنظام القديم: له تجاوز عام مؤقت حتى تفعيل السياسة المراجعة، وليس صلاحيات محددة مستنتجة.')),
                                      for (final category
                                          in _object(item['permissions'])
                                              .entries)
                                        if (category.value is Map)
                                          ListTile(
                                              title: Text(category.key),
                                              subtitle: Text((category.value
                                                      as Map)
                                                  .entries
                                                  .where((entry) =>
                                                      entry.value == true)
                                                  .map((entry) =>
                                                      entry.key.toString())
                                                  .join('، '))),
                                    ])
                            ]),
                        OutlinedButton.icon(
                            icon: const Icon(Icons.person_add_alt),
                            label: const Text('إدارة دعوات وحسابات الشركة'),
                            onPressed: !_ready
                                ? null
                                : () async {
                                    return CachePartitions.run(() async {
                                      if (!await _discardChanges()) return;
                                      if (!mounted) return;
                                      await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) => CompanyUsersPage(
                                                  companyCode:
                                                      widget.companyCode,
                                                  companyName:
                                                      widget.companyName)));
                                      if (mounted) await _load();
                                    });
                                  }),
                        _mapEditor(
                            'سقف صلاحيات الشركة',
                            _ceiling,
                            (value) =>
                                _configuration['company_permissions'] = value),
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                                'المديرون: الاستخدام منفصل عن التفويض. إضافة مدير للمسودة لا تمنحه شيئاً تلقائياً.')),
                        for (final item in _review!['accounts'] as List)
                          if (item['role'] == 'admin') _admin(_object(item)),
                        for (final uid in _admins.keys)
                          if (!(_review!['accounts'] as List).any((item) =>
                              item['role'] == 'admin' && item['uid'] == uid))
                            ListTile(
                                title: Text('إسناد قديم لهوية غير متاحة: $uid'),
                                trailing: TextButton(
                                    onPressed: !_ready
                                        ? null
                                        : () => _change(() {
                                              final all = _admins;
                                              all.remove(uid);
                                              _configuration['admin_profiles'] =
                                                  all;
                                            }),
                                    child: const Text('إزالة من المسودة'))),
                        if (!(_review!['accounts'] as List).any((item) =>
                            item['role'] == 'admin' &&
                            (item['uid'] ?? '') != ''))
                          const Text(
                              'لا يوجد مدير مرتبط بهوية حتى الآن. أنشئ دعوته من إدارة المستخدمين ثم أكمل تسجيلها قبل التفعيل.'),
                        const SizedBox(height: 16),
                        FilledButton(
                            onPressed: _ready ? _save : null,
                            child: const Text('حفظ المسودة فقط')),
                        const SizedBox(height: 8),
                        OutlinedButton(
                            onPressed: _ready &&
                                    !_dirty &&
                                    _review!['draft'] != null &&
                                    _review!['draft_requires_reconciliation'] !=
                                        true
                                ? _activate
                                : null,
                            child:
                                const Text('مراجعة وتفعيل المسودة المحفوظة')),
                        if (_review!['draft_requires_reconciliation'] == true)
                          const Text(
                              'تغيرت صلاحيات المديرين المفعلة بعد هذه المسودة. اختيارات المسودة محفوظة. قارن القيم الحالية عند الحفظ قبل التفعيل.'),
                        if (_dirty)
                          const Text(
                              'توجد تعديلات غير محفوظة. احفظ المسودة ثم راجعها قبل التفعيل.'),
                        if (_busy) const LinearProgressIndicator(),
                      ]
                    ]))));
}
