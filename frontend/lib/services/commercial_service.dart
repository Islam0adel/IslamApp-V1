import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';
import 'auth_http.dart';

/// Sales, customer account and stock movement data are kept apart from the
/// legacy daily journal. Payment allocations still affect this module's own
/// treasury balance.
class CommercialService {

  static const Map<String, String> _boxes = {
    'sales': 'sales_box',
    'returns': 'sales_returns_box',
    'customer-payments': 'customer_payments_box',
    'transfers': 'stock_transfers_box',
  };
    // ⭐ قفل لمنع syncPending المتوازي
  static bool _isPushingPending = false;
  static Timer? _backgroundSyncTimer;
  static String? _backgroundSyncCompany;

  static void startBackgroundSync(String companyCode) {
    _backgroundSyncCompany = companyCode;
    _backgroundSyncTimer ??= Timer.periodic(const Duration(seconds: 3600), (_) {
      final company = _backgroundSyncCompany;
      if (company != null) unawaited(CommercialService().syncPending(company));
    });
    unawaited(CommercialService().syncPending(companyCode));
  }

  String get _baseUrl => ApiConstants.baseUrl;

  String newId() {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final random = Random.secure();
    return '$now-${random.nextInt(0x7fffffff).toRadixString(16)}';
  }

Future<List<Map<String, dynamic>>> fetch(
  String kind,
  String companyCode, {
  String? branchCode,
  bool forceRefresh = false,  // ⭐ المستخدم يضغط "تحديث"
}) async {
  // ⭐ لو مش forceRefresh → ارجع من Hive فوراً
  if (!forceRefresh) {
    return _localRecords(kind, companyCode, branchCode);
  }

  // ⭐ forceRefresh → جيب من السيرفر + حدّث Hive
  try {
    final query = <String, String>{};
    if (branchCode != null && branchCode.isNotEmpty) {
      query['branch_code'] = branchCode;
    }
    final uri = Uri.parse('$_baseUrl/commercial/$kind/list/$companyCode')
        .replace(queryParameters: query.isEmpty ? null : query);

    final response = await AuthHttp.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return _localRecords(kind, companyCode, branchCode);

    final raw = jsonDecode(response.body);
    if (raw is! List) return _localRecords(kind, companyCode, branchCode);

    final records = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

    // احتفظ بالـ pending
    final pending = _localRecords(kind, companyCode, null)
        .where((e) => e['sync_status'] == 'pending' || e['sync_status'] == 'error')
        .toList();
    final pendingIds = pending.map((e) => e['id']?.toString() ?? '').toSet();

    // امسح القديم (من نفس الشركة + الفرع)
    final box = Hive.box(_boxes[kind]!);
    final allBranches = branchCode == null || branchCode.isEmpty ||
        {'all', 'الكل', 'كل الفروع'}.contains(branchCode);
    if (allBranches) {
      await box.clear();
    } else {
      for (final key in box.keys.toList()) {
        final v = box.get(key);
        if (v is List) {
          final filtered = v.whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['company_code']?.toString() != companyCode ||
                  (kind == 'transfers'
                      ? e['from_branch_code']?.toString() != branchCode &&
                          e['to_branch_code']?.toString() != branchCode
                      : e['branch_code']?.toString() != branchCode))
              .toList();
          if (filtered.isEmpty) { await box.delete(key); }
          else { await box.put(key, filtered); }
        }
      }
    }

    // ضيف الجديد + إعادة الـ pending
    for (final record in records) {
      if (pendingIds.contains(record['id']?.toString())) continue;
      record['sync_status'] = 'synced';
      await _putLocal(kind, record);
    }
    for (final p in pending) {
      await _putLocal(kind, p);
    }

    return _localRecords(kind, companyCode, branchCode);
  } catch (_) {
    return _localRecords(kind, companyCode, branchCode);
  }
}


  List<Map<String, dynamic>> _localRecords(String kind, String companyCode, String? branchCode) {
    final box = Hive.box(_boxes[kind]!);
    final allBranches = branchCode == null || branchCode.isEmpty ||
        {'all', 'الكل', 'كل الفروع'}.contains(branchCode);
    return box.values.whereType<List>().expand((v) => v).whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => e['company_code']?.toString() == companyCode &&
            e['is_deleted'] != true &&
            (allBranches || (kind == 'transfers'
                ? e['from_branch_code']?.toString() == branchCode || e['to_branch_code']?.toString() == branchCode
                : e['branch_code']?.toString() == branchCode)))
        .toList();
  }

  int _nextLocalSerial(String kind, String companyCode, String branchCode) {
    var maxSerial = 0;
    for (final row in _localRecords(kind, companyCode, branchCode)) {
      final serial = int.tryParse(row['serial']?.toString() ?? '') ?? 0;
      if (serial > maxSerial) maxSerial = serial;
    }
    return maxSerial + 1;
  }


/// ⭐ بينفذ العمليات المعلقة — يُستدعى:
///   - بعد save (fire-and-forget، مرة واحدة)
///   - عند فتح التطبيق (من syncAllDataIfNeeded)
///   - عند manual refresh
Future<void> syncPending([String? companyCode]) async {
  // ⭐ منع التوازي — لو فيه push شغال، اخرج
  if (_isPushingPending) {
    print('⏭️ [Commercial] syncPending already running — skipped');
    return;
  }

  if (!Hive.isBoxOpen('commercial_pending_box')) return;

  final queue = Hive.box('commercial_pending_box');
  if (queue.isEmpty) return;

  _isPushingPending = true;  // ⭐ قفل

  try {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final targetCompany = companyCode;

  for (final key in queue.keys.toList()) {
    final raw = queue.get(key);
    if (raw is! Map) continue;
    
    final op = Map<String, dynamic>.from(raw);
    if (op['blocked_conflict'] == true) continue;
    
    // فلترة حسب الشركة والمستخدم
    if (targetCompany != null &&
        op['company_code']?.toString() != targetCompany) {
      continue;
    }
    if (op['user_uid']?.toString().isNotEmpty == true &&
        op['user_uid']?.toString() != uid) {
      continue;
    }

    try {
      if (op['action'] == 'delete') {
        final response = await AuthHttp.post(
          Uri.parse('$_baseUrl/commercial/${op['kind']}/delete/'
              '${op['company_code']}/${op['id']}'),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200 || response.statusCode == 404) {
          await queue.delete(key);
        }
      } else {
        final data = Map<String, dynamic>.from(op['data'] as Map);
        if (data['provisional_serial'] == true) data['serial'] = 0;

        final response = await AuthHttp.post(
          Uri.parse('$_baseUrl/commercial/${op['kind']}/save'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(data),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final result = Map<String, dynamic>.from(jsonDecode(response.body));
          data['serial'] = result['serial'] ?? data['serial'] ?? 0;
          if (result['updated_at'] != null) data['updated_at'] = result['updated_at'];
          data.remove('provisional_serial');
          data['sync_status'] = 'synced';
          data.remove('last_error');
          await _putLocal(op['kind'].toString(), data);
          await queue.delete(key);
        } else {
          await _updateLocalSyncStatus(
            op['kind'].toString(), op['id']?.toString() ?? '',
            response.statusCode == 409 ? 'conflict' : 'error',
            'HTTP ${response.statusCode}: ${response.body}',
          );
          if (response.statusCode == 409) {
            op['blocked_conflict'] = true;
            await queue.put(key, op);
          }
        }
      }
    } catch (e) {
      // فشل — علّم السجل + سيب العملية في Queue
      await _updateLocalSyncStatus(
        op['kind'].toString(),
        op['id']?.toString() ?? '',
        'error',
        e.toString(),
      );
    }
  }
  } finally {
    _isPushingPending = false;  // ⭐ فك القفل (حتى لو حصل خطأ)
  }
}

  Future<Map<String, dynamic>> save(String kind, Map<String, dynamic> data) async {
    final serverData = Map<String, dynamic>.from(data);
    final branch = (data['branch_code'] ?? data['from_branch_code'] ?? '').toString();
    final isNew = (int.tryParse(data['serial']?.toString() ?? '0') ?? 0) <= 0 ||
        data['provisional_serial'] == true;
    if (isNew) {
      if (data['provisional_serial'] != true) {
        data['serial'] = _nextLocalSerial(kind, data['company_code'].toString(), branch);
      }
      data['provisional_serial'] = true;
      serverData['serial'] = 0;
      serverData['provisional_serial'] = true;
    }
    data['updated_at'] = DateTime.now().toUtc().toIso8601String();
    data['is_deleted'] = false;
    data['sync_status'] = 'pending';
    await _putLocal(kind, data);
    final queue = Hive.box('commercial_pending_box');
    final key = '$kind:${data['id']}';
    final revision = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    await queue.put(key, {'kind': kind, 'action': 'save', 'id': data['id'],
      'company_code': data['company_code'], 'user_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
      'revision': revision, 'attempted': false, 'blocked_conflict': false, 'data': serverData});
    unawaited(syncPending(data['company_code']?.toString()));
    return {'status': 'success', 'serial': data['serial'] ?? 0, 'pending_sync': true};
  }

  Future<void> delete(String kind, String companyCode, String id) async {
    final box = Hive.box(_boxes[kind]!);
    await Hive.box('commercial_stock_events_box').delete('${companyCode}_synced_at');
    for (final key in box.keys.toList()) {
      final values = box.get(key);
      if (values is! List) continue;
      final list = values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      for (final item in list.where((e) => e['id']?.toString() == id)) {
        item['is_deleted'] = true;
      }
      await box.put(key, list);
    }
    final pending = Hive.box('commercial_pending_box');
    final previous = pending.get('$kind:$id');
    if (previous is Map && previous['action'] == 'save' && previous['attempted'] != true) {
      await pending.delete('$kind:$id');
      return;
    }
    final revision = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    await pending.put('$kind:$id', {'kind': kind, 'action': 'delete', 'id': id, 'company_code': companyCode,
      'user_uid': FirebaseAuth.instance.currentUser?.uid ?? '', 'revision': revision, 'attempted': false});
    unawaited(syncPending(companyCode));
  }


  Future<void> _updateLocalSyncStatus(String kind, String id, String status, String error) async {
    final box = Hive.box(_boxes[kind]!);
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! List) continue;
      final list = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      var changed = false;
      for (final item in list.where((e) => e['id']?.toString() == id)) {
        item['sync_status'] = status;
        item['last_error'] = error;
        changed = true;
      }
      if (changed) await box.put(key, list);
    }
  }

  Future<void> _putLocal(String kind, Map<String, dynamic> data) async {
    final box = Hive.box(_boxes[kind]!);
    await Hive.box('commercial_stock_events_box').delete('${data['company_code']}_synced_at');
    for (final oldKey in box.keys.toList()) {
      final oldValue = box.get(oldKey);
      if (oldValue is! List) continue;
      final oldList = oldValue.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      oldList.removeWhere((e) => e['id']?.toString() == data['id']?.toString());
      if (oldList.length != oldValue.length) {
        if (oldList.isEmpty) { await box.delete(oldKey); } else { await box.put(oldKey, oldList); }
      }
    }
    final company = data['company_code']?.toString() ?? '';
    final date = data['date']?.toString() ?? '';
    final branch = kind == 'transfers'
        ? data['from_branch_code']?.toString() ?? ''
        : data['branch_code']?.toString() ?? '';
    final key = '${company}_${branch}_$date';
    final existing = box.get(key);
    final list = existing is List
        ? existing.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    list.removeWhere((e) => e['id']?.toString() == data['id']?.toString());
    list.add(Map<String, dynamic>.from(data));
    await box.put(key, list);
  }

  Future<void> refreshStockEvents(String companyCode) async {
    final box = Hive.box('commercial_stock_events_box');
    final syncedAt = DateTime.tryParse(box.get('${companyCode}_synced_at')?.toString() ?? '');
    if (syncedAt != null && DateTime.now().difference(syncedAt).inSeconds < 30) return;
    try {
      final response = await AuthHttp.get(Uri.parse('$_baseUrl/commercial/stock-events/$companyCode'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) throw Exception(response.body);
      final raw = jsonDecode(response.body);
      final events = raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : <Map<String, dynamic>>[];
      await box.put(companyCode, events);
      await box.put('${companyCode}_synced_at', DateTime.now().toIso8601String());
    } catch (_) {
      // Preserve the last good snapshot for offline stock views.
    }
  }

  Future<double> customerBalance(String companyCode, String customerCode,
      {String? branchCode}) async {
    final sales = await fetch('sales', companyCode, branchCode: branchCode);
    final returns = await fetch('returns', companyCode, branchCode: branchCode);
    final receipts = await fetch('customer-payments', companyCode, branchCode: branchCode);
    var balance = 0.0;
    for (final sale in sales.where((e) => e['customer_code']?.toString() == customerCode)) {
      balance += _num(sale['due']);
    }
    for (final receipt in receipts.where((e) => e['customer_code']?.toString() == customerCode)) {
      balance -= _num(receipt['amount']);
    }
    for (final returned in returns.where((e) => e['customer_code']?.toString() == customerCode)) {
      // Returns first offset the customer's open balance; any refund over that
      // amount is paid out from the selected treasury and does not create debt.
      balance -= _num(returned['credit_amount'] ?? returned['total']);
    }
    return max(0, balance).toDouble();
  }

  Future<List<Map<String, dynamic>>> customerBalances(
    String companyCode, {
    String? branchCode,
    String? toDate,
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) {
      for (final kind in const ['sales', 'returns', 'customer-payments']) {
        try {
          await fetch(kind, companyCode, branchCode: branchCode, forceRefresh: true);
        } catch (_) {}
      }
    }
    final sales = _localRecords('sales', companyCode, branchCode);
    final returns = _localRecords('returns', companyCode, branchCode);
    final receipts = _localRecords('customer-payments', companyCode, branchCode);
    final balances = <String, Map<String, dynamic>>{};
    bool withinDate(Map<String, dynamic> record) =>
        toDate == null || (record['date']?.toString() ?? '').compareTo(toDate) <= 0;
    Map<String, dynamic> entry(String code, String name) =>
        balances.putIfAbsent(code, () => {
          'customer_code': code,
          'customer_name': name,
          'balance': 0.0,
        });
    for (final sale in sales.where(withinDate)) {
      final code = sale['customer_code']?.toString() ?? '';
      if (code.isEmpty) continue;
      final row = entry(code, sale['customer_name']?.toString() ?? '');
      row['balance'] = _num(row['balance']) + _num(sale['due']);
    }
    for (final receipt in receipts.where(withinDate)) {
      final code = receipt['customer_code']?.toString() ?? '';
      if (code.isEmpty) continue;
      final row = entry(code, receipt['customer_name']?.toString() ?? '');
      row['balance'] = _num(row['balance']) - _num(receipt['amount']);
    }
    for (final returned in returns.where(withinDate)) {
      final code = returned['customer_code']?.toString() ?? '';
      if (code.isEmpty) continue;
      final row = entry(code, returned['customer_name']?.toString() ?? '');
      row['balance'] = _num(row['balance']) -
          _num(returned['credit_amount'] ?? returned['total']);
    }
    return balances.values
        .map((row) => {...row, 'balance': max(0, _num(row['balance']))})
        .toList()
      ..sort((a, b) => (a['customer_name']?.toString() ?? '')
          .compareTo(b['customer_name']?.toString() ?? ''));
  }

  Future<Map<String, dynamic>> returnableSale(
    String companyCode,
    String saleId, {
    String? toDate,
    String? excludeReturnId,
    bool forceRefresh = false,
  }) async {
    final query = <String, String>{};
    if (toDate != null) query['to_date'] = toDate;
    if (excludeReturnId != null) query['exclude_return_id'] = excludeReturnId;
    final uri = Uri.parse('$_baseUrl/commercial/returnable/$companyCode/$saleId').replace(
      queryParameters: query.isEmpty ? null : query,
    );
    if (forceRefresh) {
      try {
        final response = await AuthHttp.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(response.body));
      } catch (_) {}
    }

    final sales = _localRecords('sales', companyCode, null);
    final sale = sales.firstWhere((e) => e['id']?.toString() == saleId,
        orElse: () => <String, dynamic>{});
    if (sale.isEmpty) throw Exception('فاتورة البيع غير متاحة على هذا الجهاز');
    final returned = _localRecords('returns', companyCode, null).where((e) =>
        e['sale_id']?.toString() == saleId && e['id']?.toString() != excludeReturnId &&
        (toDate == null || (e['date']?.toString() ?? '').compareTo(toDate) <= 0));
    final quantities = <String, double>{};
    for (final record in returned) {
      final items = record['items'];
      if (items is! List) continue;
      for (final item in items.whereType<Map>()) {
        final code = item['code']?.toString() ?? '';
        quantities[code] = (quantities[code] ?? 0) + _num(item['quantity']);
      }
    }
    final remaining = <String, double>{};
    final saleItems = sale['items'];
    if (saleItems is List) {
      for (final item in saleItems.whereType<Map>()) {
        final code = item['code']?.toString() ?? '';
        remaining[code] = max(0, _num(item['quantity']) - (quantities[code] ?? 0)).toDouble();
      }
    }
    return {
      'remaining_quantities': remaining,
      'customer_balance': await customerBalance(companyCode, sale['customer_code']?.toString() ?? '', branchCode: sale['branch_code']?.toString()),
    };
  }
    // ============================================================
  // ⭐ FULL SYNC — أول مرة (last_sync = null)
  // ============================================================
  Future<void> fetchAll(String kind, String companyCode) async {
    print('📥 [Commercial/$kind] بدء FULL SYNC...');

    try {
      final uri = Uri.parse('$_baseUrl/commercial/$kind/list/$companyCode');
      final response = await AuthHttp.get(uri)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('فشل تحميل $kind. HTTP ${response.statusCode}');
      }

      final raw = jsonDecode(response.body);
      if (raw is! List) throw Exception('بيانات غير صالحة');

      final records = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      // ⭐ احتفظ بالـ pending items (مش هنمسحها)
      final pending = _localRecords(kind, companyCode, null)
          .where((e) =>
              e['sync_status'] == 'pending' || e['sync_status'] == 'error')
          .toList();
      final pendingIds =
          pending.map((e) => e['id']?.toString() ?? '').toSet();

      // امسح كل الـ synced القديمة
      final box = Hive.box(_boxes[kind]!);
      await box.clear();

      // أضف records من السيرفر (ما عدا الـ pending)
      for (final record in records) {
        final id = record['id']?.toString() ?? '';
        if (pendingIds.contains(id)) continue;
        record['sync_status'] = 'synced';
        await _putLocal(kind, record);
      }

      // أعد إضافة الـ pending
      for (final record in pending) {
        await _putLocal(kind, record);
      }

      print('✅ FULL SYNC [$kind]: ${records.length} سجل'
          ' (${pending.length} pending محفوظ)');
    } catch (e) {
      print('❌ فشل FULL SYNC [$kind]: $e');
      rethrow;
    }
  }

  // ============================================================
  // ⭐ INCREMENTAL SYNC — last_sync موجود
  // ============================================================
  Future<void> syncChangesFromServer(
    String kind,
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncKey = '${_lastSyncKeyFor(kind)}$companyCode';
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    // مفيش last_sync → Full sync
    if (lastSyncValue == null || lastSyncValue.isEmpty) {
      print('📥 [$kind] لا يوجد lastSync → FULL SYNC');
      await fetchAll(kind, companyCode);
      await prefs.setString(
          lastSyncKey, DateTime.now().toUtc().toIso8601String());
      return;
    }

    print('📡 [$kind] INCREMENTAL SYNC منذ $lastSyncValue');

    try {
      final syncStartedAt = DateTime.now().toUtc();
      final sinceDt = DateTime.parse(lastSyncValue).toUtc();
      final effectiveSince = sinceDt.toIso8601String();

      final uri =
          Uri.parse('$_baseUrl/commercial/$kind/changes/$companyCode')
              .replace(queryParameters: {'since': effectiveSince});

      final response =
          await AuthHttp.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception(
            'فشل مزامنة $kind. HTTP ${response.statusCode}');
      }

      final raw = jsonDecode(response.body);
      if (raw is! List) throw Exception('بيانات غير صالحة');

      final changes = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      if (changes.isEmpty) {
        print('⏭️ [$kind] لا يوجد تغييرات');
        await prefs.setString(
            lastSyncKey, syncStartedAt.toIso8601String());
        return;
      }

      // ⭐ احتفظ بالـ pending items — مش هنعمل overwrite عليها
      final pending = _localRecords(kind, companyCode, null)
          .where((e) =>
              e['sync_status'] == 'pending' || e['sync_status'] == 'error')
          .toList();
      final pendingIds =
          pending.map((e) => e['id']?.toString() ?? '').toSet();

      int applied = 0;
      int skipped = 0;

      for (final change in changes) {
        final id = change['id']?.toString() ?? '';
        if (id.isEmpty) continue;

        // في pending → متعملش overwrite
        if (pendingIds.contains(id)) {
          skipped++;
          continue;
        }

        final action = change['action']?.toString() ??
            (change['is_deleted'] == true ? 'delete' : 'update');

        if (action == 'delete' || change['is_deleted'] == true) {
          await _removeLocalById(kind, id);
        } else {
          change['sync_status'] = 'synced';
          await _putLocal(kind, change);
        }
        applied++;
      }

      // ⭐ حفظ last_sync بعد النجاح
      await prefs.setString(
          lastSyncKey, syncStartedAt.toIso8601String());

      print('✅ [$kind] مزامنة: $applied تغيير ($skipped متخطي - pending)');
    } catch (e) {
      print('❌ فشل INCREMENTAL SYNC [$kind]: $e');
      rethrow;
    }
  }

  Future<Map<String, double>> treasuryBalances(String companyCode,
      {String? branchCode, String? toDate, bool forceRefresh = false}) async {
    if (forceRefresh) {
      for (final kind in const ['sales', 'returns', 'customer-payments']) {
        try {
          await fetch(kind, companyCode, branchCode: branchCode, forceRefresh: true);
        } catch (_) {}
      }
    }
    final sales = await fetch('sales', companyCode, branchCode: branchCode);
    final returns = await fetch('returns', companyCode, branchCode: branchCode);
    final receipts = await fetch('customer-payments', companyCode, branchCode: branchCode);
    final balances = <String, double>{};
    void apply(dynamic raw, double sign, dynamic rawDate) {
      if (raw is! List) return;
      for (final payment in raw.whereType<Map>()) {
        final map = Map<String, dynamic>.from(payment);
        if (toDate != null && (rawDate?.toString() ?? '').compareTo(toDate) > 0) continue;
        final treasury = map['treasury']?.toString() ?? '';
        if (treasury.isEmpty) continue;
        balances[treasury] = (balances[treasury] ?? 0) + sign * _num(map['amount']);
      }
    }
    for (final sale in sales) { apply(sale['payments'], 1, sale['date']); }
    for (final returned in returns) { apply(returned['payments'], -1, returned['date']); }
    for (final receipt in receipts) { apply(receipt['payments'], 1, receipt['date']); }
    return balances;
  }

  static double _num(dynamic value) => value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '') ?? 0;
    // ============================================================
  // ⭐ Helper: last_sync key لكل kind
  // ============================================================
  String _lastSyncKeyFor(String kind) {
    switch (kind) {
      case 'sales':
        return ApiConstants.LAST_SYNC_SALES;
      case 'returns':
        return ApiConstants.LAST_SYNC_RETURNS;
      case 'customer-payments':
        return ApiConstants.LAST_SYNC_CUSTOMER_PAYMENTS;
      case 'transfers':
        return ApiConstants.LAST_SYNC_TRANSFERS;
      default:
        return 'last_sync_${kind}_';
    }
  }

  // ============================================================
  // ⭐ Helper: حذف سجل من Hive بالـ id (من كل المفاتيح)
  // ============================================================
  Future<void> _removeLocalById(String kind, String id) async {
    final box = Hive.box(_boxes[kind]!);
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! List) continue;
      final list = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final before = list.length;
      list.removeWhere((e) => e['id']?.toString() == id);
      if (list.length != before) {
        if (list.isEmpty) {
          await box.delete(key);
        } else {
          await box.put(key, list);
        }
      }
    }
  }

}
