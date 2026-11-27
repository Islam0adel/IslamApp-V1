// frontend/lib/services/notifications_service.dart
import 'cache_partitions.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, ValueNotifier;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app_badge.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'permissions_service.dart';

// خدمة الإشعارات المحلية: تعمل كذاكرة سريعة وتزامن مع الخادم
/// الإشعارات المحلية تعمل كذاكرة سريعة، بينما Neon هو مصدر سجل الإشعارات وإعداداتها.
class NotificationsService {
  static final NotificationsService instance = NotificationsService._();
  NotificationsService._();

  static const String _boxName = 'notifications_box';
  static const String _settingsBoxName = 'notification_settings_box';

  // يعيد صندوق الإشعارات المحلي
  Box get _box => CachePartitions.box(_boxName);

  // يعيد صندوق إعدادات الإشعارات
  Box get _settings => CachePartitions.box(_settingsBoxName);

  static const Map<String, String> _sections = {
    'transaction': 'daily',
    'supplier': 'purchases',
    'settlement': 'settlements',
    'coding': 'coding',
    'inventory': 'inventory',
    // ✅ HR
    'hr_attendance': 'hr_attendance',
    'hr_vacation': 'hr_vacations',
    'hr_adjustment': 'hr_adjustments',
    'hr_employee_settings': 'hr_employees',
    'employee': 'hr_employees',
    // ⭐ طلبات الانضمام
    'registration_request': 'registration_requests',
    'sale': 'sales',
    'sale_return': 'sales_returns',
    'customer_payment': 'customer_payments',
    'stock_transfer': 'stock_transfers',
  };

  static const Map<String, String> _sectionNames = {
    'daily': 'اليوميات',
    'purchases': 'المشتريات والموردين',
    'settlements': 'التسويات',
    'coding': 'التكويد',
    'inventory': 'الجرد',
    // ✅ HR
    'hr_attendance': 'حضور الموارد البشرية',
    'hr_vacations': 'إجازات الموارد البشرية',
    'hr_adjustments': 'تسويات الموارد البشرية',
    'hr_employees': 'بيانات الموظفين',
    // ⭐ جديد
    'registration_requests': 'طلبات الانضمام',
    'sales': 'المبيعات والمرتجعات والتحصيلات والتحويلات',
    'sales_returns': 'المبيعات والمرتجعات والتحصيلات والتحويلات',
    'customer_payments': 'المبيعات والمرتجعات والتحصيلات والتحويلات',
    'stock_transfers': 'المبيعات والمرتجعات والتحصيلات والتحويلات',
  };

  static const Map<String, String> _actionNames = {
    'add': 'إضافة',
    'insert': 'إضافة',
    'create': 'إضافة',
    'update': 'تعديل',
    'edit': 'تعديل',
    'delete': 'حذف',
    'remove': 'حذف',
  };

  String? _companyCode;
  int _cacheGeneration = -1;
  Future<void>? _settingsLoad;
  Future<void>? _settingsRequest;
  int _bindingVersion = 0;
  bool _settingsRefreshPending = false;
  Future<void>? _refreshInFlight;
  String? _refreshCompany;
  String? _refreshUid;
  int? _refreshScope;
  int _scopeVersion = 0;
  bool _hrAuthorizationPending = false;
  int _hrAuthorizationGeneration = 0;
  static const _hrSections = {
    'hr_employees',
    'hr_attendance',
    'hr_vacations',
    'hr_adjustments'
  };

  // يحدد هل المستخدم يرى إشعارات الموارد البشرية الخاصة به فقط
  bool get _ownHROnly {
    final ps = PermissionsService();
    return ps.canViewOwnHRData &&
        !(ps.canViewEmployees ||
            ps.canManageEmployees ||
            ps.canOpenAttendancePage ||
            ps.canOpenVacationsPage ||
            ps.canViewAdjustments ||
            ps.canViewBranchSalaryReport);
  }

  // يحدد هل إشعار الموارد البشرية يخص المستخدم نفسه
  bool _isOwnHRItem(Map item) {
    final scope = item['notification_scope'];
    final ps = PermissionsService();
    return _hrSections.contains(item['section']) &&
        ps.canViewOwnHRData &&
        ps.hrNotificationsEnabled &&
        scope is Map &&
        scope['is_self'] == true &&
        (scope['employee_code'] ?? '').toString().isNotEmpty;
  }

  // يحدد هل يُسمح بإشعار الموارد البشرية
  bool _hrItemAllowed(Map item) {
    if (!_hrSections.contains(item['section'])) return true;
    if (_hrAuthorizationPending || !PermissionsService().hrNotificationsEnabled)
      return false;
    if (_isOwnHRItem(item)) return true;
    final scope = item['notification_scope'];
    if (_ownHROnly) return false;
    final viewable = PermissionsService().hrViewableEmployees;
    if (viewable != null && viewable.isNotEmpty) {
      return scope is Map &&
          viewable.contains((scope['employee_code'] ?? '').toString());
    }
    return true;
  }

  // يبطل إشعارات الموارد البشرية عند تغيّر التفويض
  Future<int> invalidateHRAuthorization(
      {required String companyCode, required String uid}) async {
    return CachePartitions.run(() async {
      final generation = ++_hrAuthorizationGeneration;
      _scopeVersion++;
      _hrAuthorizationPending = true;
      if (!CachePartitions.isBoxOpen(_boxName)) return generation;
      final keys = _box.keys.where((key) {
        final item = _box.get(key);
        return item is Map &&
            item['recipient_uid'] == uid &&
            item['company_code'] == companyCode &&
            _hrSections.contains(item['section']);
      }).toList();
      if (keys.isNotEmpty) {
        await _box.deleteAll(keys);
        await _box.compact();
      }
      if (CachePartitions.isBoxOpen(_settingsBoxName)) {
        await _settings.delete('notification_cursor_${uid}_$companyCode');
      }
      return generation;
    });
  }

  // ينهي تحديث تفويض الموارد البشرية
  bool finishHRAuthorization(int generation) {
    if (generation != _hrAuthorizationGeneration) return false;
    _hrAuthorizationPending = false;
    return true;
  }

  // يحدد هل الطلب ما زال صالحًا
  bool _requestIsCurrent(String company, String uid, int scope) =>
      uid.isNotEmpty &&
      FirebaseAuth.instance.currentUser?.uid == uid &&
      (_companyCode == null || _companyCode == company) &&
      PermissionsService().isLoaded &&
      PermissionsService().canShowNotifications &&
      !_hrAuthorizationPending &&
      scope == _scopeVersion;

  // يحدد هل يُسمح بالإشعار
  bool _itemIsAllowed(Map item, String company, String uid) {
    if (!PermissionsService().canShowNotifications) return false;
    if ((item['company_code'] ?? '').toString() != company) return false;
    final recipient = (item['recipient_uid'] ?? '').toString();
    if (recipient.isNotEmpty && recipient != uid) return false;
    if (_isOwnHRItem(item)) return _hrItemAllowed(item);
    final branch = (item['branch_code'] ?? '').toString();
    final allowed = PermissionsService().allowedBranches;
    return (branch.isEmpty ||
            allowed == null ||
            allowed.contains('all') ||
            allowed.contains(branch)) &&
        _canAccessSection((item['section'] ?? '').toString()) &&
        _hrItemAllowed(item);
  }

  // Uses today's existing section predicates, not a new entitlement policy.
  // A revoked notification is disposable cache, never an unsent user edit.
  // يزيل الإشعارات غير المسموح بها من الذاكرة
  Future<int> purgeInaccessibleCache({
    required String companyCode,
    required String? ownerUid,
    required bool scopeChanged,
  }) async {
    return CachePartitions.run(() async {
      if (!CachePartitions.isBoxOpen(_boxName) ||
          ownerUid == null ||
          ownerUid.isEmpty ||
          FirebaseAuth.instance.currentUser?.uid != ownerUid ||
          (_companyCode != null && _companyCode != companyCode) ||
          !PermissionsService().isLoaded) return 0;
      if (scopeChanged) _scopeVersion++;
      final scope = _scopeVersion;
      if (scopeChanged) {
        if (CachePartitions.isBoxOpen(_settingsBoxName)) {
          await _settings
              .delete('notification_cursor_${ownerUid}_$companyCode');
        }
      }
      var removed = 0;
      for (final key in _box.keys.toList()) {
        if (!_requestIsCurrent(companyCode, ownerUid, scope)) return removed;
        final item = _box.get(key);
        if (item is! Map ||
            item['company_code'] != companyCode ||
            item['recipient_uid'] != ownerUid) continue;
        if (!_itemIsAllowed(item, companyCode, ownerUid)) {
          await _box.delete(key);
          removed++;
        }
      }
      // Hive deletion alone leaves old frames in its append-only file.
      if (removed > 0) await _box.compact();
      if (scopeChanged &&
          _companyCode == companyCode &&
          _requestIsCurrent(companyCode, ownerUid, scope)) {
        unawaited(refreshFromServer(companyCode: companyCode));
      }
      return removed;
    });
  }

  // يحدد هل المستلم هو نفسه
  bool _sameRecipient(dynamic item, String company, String uid) =>
      item is Map &&
      item['recipient_uid'] == uid &&
      item['company_code'] == company;

  // يحدد هل الإشعار مفعّل للقسم والإجراء
  bool _enabled(String section, String action) {
    const commercialSections = {
      'sales',
      'sales_returns',
      'customer_payments',
      'stock_transfers'
    };
    if (!PermissionsService().canShowNotifications) return false;
    final defaultEnabled = !commercialSections.contains(section);
    return _settings.get('enabled_$section', defaultValue: defaultEnabled) ==
            true &&
        _settings.get('event_$action', defaultValue: true) == true;
  }

  // يعالج حدث مزامنة وارد
  Future<void> handleSyncEvent(Map<String, dynamic> event) async {
    return CachePartitions.run(() async {
      final receivedScope = _scopeVersion;
      final receivedUid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (receivedUid.isEmpty) return;
      try {
        if (_settingsLoad != null) {
          await _settingsLoad!.timeout(
            const Duration(milliseconds: 500),
            onTimeout: () {},
          );
        }

        // ✅ NEW: لا تحفظ حدث قبل تحميل الصلاحيات
        // عشان نتجنب حفظ إشعارات بصلاحيات افتراضية غلط
        if (!PermissionsService().isLoaded ||
            FirebaseAuth.instance.currentUser?.uid != receivedUid) {
          print('⏳ الصلاحيات مش متحملة — تجاهل حدث ${event['type']}');
          return;
        }

        final type = (event['type'] ?? '').toString();
        final section = _sections[type];
        if (section == null) return;
        final raw = event['data'];
        if (raw is! Map) return;
        final data = Map<String, dynamic>.from(raw);
        final companyCode =
            (data['company_code'] ?? event['company_code'] ?? '').toString();
        final currentUser = FirebaseAuth.instance.currentUser;
        final uid = currentUser?.uid ?? '';
        final actorUid =
            (event['actor_uid'] ?? data['actor_uid'] ?? '').toString();
        if (companyCode.isEmpty ||
            (_companyCode != null && _companyCode != companyCode)) return;

        final rawAction =
            (event['action'] ?? 'update').toString().toLowerCase();
        final action = data['is_deleted'] == true ||
                rawAction == 'delete' ||
                rawAction == 'remove'
            ? 'delete'
            : (rawAction == 'insert' ||
                    rawAction == 'create' ||
                    rawAction == 'add'
                ? 'add'
                : 'edit');
        if (!_enabled(section, action)) return;

        final personal = _isOwnHRItem({
          'section': section,
          'notification_scope': event['notification_scope']
        });
        final branchCode = (data['branch_code'] ?? '').toString();
        final allowedBranches = PermissionsService().allowedBranches;
        if (!personal &&
            branchCode.isNotEmpty &&
            allowedBranches != null &&
            !allowedBranches.contains('all') &&
            !allowedBranches.contains(branchCode)) return;
        if (!personal && !_canAccessSection(section)) return;

        final eventId = (event['event_id'] ?? '').toString();
        final localKey = eventId.isNotEmpty
            ? eventId
            : '${companyCode}_${type}_${action}_${data['id'] ?? data['serial'] ?? data['code'] ?? ''}_${data['updated_at'] ?? data['date'] ?? ''}';
        final existing = _box.get(localKey);
        if (existing is Map &&
            (existing['server_id'] ?? '').toString().isNotEmpty) return;
        final alreadyRead = _sameRecipient(existing, companyCode, uid) &&
            existing['read'] == true;
        final actorEvent =
            uid.isNotEmpty && actorUid.isNotEmpty && actorUid == uid;

        final actorName = (event['actor_name'] ??
                data['actor_name'] ??
                data['employee'] ??
                data['created_by'] ??
                data['updated_by'] ??
                '')
            .toString();
        final detailParts = <String>[];
        // ⭐ لو طلب انضمام — اعرض بيانات مختلفة
        final detailKeys = section == 'registration_requests'
            ? ['name', 'phone_number', 'email', 'note']
            : [
                'name',
                'supplier_name',
                'statement',
                'category',
                'serial',
                'code',
                'branch_code'
              ];
        for (final key in detailKeys) {
          final value = data[key];
          if (value != null && value.toString().trim().isNotEmpty) {
            detailParts.add('${_detailLabel(key)}: ${value.toString()}');
          }
          if (detailParts.length == 2) break;
        }
        if (receivedScope != _scopeVersion ||
            !_hrItemAllowed({
              'section': section,
              'notification_scope': event['notification_scope'],
            })) return;
        await _box.put(localKey, <String, dynamic>{
          'id': localKey,
          'event_key': localKey,
          'server_id': '',
          'recipient_uid': uid,
          'title':
              '${_actionNames[action] ?? 'تغيير'} في ${_sectionNames[section]}',
          'body': detailParts.join(' • '),
          'section': section,
          if (event['notification_scope'] is Map)
            'notification_scope': event['notification_scope'],
          'action': action,
          'company_code': companyCode,
          'branch_code': branchCode,
          'actor_uid': actorUid,
          'actor_name': actorName,
          'created_at': DateTime.now().toIso8601String(),
          'read': actorEvent || alreadyRead,
        });
        await _purgeExpired();
      } catch (e) {
        print('⚠️ تعذر حفظ الإشعار محليًا: $e');
      }
    });
  }

  // يعيد وصف الحقل للعرض
  String _detailLabel(String key) =>
      const {
        'name': 'الاسم', 'supplier_name': 'المورد', 'statement': 'البيان',
        'category': 'التصنيف', 'serial': 'رقم الحركة', 'code': 'الكود',
        'branch_code': 'الفرع',
        // ⭐ جديد
        'phone_number': 'الموبايل',
        'email': 'الإيميل',
        'note': 'ملاحظات',
      }[key] ??
      key;

  // ⭐ Helper موحد لفحص صلاحية الوصول للقسم
  // يحدد هل يحق للمستخدم الوصول للقسم
  bool _canAccessSection(String section) {
    final ps = PermissionsService();
    switch (section) {
      case 'daily':
        return ps.canViewTransactions || ps.canAddTransaction;
      case 'purchases':
        return ps.canViewSupplierHistory || ps.canAddSupplierTransaction;
      case 'settlements':
        return ps.canShowSupplierSettlements;
      case 'coding':
        return ps.canViewCoding;
      case 'inventory':
        return ps.canViewInventory;
      case 'sales':
        return ps.hasPermission('المبيعات', 'معاينة') ||
            ps.hasPermission('المبيعات', 'إضافة');
      case 'sales_returns':
        return ps.hasPermission('المرتجعات', 'معاينة') ||
            ps.hasPermission('المرتجعات', 'إضافة');
      case 'customer_payments':
        return ps.hasPermission('حسابات العملاء', 'معاينة') ||
            ps.hasPermission('حسابات العملاء', 'إضافة تحصيل');
      case 'stock_transfers':
        return ps.hasPermission('التحويلات المخزنية', 'معاينة') ||
            ps.hasPermission('التحويلات المخزنية', 'إضافة');
      // ✅ HR
      case 'hr_attendance':
        return ps.canOpenAttendancePage || ps.canAddAttendance;
      case 'hr_vacations':
        return ps.canOpenVacationsPage || ps.canAddVacation;
      case 'hr_adjustments':
        return ps.canViewAdjustments;
      case 'hr_employees':
        return ps.canViewEmployees || ps.canViewOwnHRData;
      // ⭐ طلبات الانضمام — super_admin فقط
      case 'registration_requests':
        return ps.isSuperAdmin;
      default:
        return false;
    }
  }

  Completer<void>? _refreshEnqueued;

  // يبدأ تحديث الأولوية للشركة
  /// Reserve the first history HTTP slot before business pulls start. Waits
  /// only for enqueue (and the existing bounded settings wait), not download.
  Future<void> startPriorityRefresh({required String companyCode}) async {
    unawaited(refreshFromServer(companyCode: companyCode));
    final enqueued = _refreshEnqueued;
    if (enqueued != null) await enqueued.future;
  }

  // يحدّث الإشعارات من الخادم
  Future<void> refreshFromServer({String? companyCode}) {
    final company = companyCode ?? _companyCode;
    if (company == null || company.isEmpty) return Future<void>.value();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final scope = _scopeVersion;
    if (_refreshInFlight != null &&
        _refreshCompany == company &&
        _refreshUid == uid &&
        _refreshScope == scope) return _refreshInFlight!;

    final enqueued = Completer<void>();
    _refreshEnqueued = enqueued;
    final task =
        _refreshFromServer(company, uid, scope, enqueued).whenComplete(() {
      if (!enqueued.isCompleted) enqueued.complete();
    });
    _refreshCompany = company;
    _refreshUid = uid;
    _refreshScope = scope;
    _refreshInFlight = task;
    return task.whenComplete(() {
      if (identical(_refreshInFlight, task)) {
        _refreshInFlight = null;
        _refreshCompany = null;
        _refreshUid = null;
        _refreshScope = null;
      }
    });
  }

  // تحديث مخصص للإشعارات غير المقروءة فقط، دون تحريك مؤشر المزامنة التزايدية.
  // يحدّث عدد غير المقروء من الخادم
  Future<void> refreshUnreadFromServer({String? companyCode}) async {
    return CachePartitions.run(() async {
      final company = companyCode ?? _companyCode;
      if (company == null || company.isEmpty) return;
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final scope = _scopeVersion;

      try {
        if (_settingsLoad != null) {
          await _settingsLoad!.timeout(
            const Duration(milliseconds: 500),
            onTimeout: () {},
          );
        }
        if (!_requestIsCurrent(company, uid, scope)) return;
        final uri = Uri.parse('${ApiConstants.baseUrl}/notifications').replace(
          queryParameters: const {'limit': '100', 'unread_only': 'true'},
        );
        final response =
            await AuthHttp.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200 ||
            !_requestIsCurrent(company, uid, scope)) return;
        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['items'] is! List) return;

        for (final raw in decoded['items'] as List) {
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(raw);
          if (!_requestIsCurrent(company, uid, scope)) return;
          if (!_itemIsAllowed(item, company, uid) || item['read'] == true)
            continue;
          final eventKey = (item['event_id'] ?? item['id'] ?? '').toString();
          if (eventKey.isEmpty) continue;
          final previous = _box.get(eventKey);
          item['id'] = eventKey;
          item['event_key'] = eventKey;
          item['server_id'] = (raw['id'] ?? '').toString();
          item['recipient_uid'] = uid;
          // لا نعيد إشعارًا سبق أن علّمه المستخدم كمقروء محليًا.
          item['read'] = _sameRecipient(previous, company, uid) &&
              previous['read'] == true;
          await _box.put(eventKey, item);
        }
        await _purgeExpired();
      } catch (e) {
        print('⚠️ تعذر تحديث الإشعارات غير المقروءة من Neon: $e');
      }
    });
  }

  // يجلب الإشعارات من الخادم ويخزنها
  Future<void> _refreshFromServer(
      String company, String uid, int scope, Completer<void> enqueued) async {
    return CachePartitions.run(() async {
      try {
        if (_settingsLoad != null) {
          await _settingsLoad!.timeout(
            const Duration(milliseconds: 500),
            onTimeout: () {},
          );
        }
        if (!_requestIsCurrent(company, uid, scope)) return;
        final cursorKey = 'notification_cursor_${uid}_$company';
        final savedCursor = _settings.get(cursorKey);
        int? cursor = savedCursor is num
            ? savedCursor.toInt()
            : int.tryParse(savedCursor?.toString() ?? '');
        final initialLoad = cursor == null || cursor <= 0;
        var firstPage = true;
        var pageCount = 0;

        while (pageCount < 10) {
          final currentCursor = cursor ?? 0;
          final int? requestCursor = currentCursor <= 0
              ? null
              : (currentCursor - 50).clamp(0, currentCursor).toInt();
          final query = <String, String>{
            'limit': initialLoad && firstPage ? '100' : '200'
          };
          if (requestCursor != null)
            query['after_id'] = requestCursor.toString();
          final uri = Uri.parse('${ApiConstants.baseUrl}/notifications')
              .replace(queryParameters: query);
          final pendingResponse = AuthHttp.get(uri);
          if (!enqueued.isCompleted) enqueued.complete();
          final response =
              await pendingResponse.timeout(const Duration(seconds: 8));
          if (response.statusCode != 200 ||
              !_requestIsCurrent(company, uid, scope)) return;
          final decoded = jsonDecode(response.body);
          if (decoded is! Map || decoded['items'] is! List) return;

          for (final raw in decoded['items'] as List) {
            if (raw is! Map) continue;
            final item = Map<String, dynamic>.from(raw);
            if (!_requestIsCurrent(company, uid, scope)) return;
            if (!_itemIsAllowed(item, company, uid)) continue;
            final eventKey = (item['event_id'] ?? item['id'] ?? '').toString();
            if (eventKey.isEmpty) continue;
            final previous = _box.get(eventKey);
            item['id'] = eventKey;
            item['event_key'] = eventKey;
            item['server_id'] = (raw['id'] ?? '').toString();
            item['recipient_uid'] = uid;
            item['read'] = raw['read'] == true ||
                (_sameRecipient(previous, company, uid) &&
                    previous['read'] == true);
            await _box.put(eventKey, item);
          }

          if (!_requestIsCurrent(company, uid, scope)) return;
          final nextCursorRaw = decoded['next_cursor'];
          final nextCursor = nextCursorRaw is num
              ? nextCursorRaw.toInt()
              : int.tryParse(nextCursorRaw?.toString() ?? '');
          if (nextCursor != null && nextCursor > (cursor ?? 0)) {
            cursor = nextCursor;
            await _settings.put(cursorKey, cursor);
          }

          pageCount++;
          final hasMore = decoded['has_more'] == true;
          // أول تحميل يقتصر على آخر 100 إشعار؛ المرات التالية تسترجع الجديد فقط.
          if (initialLoad ||
              !hasMore ||
              nextCursor == null ||
              (cursor != null && nextCursor < cursor)) break;
          firstPage = false;
        }
        await _purgeExpired();
      } catch (e) {
        print('⚠️ تعذر تحديث سجل الإشعارات من Neon: $e');
      }
    });
  }

  final settingsChanges = ValueNotifier<int>(0);
  bool _settingsLoaded = false;

  // يضمن تحميل الإعدادات
  Future<void> ensureSettings() async {
    if (_settingsLoad != null) await _settingsLoad;
    if (!_settingsLoaded) await loadSettingsFromServer();
  }

  // يحمّل الإعدادات من الخادم
  Future<void> loadSettingsFromServer({bool force = false}) {
    if (_settingsRequest != null) {
      if (force) _settingsRefreshPending = true;
      return _settingsRequest!;
    }
    final binding = _bindingVersion;
    final task = () async {
      do {
        if (binding != _bindingVersion) return;
        _settingsRefreshPending = false;
        await _loadSettingsFromServer();
      } while (_settingsRefreshPending && binding == _bindingVersion);
    }();
    _settingsRequest = task;
    return task.whenComplete(() {
      if (identical(_settingsRequest, task)) _settingsRequest = null;
    });
  }

  // ينفذ تحميل الإعدادات من الخادم
  Future<void> _loadSettingsFromServer() async {
    return CachePartitions.run(() async {
      final company = _companyCode;
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final generation = _cacheGeneration;
      try {
        final response = await AuthHttp.get(
                Uri.parse('${ApiConstants.baseUrl}/notifications/settings'))
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return;
        final data = jsonDecode(response.body);
        if (data is! Map) return;
        if (company != _companyCode ||
            uid != FirebaseAuth.instance.currentUser?.uid ||
            generation != _cacheGeneration) return;
        final sections = data['sections'];
        if (sections is Map) {
          for (final entry in sections.entries) {
            await _settings.put('enabled_${entry.key}', entry.value == true);
          }
        }
        final actions = data['actions'];
        if (actions is Map) {
          for (final entry in actions.entries) {
            await _settings.put('event_${entry.key}', entry.value == true);
          }
        }
        if (data['retention_days'] is num)
          await _settings.put(
              'retention_days', (data['retention_days'] as num).toInt());
        _settingsLoaded = true;
        settingsChanges.value++;
        await _purgeExpired();
      } catch (e) {
        print('⚠️ تعذر تحديث إعدادات الإشعارات من Neon: $e');
      }
    });
  }

  // ============================================================
  // حفظ الإعدادات على السيرفر (Neon)
  //
  // ⭐ بتستخدم _sectionNames.keys تلقائيًا — فلو أضفت قسم جديد
  //    في _sectionNames (زي HR)، هيتبعت للسيرفر تلقائي.
  // ============================================================

  // يحفظ الإعدادات في الخادم
  Future<void> _saveRemoteSettings() async {
    return CachePartitions.run(() async {
      try {
        final sections = {
          for (final key in _sectionNames.keys) key: sectionEnabled(key)
        };
        final actions = {
          for (final key in const ['add', 'edit', 'delete'])
            key: eventEnabled(key)
        };
        await AuthHttp.put(
          Uri.parse('${ApiConstants.baseUrl}/notifications/settings'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sections': sections,
            'actions': actions,
            'retention_days': retentionDays,
          }),
        ).timeout(const Duration(seconds: 8));
      } catch (e) {
        print('⚠️ تعذر حفظ إعدادات الإشعارات في Neon: $e');
      }
    });
  }

  // يعيد الإشعارات المسموح بها
  List<Map<String, dynamic>> getNotifications({String? companyCode}) {
    if (!PermissionsService().isLoaded ||
        !PermissionsService().canShowNotifications) return [];
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final allowedBranches = PermissionsService().allowedBranches;
    final items = _box.values
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((item) {
      final sameUser = (item['recipient_uid'] ?? '') == currentUid;
      final sameCompany =
          companyCode == null || item['company_code'] == companyCode;
      final branch = (item['branch_code'] ?? '').toString();
      final branchAllowed = branch.isEmpty ||
          allowedBranches == null ||
          allowedBranches.contains('all') ||
          allowedBranches.contains(branch);
      final section = (item['section'] ?? '').toString();
      return sameUser &&
          sameCompany &&
          (_isOwnHRItem(item) ||
              (branchAllowed && _canAccessSection(section))) &&
          _hrItemAllowed(item);
    }).toList();
    items.sort((a, b) => (b['created_at'] ?? '')
        .toString()
        .compareTo((a['created_at'] ?? '').toString()));
    return items;
  }

  // يعيد عدد الإشعارات غير المقروءة
  int unreadCount({String? companyCode}) =>
      getNotifications(companyCode: companyCode)
          .where((e) => e['read'] != true)
          .length;

  // يعلّم إشعارًا كمقروء
  Future<void> markRead(String id) async {
    return CachePartitions.run(() async {
      final entry = _findEntry(id);
      if (entry == null) return;
      final key = entry.key;
      final item = Map<String, dynamic>.from(entry.value as Map);
      item['read'] = true;
      await _box.put(key, item);
      final serverId = (item['server_id'] ?? '').toString();
      try {
        final endpoint = serverId.isNotEmpty
            ? '${ApiConstants.baseUrl}/notifications/$serverId/read'
            : '${ApiConstants.baseUrl}/notifications/event/${item['event_key'] ?? id}/read';
        await AuthHttp.post(Uri.parse(endpoint));
      } catch (_) {}

      await _syncBadgeForCompany(_companyCode);
    });
  }

  // يبحث عن إشعار بالمعرّف
  MapEntry<dynamic, dynamic>? _findEntry(String id) {
    for (final entry in _box.toMap().entries) {
      if (entry.value is Map) {
        final item = Map<String, dynamic>.from(entry.value as Map);
        if (entry.key.toString() == id ||
            item['id']?.toString() == id ||
            item['event_key']?.toString() == id ||
            item['server_id']?.toString() == id)
          return MapEntry(entry.key, entry.value);
      }
    }
    return null;
  }

  // يعلّم كل الإشعارات كمقروءة
  Future<void> markAllRead({String? companyCode}) async {
    return CachePartitions.run(() async {
      final targetCompany = companyCode ?? _companyCode;
      for (final item in getNotifications(companyCode: targetCompany)) {
        if (item['read'] == true) continue;
        final entry = _findEntry(item['id'].toString());
        if (entry == null) continue;
        final updated = Map<String, dynamic>.from(entry.value as Map)
          ..['read'] = true;
        await _box.put(entry.key, updated);
      }
      try {
        await AuthHttp.post(
            Uri.parse('${ApiConstants.baseUrl}/notifications/read-all'));
      } catch (_) {}

      await _syncBadgeForCompany(targetCompany);
    });
  }

  // ⭐ حذف إشعار واحد (by event_key أو server_id)
  // يحذف إشعارًا
  Future<void> deleteNotification({required String notificationId}) async {
    return CachePartitions.run(() async {
      final entry = _findEntry(notificationId);
      if (entry == null) return;

      final item = Map<String, dynamic>.from(entry.value as Map);
      final serverId = (item['server_id'] ?? '').toString();
      final eventKey =
          (item['event_key'] ?? item['id'] ?? notificationId).toString();

      await _box.delete(entry.key);

      try {
        if (serverId.isNotEmpty) {
          await AuthHttp.delete(
            Uri.parse('${ApiConstants.baseUrl}/notifications/$serverId'),
          );
        } else {
          debugPrint('ℹ️ deleteNotification: local-only (event=$eventKey)');
        }
      } catch (e) {
        debugPrint('⚠️ deleteNotification remote failed: $e');
      }
    });
  }

  // يمسح الإشعارات
  Future<void> clear({String? companyCode}) async {
    return CachePartitions.run(() async {
      final targetCompany = companyCode ?? _companyCode;
      for (final item in getNotifications(companyCode: targetCompany)) {
        final entry = _findEntry(item['id'].toString());
        if (entry != null) await _box.delete(entry.key);
      }
      try {
        await AuthHttp.delete(
            Uri.parse('${ApiConstants.baseUrl}/notifications'));
      } catch (_) {}
    });
  }

  // يعيد مدة الاحتفاظ بالإشعارات بالأيام
  int get retentionDays =>
      (_settings.get('retention_days', defaultValue: 90) as num).toInt();

  // يضبط مدة الاحتفاظ بالإشعارات
  Future<void> setRetentionDays(int days) async {
    return CachePartitions.run(() async {
      await _settings.put('retention_days', days);
      await _purgeExpired();
      await _saveRemoteSettings();
    });
  }

  // يزيل الإشعارات المنتهية
  Future<void> _purgeExpired() async {
    return CachePartitions.run(() async {
      final days = retentionDays;
      if (days <= 0) return;
      final cutoff = DateTime.now().subtract(Duration(days: days));
      for (final entry in _box.toMap().entries) {
        if (entry.value is Map) {
          final item = Map<String, dynamic>.from(entry.value as Map);
          final date = DateTime.tryParse((item['created_at'] ?? '').toString());
          if (date != null && date.isBefore(cutoff))
            await _box.delete(entry.key);
        }
      }
    });
  }

  // يفعّل أو يعطّل إشعارات قسم
  Future<void> setSectionEnabled(String section, bool value) async {
    return CachePartitions.run(() async {
      final keys = section == 'commercial'
          ? const [
              'sales',
              'sales_returns',
              'customer_payments',
              'stock_transfers'
            ]
          : [section];
      for (final key in keys) {
        await _settings.put('enabled_$key', value);
      }
      await _saveRemoteSettings();
    });
  }

  // يفعّل أو يعطّل إشعارات حدث
  Future<void> setEventEnabled(String event, bool value) async {
    return CachePartitions.run(() async {
      await _settings.put('event_$event', value);
      await _saveRemoteSettings();
    });
  }

  // يحدد هل إشعارات القسم مفعّلة
  bool sectionEnabled(String section) {
    if (section == 'commercial') {
      return const [
        'sales',
        'sales_returns',
        'customer_payments',
        'stock_transfers'
      ].every(
          (key) => _settings.get('enabled_$key', defaultValue: false) == true);
    }
    return _settings.get('enabled_$section', defaultValue: true) == true;
  }

  // يحدد هل إشعارات الحدث مفعّلة
  bool eventEnabled(String event) =>
      _settings.get('event_$event', defaultValue: true) == true;

  // يعيد ضبط الإعدادات ويحمّلها
  Future<void> _resetAndLoadSettings() async {
    return CachePartitions.run(() async {
      for (final key in _sectionNames.keys) {
        await _settings.delete('enabled_$key');
      }
      for (final key in const ['add', 'edit', 'delete']) {
        await _settings.delete('event_$key');
      }
      await _settings.put('retention_days', 90);
      await loadSettingsFromServer();
    });
  }

  // ============================================================
  // ⭐ App Badge (الشارة الحمراء على أيقونة التطبيق)
  // ============================================================

  // يحدّث رقم شارة التطبيق
  /// تحديث شارة العدد على أيقونة التطبيق
  /// (تعمل فقط على PWA المثبتة — Chrome/Edge/Safari)
  Future<void> syncAppBadge(int count) async {
    return CachePartitions.run(() async {
      await jsSyncAppBadge(count < 0 ? 0 : count);
    });
  }

  // ⭐ دالة مساعدة: تحسب unread وتنادي syncAppBadge بعد تأخير بسيط
  // (debounce عشان تتنادى مرة واحدة حتى لو حصلت عمليات كتير)
  Timer? _badgeDebounceTimer;

  // يحدّث الشارة للشركة
  Future<void> _syncBadgeForCompany(String? companyCode) async {
    return CachePartitions.run(() async {
      _badgeDebounceTimer?.cancel();
      _badgeDebounceTimer = Timer(const Duration(milliseconds: 100), () async {
        try {
          final unread = unreadCount(companyCode: companyCode);
          debugPrint(
              '🔔 [Badge] syncAppBadge($unread) for company=$companyCode');
          await jsSyncAppBadge(unread);
        } catch (e) {
          debugPrint('⚠️ [Badge] syncAppBadge failed: $e');
        }
      });

      // انتظر شوية عشان الـ debounce ينفذ قبل ما نرجع
      await Future.delayed(const Duration(milliseconds: 150));
    });
  }

  // يربط الخدمة بالشركة قبل عمل المقبس
  /// Bind before socket work. A later Home mount must not reset that same work.
  bool bindCompany(String companyCode) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final changed = _cacheGeneration != CachePartitions.generation ||
        _companyCode != companyCode ||
        _boundUid != uid ||
        !identical(_boundSettingsIdentity,
            CachePartitions.boxIdentity(_settingsBoxName));
    if (!changed) return false;
    _boundUid = uid;
    _boundSettingsIdentity = CachePartitions.boxIdentity(_settingsBoxName);
    _bindingVersion++;
    _cacheGeneration = CachePartitions.generation;
    _companyCode = companyCode;
    _settingsLoaded = false;
    _settingsRequest = null;
    _settingsRefreshPending = false;
    _settingsLoad = null;
    _refreshInFlight = null;
    _refreshScope = null;
    _scopeVersion++;
    _hrAuthorizationGeneration++;
    _hrAuthorizationPending = false;
    unawaited(_settings.put('user_company_code', companyCode));
    unawaited(_settings.put('active_uid', uid));
    return true;
  }

  String? _boundUid;
  Object? _boundSettingsIdentity;

  // يضبط الشركة الحالية
  void setCompany(String companyCode) {
    if (!bindCompany(companyCode)) return;
    _settingsLoad = _resetAndLoadSettings();
    unawaited(_settingsLoad!);
    unawaited(refreshFromServer(companyCode: companyCode));
  }
}
