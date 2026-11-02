import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants.dart';
import 'auth_http.dart';
import 'permissions_service.dart';

/// الإشعارات المحلية تعمل كذاكرة سريعة، بينما Neon هو مصدر سجل الإشعارات وإعداداتها.
class NotificationsService {
  static final NotificationsService instance = NotificationsService._();
  NotificationsService._();

  static const String _boxName = 'notifications_box';
  static const String _settingsBoxName = 'notification_settings_box';

  Box get _box => Hive.box(_boxName);
  Box get _settings => Hive.box(_settingsBoxName);

  static const Map<String, String> _sections = {
    'transaction': 'daily',
    'supplier': 'purchases',
    'settlement': 'settlements',
    'coding': 'coding',
    'inventory': 'inventory',
  };

  static const Map<String, String> _sectionNames = {
    'daily': 'اليوميات',
    'purchases': 'المشتريات والموردين',
    'settlements': 'التسويات',
    'coding': 'التكويد',
    'inventory': 'الجرد',
  };

  static const Map<String, String> _actionNames = {
    'add': 'إضافة', 'insert': 'إضافة', 'create': 'إضافة',
    'update': 'تعديل', 'edit': 'تعديل', 'delete': 'حذف', 'remove': 'حذف',
  };

  String? _companyCode;
  Future<void>? _settingsLoad;
  Future<void>? _refreshInFlight;
  String? _refreshCompany;

  bool _enabled(String section, String action) =>
      _settings.get('enabled_$section', defaultValue: true) == true &&
      _settings.get('event_$action', defaultValue: true) == true;

  Future<void> handleSyncEvent(Map<String, dynamic> event) async {
  try {
    if (_settingsLoad != null) {
      await _settingsLoad!.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }

    // ✅ NEW: لا تحفظ حدث قبل تحميل الصلاحيات
    // عشان نتجنب حفظ إشعارات بصلاحيات افتراضية غلط
    if (!PermissionsService().isLoaded) {
      print('⏳ الصلاحيات مش متحملة — تجاهل حدث ${event['type']}');
      return;
    }

    final type = (event['type'] ?? '').toString();
      final section = _sections[type];
      if (section == null) return;
      final raw = event['data'];
      if (raw is! Map) return;
      final data = Map<String, dynamic>.from(raw);
      final companyCode = (data['company_code'] ?? event['company_code'] ?? '').toString();
      final currentUser = FirebaseAuth.instance.currentUser;
      final uid = currentUser?.uid ?? '';
      final actorUid = (event['actor_uid'] ?? data['actor_uid'] ?? '').toString();
      if (companyCode.isEmpty || (_companyCode != null && _companyCode != companyCode)) return;

      final rawAction = (event['action'] ?? 'update').toString().toLowerCase();
      final action = data['is_deleted'] == true || rawAction == 'delete' || rawAction == 'remove'
          ? 'delete'
          : (rawAction == 'insert' || rawAction == 'create' || rawAction == 'add' ? 'add' : 'edit');
      if (!_enabled(section, action)) return;

      final branchCode = (data['branch_code'] ?? '').toString();
      final allowedBranches = PermissionsService().allowedBranches;
      if (branchCode.isNotEmpty && allowedBranches != null && !allowedBranches.contains('all') && !allowedBranches.contains(branchCode)) return;
      final canAccessSection = section == 'daily' ? PermissionsService().canShowTreasury : section == 'purchases' ? PermissionsService().canShowSuppliers : section == 'settlements' ? PermissionsService().canShowSupplierSettlements : section == 'coding' ? PermissionsService().canShowCoding : PermissionsService().canShowInventory;
      if (!canAccessSection) return;

      final eventId = (event['event_id'] ?? '').toString();
      final localKey = eventId.isNotEmpty ? eventId : '${companyCode}_${type}_${action}_${data['id'] ?? data['serial'] ?? data['code'] ?? ''}_${data['updated_at'] ?? data['date'] ?? ''}';
      final existing = _box.get(localKey);
      if (existing is Map && (existing['server_id'] ?? '').toString().isNotEmpty) return;
      final alreadyRead = existing is Map && existing['read'] == true;
      final actorEvent = uid.isNotEmpty && actorUid.isNotEmpty && actorUid == uid;

      final actorName = (event['actor_name'] ?? data['actor_name'] ?? data['employee'] ?? data['created_by'] ?? data['updated_by'] ?? '').toString();
      final detailParts = <String>[];
      for (final key in ['name', 'supplier_name', 'statement', 'category', 'serial', 'code', 'branch_code']) {
        final value = data[key];
        if (value != null && value.toString().trim().isNotEmpty) detailParts.add('${_detailLabel(key)}: ${value.toString()}');
        if (detailParts.length == 2) break;
      }
      await _box.put(localKey, <String, dynamic>{
        'id': localKey,
        'event_key': localKey,
        'server_id': '',
        'recipient_uid': uid,
        'title': '${_actionNames[action] ?? 'تغيير'} في ${_sectionNames[section]}',
        'body': detailParts.join(' • '),
        'section': section,
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
  }

  String _detailLabel(String key) => const {
    'name': 'الاسم', 'supplier_name': 'المورد', 'statement': 'البيان',
    'category': 'التصنيف', 'serial': 'رقم الحركة', 'code': 'الكود',
    'branch_code': 'الفرع',
  }[key] ?? key;

  Future<void> refreshFromServer({String? companyCode}) {
    final company = companyCode ?? _companyCode;
    if (company == null || company.isEmpty) return Future<void>.value();
    if (_refreshInFlight != null && _refreshCompany == company) return _refreshInFlight!;

    final task = _refreshFromServer(company);
    _refreshCompany = company;
    _refreshInFlight = task;
    return task.whenComplete(() {
      if (identical(_refreshInFlight, task)) {
        _refreshInFlight = null;
        _refreshCompany = null;
      }
    });
  }

  // تحديث مخصص للإشعارات غير المقروءة فقط، دون تحريك مؤشر المزامنة التزايدية.
  Future<void> refreshUnreadFromServer({String? companyCode}) async {
  final company = companyCode ?? _companyCode;
  if (company == null || company.isEmpty) return;

  try {
    if (_settingsLoad != null) {
      await _settingsLoad!.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) return;
      final uri = Uri.parse('${ApiConstants.baseUrl}/notifications').replace(
        queryParameters: const {'limit': '100', 'unread_only': 'true'},
      );
      final response = await AuthHttp.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['items'] is! List) return;

      for (final raw in decoded['items'] as List) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        if ((item['company_code'] ?? '').toString() != company || item['read'] == true) continue;
        final eventKey = (item['event_id'] ?? item['id'] ?? '').toString();
        if (eventKey.isEmpty) continue;
        final previous = _box.get(eventKey);
        item['id'] = eventKey;
        item['event_key'] = eventKey;
        item['server_id'] = (raw['id'] ?? '').toString();
        item['recipient_uid'] = uid;
        // لا نعيد إشعارًا سبق أن علّمه المستخدم كمقروء محليًا.
        item['read'] = previous is Map && previous['read'] == true;
        await _box.put(eventKey, item);
      }
      await _purgeExpired();
    } catch (e) {
      print('⚠️ تعذر تحديث الإشعارات غير المقروءة من Neon: $e');
    }
  }

  Future<void> _refreshFromServer(String company) async {
  try {
    if (_settingsLoad != null) {
      await _settingsLoad!.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) return;
      final cursorKey = 'notification_cursor_${uid}_$company';
      final savedCursor = _settings.get(cursorKey);
      int? cursor = savedCursor is num ? savedCursor.toInt() : int.tryParse(savedCursor?.toString() ?? '');
      final initialLoad = cursor == null || cursor <= 0;
      var firstPage = true;
      var pageCount = 0;

      while (pageCount < 10) {
        final currentCursor = cursor ?? 0;
        final int? requestCursor = currentCursor <= 0 ? null : (currentCursor - 50).clamp(0, currentCursor).toInt();
        final query = <String, String>{'limit': initialLoad && firstPage ? '100' : '200'};
        if (requestCursor != null) query['after_id'] = requestCursor.toString();
        final uri = Uri.parse('${ApiConstants.baseUrl}/notifications').replace(queryParameters: query);
        final response = await AuthHttp.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return;
        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['items'] is! List) return;

        for (final raw in decoded['items'] as List) {
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(raw);
          if ((item['company_code'] ?? '').toString() != company) continue;
          final eventKey = (item['event_id'] ?? item['id'] ?? '').toString();
          if (eventKey.isEmpty) continue;
          final previous = _box.get(eventKey);
          item['id'] = eventKey;
          item['event_key'] = eventKey;
          item['server_id'] = (raw['id'] ?? '').toString();
          item['recipient_uid'] = uid;
          item['read'] = raw['read'] == true || (previous is Map && previous['read'] == true);
          await _box.put(eventKey, item);
        }

        final nextCursorRaw = decoded['next_cursor'];
        final nextCursor = nextCursorRaw is num ? nextCursorRaw.toInt() : int.tryParse(nextCursorRaw?.toString() ?? '');
        if (nextCursor != null && nextCursor > (cursor ?? 0)) {
          cursor = nextCursor;
          await _settings.put(cursorKey, cursor);
        }

        pageCount++;
        final hasMore = decoded['has_more'] == true;
        // أول تحميل يقتصر على آخر 100 إشعار؛ المرات التالية تسترجع الجديد فقط.
        if (initialLoad || !hasMore || nextCursor == null || (cursor != null && nextCursor < cursor)) break;
        firstPage = false;
      }
      await _purgeExpired();
    } catch (e) {
      print('⚠️ تعذر تحديث سجل الإشعارات من Neon: $e');
    }
  }


  Future<void> loadSettingsFromServer() async {
    try {
      final response = await AuthHttp.get(Uri.parse('${ApiConstants.baseUrl}/notifications/settings')).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body);
      if (data is! Map) return;
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
      if (data['retention_days'] is num) await _settings.put('retention_days', (data['retention_days'] as num).toInt());
      await _purgeExpired();
    } catch (e) {
      print('⚠️ تعذر تحديث إعدادات الإشعارات من Neon: $e');
    }
  }

  Future<void> _saveRemoteSettings() async {
    try {
      final sections = {for (final key in _sectionNames.keys) key: sectionEnabled(key)};
      final actions = {for (final key in const ['add', 'edit', 'delete']) key: eventEnabled(key)};
      await AuthHttp.put(
        Uri.parse('${ApiConstants.baseUrl}/notifications/settings'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'sections': sections, 'actions': actions, 'retention_days': retentionDays}),
      ).timeout(const Duration(seconds: 8));
    } catch (e) {
      print('⚠️ تعذر حفظ إعدادات الإشعارات في Neon: $e');
    }
  }

  List<Map<String, dynamic>> getNotifications({String? companyCode}) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final allowedBranches = PermissionsService().allowedBranches;
    final items = _box.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).where((item) {
      final sameUser = (item['recipient_uid'] ?? '') == currentUid;
      final sameCompany = companyCode == null || item['company_code'] == companyCode;
      final branch = (item['branch_code'] ?? '').toString();
      final branchAllowed = branch.isEmpty || allowedBranches == null || allowedBranches.contains('all') || allowedBranches.contains(branch);
      final section = (item['section'] ?? '').toString();
      final canAccess = section == 'daily' ? PermissionsService().canShowTreasury : section == 'purchases' ? PermissionsService().canShowSuppliers : section == 'settlements' ? PermissionsService().canShowSupplierSettlements : section == 'coding' ? PermissionsService().canShowCoding : PermissionsService().canShowInventory;
      return sameUser && sameCompany && branchAllowed && canAccess;
    }).toList();
    items.sort((a, b) => (b['created_at'] ?? '').toString().compareTo((a['created_at'] ?? '').toString()));
    return items;
  }

  int unreadCount({String? companyCode}) => getNotifications(companyCode: companyCode).where((e) => e['read'] != true).length;

  Future<void> markRead(String id) async {
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
  }

  MapEntry<dynamic, dynamic>? _findEntry(String id) {
    for (final entry in _box.toMap().entries) {
      if (entry.value is Map) {
        final item = Map<String, dynamic>.from(entry.value as Map);
        if (entry.key.toString() == id || item['id']?.toString() == id || item['event_key']?.toString() == id || item['server_id']?.toString() == id) return MapEntry(entry.key, entry.value);
      }
    }
    return null;
  }

  Future<void> markAllRead({String? companyCode}) async {
    for (final item in getNotifications(companyCode: companyCode)) {
      if (item['read'] == true) continue;
      final entry = _findEntry(item['id'].toString());
      if (entry == null) continue;
      final updated = Map<String, dynamic>.from(entry.value as Map)..['read'] = true;
      await _box.put(entry.key, updated);
    }
    try { await AuthHttp.post(Uri.parse('${ApiConstants.baseUrl}/notifications/read-all')); } catch (_) {}
  }

  Future<void> clear({String? companyCode}) async {
    for (final item in getNotifications(companyCode: companyCode)) {
      final entry = _findEntry(item['id'].toString());
      if (entry != null) await _box.delete(entry.key);
    }
    try { await AuthHttp.delete(Uri.parse('${ApiConstants.baseUrl}/notifications')); } catch (_) {}
  }

  int get retentionDays => (_settings.get('retention_days', defaultValue: 90) as num).toInt();

  Future<void> setRetentionDays(int days) async {
    await _settings.put('retention_days', days);
    await _purgeExpired();
    await _saveRemoteSettings();
  }

  Future<void> _purgeExpired() async {
    final days = retentionDays;
    if (days <= 0) return;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    for (final entry in _box.toMap().entries) {
      if (entry.value is Map) {
        final item = Map<String, dynamic>.from(entry.value as Map);
        final date = DateTime.tryParse((item['created_at'] ?? '').toString());
        if (date != null && date.isBefore(cutoff)) await _box.delete(entry.key);
      }
    }
  }

  Future<void> setSectionEnabled(String section, bool value) async {
    await _settings.put('enabled_$section', value);
    await _saveRemoteSettings();
  }

  Future<void> setEventEnabled(String event, bool value) async {
    await _settings.put('event_$event', value);
    await _saveRemoteSettings();
  }

  bool sectionEnabled(String section) => _settings.get('enabled_$section', defaultValue: true) == true;
  bool eventEnabled(String event) => _settings.get('event_$event', defaultValue: true) == true;

  Future<void> _resetAndLoadSettings() async {
    for (final key in const ['daily', 'purchases', 'settlements', 'coding', 'inventory']) {
      await _settings.delete('enabled_$key');
    }
    for (final key in const ['add', 'edit', 'delete']) {
      await _settings.delete('event_$key');
    }
    await _settings.put('retention_days', 90);
    await loadSettingsFromServer();
  }

  void setCompany(String companyCode) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final changed = _companyCode != companyCode || _settings.get('active_uid') != uid;
    _companyCode = companyCode;
    unawaited(_settings.put('user_company_code', companyCode));
    unawaited(_settings.put('active_uid', uid));
    if (changed) {
      _settingsLoad = _resetAndLoadSettings();
      unawaited(_settingsLoad!);
      unawaited(refreshFromServer(companyCode: companyCode));
    }
  }
}