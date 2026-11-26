import 'cache_partitions.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';
import 'staged_changes.dart';
import 'sync_read_access.dart';

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
  static final Set<String?> _requestedSyncCompanies = {};
  static Timer? _backgroundSyncTimer;
  static String? _backgroundSyncCompany;

  static int _backgroundCacheGeneration = -1;

  static void startBackgroundSync(String companyCode) {
    if (_backgroundCacheGeneration != CachePartitions.generation) {
      _backgroundSyncTimer?.cancel();
      _backgroundSyncTimer = null;
      _backgroundCacheGeneration = CachePartitions.generation;
    }
    _backgroundSyncCompany = companyCode;
    _backgroundSyncTimer ??= Timer.periodic(const Duration(seconds: 3600), (_) {
      final company = _backgroundSyncCompany;
      if (company != null && CachePartitions.isReady) {
        unawaited(CommercialService().syncPending(company).catchError((Object _) {}));
      }
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
    bool forceRefresh = false, // ⭐ المستخدم يضغط "تحديث"
  }) async {
return CachePartitions.run(() async {

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

      final response =
          await AuthHttp.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200)
        return _localRecords(kind, companyCode, branchCode);

      final raw = jsonDecode(response.body);
      if (raw is! List) return _localRecords(kind, companyCode, branchCode);

      final records = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      await _mergeServerRecords(kind, companyCode, records,
          branchCode: branchCode);

      return _localRecords(kind, companyCode, branchCode);
    } catch (_) {
      return _localRecords(kind, companyCode, branchCode);
    }
});
}

  // All server-read paths share one merge policy. The lock is local only;
  // network requests stay outside it, and unresolved local work always wins.
  Future<void> _mergeServerRecords(
      String kind, String companyCode, List<Map<String, dynamic>> records,
      {String? branchCode, bool snapshot = true}) async {
return CachePartitions.run(() async {

    return _queueMutation(() async {
      final box = CachePartitions.box(_boxes[kind]!);
      final queue = CachePartitions.box('commercial_pending_box');
      final queuedIds = queue.values
          .whereType<Map>()
          .where(
              (op) => op['kind'] == kind && op['company_code'] == companyCode)
          .map((op) => op['id']?.toString())
          .toSet();
      final allBranches = branchCode == null ||
          branchCode.isEmpty ||
          {'all', 'الكل', 'كل الفروع'}.contains(branchCode);
      bool inScope(Map row) =>
          row['company_code']?.toString() == companyCode &&
          (allBranches ||
              (kind == 'transfers'
                  ? row['from_branch_code']?.toString() == branchCode ||
                      row['to_branch_code']?.toString() == branchCode
                  : row['branch_code']?.toString() == branchCode));
      // Read after the GET, under the same local lock as save/delete. Keep
      // conflict rows AND deletion tombstones, not only visible pending rows.
      if (snapshot) {
        for (final key in box.keys.toList()) {
          final raw = box.get(key);
          if (raw is! List) continue;
          final kept = raw
              .whereType<Map>()
              .map((r) => Map<String, dynamic>.from(r))
              .where((row) =>
                  !inScope(row) ||
                  queuedIds.contains(row['id']?.toString()) ||
                  {'pending', 'error', 'conflict'}.contains(row['sync_status']))
              .toList();
          if (kept.isEmpty) {
            await box.delete(key);
          } else {
            await box.put(key, kept);
          }
        }
      }
      final protectedIds = box.values
          .whereType<List>()
          .expand((v) => v)
          .whereType<Map>()
          .where(inScope)
          .where((row) =>
              queuedIds.contains(row['id']?.toString()) ||
              {'pending', 'error', 'conflict'}.contains(row['sync_status']))
          .map((row) => row['id']?.toString())
          .toSet();
      for (final record in records) {
        if (!inScope(record) ||
            queuedIds.contains(record['id']?.toString()) ||
            protectedIds.contains(record['id']?.toString())) continue;
        final id = record['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        if (record['action'] == 'delete' || record['is_deleted'] == true) {
          await _removeLocalById(kind, id);
        } else {
          record['sync_status'] = 'synced';
          await _putLocal(kind, record);
        }
      }
    });
});
}

  List<Map<String, dynamic>> _localRecords(
      String kind, String companyCode, String? branchCode) {
    final box = CachePartitions.box(_boxes[kind]!);
    final allBranches = branchCode == null ||
        branchCode.isEmpty ||
        {'all', 'الكل', 'كل الفروع'}.contains(branchCode);
    return box.values
        .whereType<List>()
        .expand((v) => v)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) =>
            e['company_code']?.toString() == companyCode &&
            e['is_deleted'] != true &&
            (allBranches ||
                (kind == 'transfers'
                    ? e['from_branch_code']?.toString() == branchCode ||
                        e['to_branch_code']?.toString() == branchCode
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
// Serialize local record + queue transitions, never the network request.
// A response may only acknowledge the exact revision it sent.
  static Future<void> _queueTail = Future<void>.value();

  static Future<T> _queueMutation<T>(Future<T> Function() work) async {
return CachePartitions.run(() async {

    final previous = _queueTail;
    final done = Completer<void>();
    _queueTail = done.future;
    await previous;
    try {
      return await work();
    } finally {
      done.complete();
    }
});
}

  bool _canPush(Map op, String? companyCode) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return uid.isNotEmpty &&
        op['user_uid'] == uid &&
        op['blocked_conflict'] != true &&
        op['discarded'] != true &&
        op['revoked_hold'] != true &&
        (companyCode == null || op['company_code'] == companyCode);
  }

  Future<void> syncPending([String? companyCode]) async {
return CachePartitions.run(() async {

    if (!CachePartitions.isBoxOpen('commercial_pending_box')) return;
    if (_isPushingPending) {
      _requestedSyncCompanies.add(companyCode);
      return;
    }
    _isPushingPending = true;
    final visited = <String>{};
    try {
      // Re-scan after each response: edits/deletes created during an in-flight
      // request must run after it, without waiting for the hourly timer.
      while (true) {
        dynamic selectedKey;
        Map<String, dynamic>? selected;
        await _queueMutation(() async {
          final queue = CachePartitions.box('commercial_pending_box');
          for (final key in queue.keys.toList()) {
            final raw = queue.get(key);
            if (raw is! Map) continue;
            final op = Map<String, dynamic>.from(raw);
            if ((op['user_uid']?.toString() ?? '').isEmpty) {
              if (op['ownership_unverified'] != true) {
                op['ownership_unverified'] = true;
                await queue.put(key, op);
              }
              continue;
            }
            final token = '$key:${op['revision']}';
            if (!_canPush(op, companyCode) || visited.contains(token)) continue;
            visited.add(token);
            op['attempted'] = true;
            await queue.put(key, op); // Persist before issuing the POST.
            selectedKey = key;
            selected = op;
            break;
          }
        });
        if (selected == null) break;
        final op = selected!;
        final key = selectedKey;
        final deleting = op['action'] == 'delete';
        final kind = op['kind'].toString();
        final data = deleting
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(op['data'] as Map);
        if (data['provisional_serial'] == true) data['serial'] = 0;
        try {
          final response = deleting
              ? await AuthHttp.post(
                      Uri.parse('$_baseUrl/commercial/$kind/delete/'
                          '${op['company_code']}/${op['id']}'))
                  .timeout(const Duration(seconds: 10))
              : await AuthHttp.post(
                      Uri.parse('$_baseUrl/commercial/$kind/save'),
                      headers: {'Content-Type': 'application/json'},
                      body: jsonEncode(data))
                  .timeout(const Duration(seconds: 10));
          await _queueMutation(() async {
            final queue = CachePartitions.box('commercial_pending_box');
            final raw = queue.get(key);
            if (raw is! Map) return;
            final current = Map<String, dynamic>.from(raw);
            final sameRevision = current['revision'] == op['revision'];
            // A hold/revocation/ownership change made while awaiting the server
            // remains authoritative. Do not clear it or replace its data.
            if (!_canPush(current, companyCode)) return;
            if (deleting &&
                (response.statusCode == 200 || response.statusCode == 404)) {
              if (sameRevision) await queue.delete(key);
              return;
            }
            if (!deleting && response.statusCode == 200) {
              final result =
                  Map<String, dynamic>.from(jsonDecode(response.body));
              if (sameRevision) {
                data['serial'] = result['serial'] ?? data['serial'] ?? 0;
                if (result['updated_at'] != null)
                  data['updated_at'] = result['updated_at'];
                data.remove('provisional_serial');
                data['sync_status'] = 'synced';
                data.remove('last_error');
                await _putLocal(kind, data);
                await queue.delete(key);
              } else if (current['action'] == 'save') {
                // Only metadata advances. Never replace the user's newer values
                // with the payload from the older POST.
                final next = Map<String, dynamic>.from(current['data'] as Map);
                if (result['updated_at'] != null) {
                  next['base_updated_at'] = result['updated_at'];
                }
                if (result['serial'] != null) next['serial'] = result['serial'];
                next.remove('provisional_serial');
                current['data'] = next;
                current['attempted'] = true;
                await queue.put(key, current);
                final local =
                    _localRecords(kind, op['company_code'].toString(), null)
                        .where((r) => r['id'] == op['id'])
                        .firstOrNull;
                if (local != null) {
                  if (result['serial'] != null)
                    local['serial'] = result['serial'];
                  if (result['updated_at'] != null) {
                    local['base_updated_at'] = result['updated_at'];
                  }
                  local.remove('provisional_serial');
                  await _putLocal(kind, local);
                }
              }
              // A newer delete stays queued; it must follow this committed save.
            } else if (sameRevision) {
              await _updateLocalSyncStatus(
                  kind,
                  op['id'].toString(),
                  response.statusCode == 409 ? 'conflict' : 'error',
                  'HTTP ${response.statusCode}: ${response.body}');
              if (response.statusCode == 409) {
                current['blocked_conflict'] = true;
                await queue.put(key, current);
              }
            }
          });
        } catch (e) {
          // The original queue remains durable. Do not turn a rejected stale
          // acknowledgement into another mutation in the next session.
          if (!CachePartitions.boundWorkIsCurrent) return;
          await _queueMutation(() async {
            final raw = CachePartitions.box('commercial_pending_box').get(key);
            if (raw is Map &&
                raw['revision'] == op['revision'] &&
                _canPush(raw, companyCode)) {
              await _updateLocalSyncStatus(
                  kind, op['id'].toString(), 'error', e.toString());
            }
          });
        }
      }
    } finally {
      _isPushingPending = false;
      if (!CachePartitions.boundWorkIsCurrent) {
        _requestedSyncCompanies.clear();
      } else if (_requestedSyncCompanies.isNotEmpty) {
        final next = _requestedSyncCompanies.first;
        _requestedSyncCompanies.remove(next);
        unawaited(syncPending(next));
      }
    }
});
}

  Future<Map<String, dynamic>> save(
      String kind, Map<String, dynamic> data) async {
return CachePartitions.run(() async {

    late Map<String, dynamic> result;
    await _queueMutation(() async {
      final queue = CachePartitions.box('commercial_pending_box');
      final key = '$kind:${data['id']}';
      final previous = queue.get(key);
      final serverData = Map<String, dynamic>.from(data);
      // An unsent edit's base is the last known SERVER version, not the local
      // timestamp placed on the record by an earlier pending edit.
      if (previous is Map &&
          previous['action'] == 'save' &&
          previous['data'] is Map) {
        final oldData = previous['data'] as Map;
        if (oldData.containsKey('base_updated_at')) {
          serverData['base_updated_at'] = oldData['base_updated_at'];
        } else {
          serverData.remove('base_updated_at');
        }
      }
      final branch =
          (data['branch_code'] ?? data['from_branch_code'] ?? '').toString();
      final isNew =
          (int.tryParse(data['serial']?.toString() ?? '0') ?? 0) <= 0 ||
              data['provisional_serial'] == true;
      if (isNew) {
        if (data['provisional_serial'] != true) {
          data['serial'] =
              _nextLocalSerial(kind, data['company_code'].toString(), branch);
        }
        data['provisional_serial'] = true;
        serverData['serial'] = 0;
        serverData['provisional_serial'] = true;
      }
      data['updated_at'] = DateTime.now().toUtc().toIso8601String();
      data['is_deleted'] = false;
      data['sync_status'] = 'pending';
      await _putLocal(kind, data);
      await queue.put(key, {
        'kind': kind,
        'action': 'save',
        'id': data['id'],
        'company_code': data['company_code'],
        'user_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'revision': newId(),
        'attempted': previous is Map && previous['attempted'] == true,
        'blocked_conflict': false,
        'data': serverData
      });
      result = {
        'status': 'success',
        'serial': data['serial'] ?? 0,
        'pending_sync': true
      };
    });
    unawaited(syncPending(data['company_code']?.toString()));
    return result;
});
}

  Future<void> delete(String kind, String companyCode, String id) async {
return CachePartitions.run(() async {

    await _queueMutation(() async {
      final box = CachePartitions.box(_boxes[kind]!);
      await CachePartitions.box('commercial_stock_events_box')
          .delete('${companyCode}_synced_at');
      for (final key in box.keys.toList()) {
        final values = box.get(key);
        if (values is! List) continue;
        final list = values
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        for (final item in list.where((e) => e['id']?.toString() == id)) {
          item['is_deleted'] = true;
        }
        await box.put(key, list);
      }
      // Even a legacy attempted=false entry may have reached the server.
      // A delete is idempotent (200/404); retain it until acknowledged.
      await CachePartitions.box('commercial_pending_box').put('$kind:$id', {
        'kind': kind,
        'action': 'delete',
        'id': id,
        'company_code': companyCode,
        'user_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'revision': newId(),
        'attempted': false
      });
    });
    unawaited(syncPending(companyCode));
});
}

  Future<void> _updateLocalSyncStatus(
      String kind, String id, String status, String error) async {
return CachePartitions.run(() async {

    final box = CachePartitions.box(_boxes[kind]!);
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! List) continue;
      final list = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      var changed = false;
      for (final item in list.where((e) => e['id']?.toString() == id)) {
        item['sync_status'] = status;
        item['last_error'] = error;
        changed = true;
      }
      if (changed) await box.put(key, list);
    }
});
}

  Future<void> _putLocal(String kind, Map<String, dynamic> data) async {
return CachePartitions.run(() async {

    final box = CachePartitions.box(_boxes[kind]!);
    await CachePartitions.box('commercial_stock_events_box')
        .delete('${data['company_code']}_synced_at');
    for (final oldKey in box.keys.toList()) {
      final oldValue = box.get(oldKey);
      if (oldValue is! List) continue;
      final oldList = oldValue
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      oldList.removeWhere((e) => e['id']?.toString() == data['id']?.toString());
      if (oldList.length != oldValue.length) {
        if (oldList.isEmpty) {
          await box.delete(oldKey);
        } else {
          await box.put(oldKey, oldList);
        }
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
        ? existing
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    list.removeWhere((e) => e['id']?.toString() == data['id']?.toString());
    list.add(Map<String, dynamic>.from(data));
    await box.put(key, list);
});
}

  Future<void> refreshStockEvents(String companyCode) async {
return CachePartitions.run(() async {

    final box = CachePartitions.box('commercial_stock_events_box');
    final syncedAt = DateTime.tryParse(
        box.get('${companyCode}_synced_at')?.toString() ?? '');
    if (syncedAt != null && DateTime.now().difference(syncedAt).inSeconds < 30)
      return;
    try {
      final response = await AuthHttp.get(
              Uri.parse('$_baseUrl/commercial/stock-events/$companyCode'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) throw Exception(response.body);
      final raw = jsonDecode(response.body);
      final events = raw is List
          ? raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      await box.put(companyCode, events);
      await box.put(
          '${companyCode}_synced_at', DateTime.now().toIso8601String());
    } catch (_) {
      // Preserve the last good snapshot for offline stock views.
    }
});
}

  Future<double> customerBalance(String companyCode, String customerCode,
      {String? branchCode}) async {
return CachePartitions.run(() async {

    final sales = await fetch('sales', companyCode, branchCode: branchCode);
    final returns = await fetch('returns', companyCode, branchCode: branchCode);
    final receipts =
        await fetch('customer-payments', companyCode, branchCode: branchCode);
    var balance = 0.0;
    for (final sale
        in sales.where((e) => e['customer_code']?.toString() == customerCode)) {
      balance += _num(sale['due']);
    }
    for (final receipt in receipts
        .where((e) => e['customer_code']?.toString() == customerCode)) {
      balance -= _num(receipt['amount']);
    }
    for (final returned in returns
        .where((e) => e['customer_code']?.toString() == customerCode)) {
      // Returns first offset the customer's open balance; any refund over that
      // amount is paid out from the selected treasury and does not create debt.
      balance -= _num(returned['credit_amount'] ?? returned['total']);
    }
    return max(0, balance).toDouble();
});
}

  Future<List<Map<String, dynamic>>> customerBalances(
    String companyCode, {
    String? branchCode,
    String? toDate,
    bool forceRefresh = false,
  }) async {
return CachePartitions.run(() async {

    if (forceRefresh) {
      for (final kind in const ['sales', 'returns', 'customer-payments']) {
        try {
          await fetch(kind, companyCode,
              branchCode: branchCode, forceRefresh: true);
        } catch (_) {}
      }
    }
    final sales = _localRecords('sales', companyCode, branchCode);
    final returns = _localRecords('returns', companyCode, branchCode);
    final receipts =
        _localRecords('customer-payments', companyCode, branchCode);
    final balances = <String, Map<String, dynamic>>{};
    bool withinDate(Map<String, dynamic> record) =>
        toDate == null ||
        (record['date']?.toString() ?? '').compareTo(toDate) <= 0;
    Map<String, dynamic> entry(String code, String name) =>
        balances.putIfAbsent(
            code,
            () => {
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
});
}

  Future<Map<String, dynamic>> returnableSale(
    String companyCode,
    String saleId, {
    String? toDate,
    String? excludeReturnId,
    bool forceRefresh = false,
  }) async {
return CachePartitions.run(() async {

    final query = <String, String>{};
    if (toDate != null) query['to_date'] = toDate;
    if (excludeReturnId != null) query['exclude_return_id'] = excludeReturnId;
    final uri =
        Uri.parse('$_baseUrl/commercial/returnable/$companyCode/$saleId')
            .replace(
      queryParameters: query.isEmpty ? null : query,
    );
    if (forceRefresh) {
      try {
        final response =
            await AuthHttp.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode == 200)
          return Map<String, dynamic>.from(jsonDecode(response.body));
      } catch (_) {}
    }

    final sales = _localRecords('sales', companyCode, null);
    final sale = sales.firstWhere((e) => e['id']?.toString() == saleId,
        orElse: () => <String, dynamic>{});
    if (sale.isEmpty) throw Exception('فاتورة البيع غير متاحة على هذا الجهاز');
    final returned = _localRecords('returns', companyCode, null).where((e) =>
        e['sale_id']?.toString() == saleId &&
        e['id']?.toString() != excludeReturnId &&
        (toDate == null ||
            (e['date']?.toString() ?? '').compareTo(toDate) <= 0));
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
        remaining[code] =
            max(0, _num(item['quantity']) - (quantities[code] ?? 0)).toDouble();
      }
    }
    return {
      'remaining_quantities': remaining,
      'customer_balance': await customerBalance(
          companyCode, sale['customer_code']?.toString() ?? '',
          branchCode: sale['branch_code']?.toString()),
    };
});
}

  // ============================================================
  // ⭐ FULL SYNC — أول مرة (last_sync = null)
  // ============================================================
  Future<void> fetchAll(String kind, String companyCode) async {
return CachePartitions.run(() async {

    print('📥 [Commercial/$kind] بدء FULL SYNC...');

    try {
      final v2Candidate = await _captureV2(kind, companyCode);
      final uri = Uri.parse('$_baseUrl/commercial/$kind/list/$companyCode');
      final response =
          await AuthHttp.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('فشل تحميل $kind. HTTP ${response.statusCode}');
      }

      final raw = jsonDecode(response.body);
      if (raw is! List) throw Exception('بيانات غير صالحة');

      final records = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      await _mergeServerRecords(kind, companyCode, records);
      await _commitV2(kind, companyCode, v2Candidate);
      print('FULL SYNC [$kind]: ${records.length} server records merged');
    } catch (e) {
      print('❌ فشل FULL SYNC [$kind]: $e');
      rethrow;
    }
});
}

  // ============================================================
  // ⭐ INCREMENTAL SYNC — last_sync موجود
  // ============================================================
  Future<void> syncChangesFromServer(
    String kind,
    String companyCode, [
    String? lastSync,
  ]) async {
return CachePartitions.run(() async {

    final prefs = await CachePartitions.preferences();
    final lastSyncKey = '${_lastSyncKeyFor(kind)}$companyCode';
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    // مفيش last_sync → Full sync
    if (lastSyncValue == null || lastSyncValue.isEmpty) {
      print('📥 [$kind] لا يوجد lastSync → FULL SYNC');
      final syncStartedAt = DateTime.now().toUtc();
      await fetchAll(kind, companyCode);
      await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
      return;
    }

    print('📡 [$kind] INCREMENTAL SYNC منذ $lastSyncValue');

    try {
      final v2Candidate = await _captureV2(kind, companyCode);
      final storedEpoch = prefs.getString(v2EpochKey(kind, companyCode));
      if (v2Candidate != null && storedEpoch != null && storedEpoch != v2Candidate.epoch) {
        print('📥 [$kind] feed epoch changed → FULL SYNC');
        final startedAt = DateTime.now().toUtc();
        await fetchAll(kind, companyCode);
        await prefs.setString(lastSyncKey, startedAt.toIso8601String());
        return;
      }
      final syncStartedAt = DateTime.now().toUtc();
      final sinceDt = DateTime.parse(lastSyncValue).toUtc();
      final effectiveSince = sinceDt.toIso8601String();

      final uri = Uri.parse('$_baseUrl/commercial/$kind/changes/$companyCode')
          .replace(queryParameters: {'since': effectiveSince});

      final response =
          await AuthHttp.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('فشل مزامنة $kind. HTTP ${response.statusCode}');
      }

      final raw = jsonDecode(response.body);
      if (raw is! List) throw Exception('بيانات غير صالحة');

      final changes = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      if (changes.isEmpty) {
        print('⏭️ [$kind] لا يوجد تغييرات');
        await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
        await _commitV2(kind, companyCode, v2Candidate);
        return;
      }

      await _mergeServerRecords(kind, companyCode, changes, snapshot: false);

      // ⭐ حفظ last_sync بعد النجاح
      await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
      await _commitV2(kind, companyCode, v2Candidate);

      print(
          'INCREMENTAL SYNC [$kind]: ${changes.length} server changes merged');
    } catch (e) {
      print('❌ فشل INCREMENTAL SYNC [$kind]: $e');
      rethrow;
    }
});
}

  Future<Map<String, double>> treasuryBalances(String companyCode,
      {String? branchCode, String? toDate, bool forceRefresh = false}) async {
return CachePartitions.run(() async {

    if (forceRefresh) {
      for (final kind in const ['sales', 'returns', 'customer-payments']) {
        try {
          await fetch(kind, companyCode,
              branchCode: branchCode, forceRefresh: true);
        } catch (_) {}
      }
    }
    final sales = await fetch('sales', companyCode, branchCode: branchCode);
    final returns = await fetch('returns', companyCode, branchCode: branchCode);
    final receipts =
        await fetch('customer-payments', companyCode, branchCode: branchCode);
    final balances = <String, double>{};
    void apply(dynamic raw, double sign, dynamic rawDate) {
      if (raw is! List) return;
      for (final payment in raw.whereType<Map>()) {
        final map = Map<String, dynamic>.from(payment);
        if (toDate != null && (rawDate?.toString() ?? '').compareTo(toDate) > 0)
          continue;
        final treasury = map['treasury']?.toString() ?? '';
        if (treasury.isEmpty) continue;
        balances[treasury] =
            (balances[treasury] ?? 0) + sign * _num(map['amount']);
      }
    }

    for (final sale in sales) {
      apply(sale['payments'], 1, sale['date']);
    }
    for (final returned in returns) {
      apply(returned['payments'], -1, returned['date']);
    }
    for (final receipt in receipts) {
      apply(receipt['payments'], 1, receipt['date']);
    }
    return balances;
});
}

  static double _num(dynamic value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;
  // ============================================================
  // EXPERIMENT: commit-safe staged feed (migration 007, /commercial/{kind}/changes-v2)
  // ============================================================
  static void Function(String kind, String company)? onCheckpointChanged;
  static const _v2Sections = {
    'sales': 'sales',
    'returns': 'returns',
    'customer-payments': 'customer-payments',
    'transfers': 'transfers',
  };
  static String v2CursorKey(String kind, String c) => '${_staticLastSyncKey(kind)}${c}_v2';
  static String v2ScopeKey(String kind, String c) => '${_staticLastSyncKey(kind)}${c}_v2scope';
  static String v2EpochKey(String kind, String c) => '${_staticLastSyncKey(kind)}${c}_v2epoch';
  static String _staticLastSyncKey(String kind) {
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

  Future<({String cursor, String scope, String epoch})?> _captureV2(String kind, String company) async {
    try {
      final r = await AuthHttp.get(Uri.parse('$_baseUrl/commercial/$kind/changes-v2/$company?cursor=latest'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body);
      if (m is! Map ||
          m['invalid'] == true ||
          m['next_cursor'] is! String ||
          m['scope'] is! String ||
          (m['scope'] as String).isEmpty) return null;
      return (cursor: m['next_cursor'] as String, scope: m['scope'] as String, epoch: (m['epoch'] ?? '').toString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _commitV2(String kind, String company, ({String cursor, String scope, String epoch})? cand) async {
    if (cand == null) return;
    try {
      final prefs = await CachePartitions.preferences();
      await prefs.setString(v2CursorKey(kind, company), cand.cursor);
      await prefs.setString(v2ScopeKey(kind, company), cand.scope);
      await prefs.setString(v2EpochKey(kind, company), cand.epoch);
      try {
        onCheckpointChanged?.call(kind, company);
      } catch (_) {}
    } catch (_) {}
  }

  Future<({String cursor, String scope})?> stagedCheckpoint(String kind, String company) async {
    try {
      if (!SyncReadAccess.allows(_v2Sections[kind] ?? kind)) return null;
      final prefs = await CachePartitions.preferences();
      final c = prefs.getString(v2CursorKey(kind, company));
      final s = prefs.getString(v2ScopeKey(kind, company));
      if (c == null || s == null || s.isEmpty) return null;
      return (cursor: c, scope: s);
    } catch (_) {
      return null;
    }
  }

  /// Applies one changes-v2 response fetched by the service worker while the app was closed.
  /// Only when it continues exactly from the stored cursor and scope, under the read right held
  /// NOW. Rows queued or pending locally stay protected by _mergeServerRecords. Returns true when applied.
  Future<bool> applyStagedBatch(String kind, String company, dynamic decoded,
      {required String fromCursor, required String fromScope}) async {
    final section = _v2Sections[kind];
    if (section == null) return false;
    try {
      return await CachePartitions.run(() async {
        final epoch = ReadAuthorizationEpoch.value;
        if (!SyncReadAccess.allows(section)) return false;
        final prefs = await CachePartitions.preferences();
        if (prefs.getString(v2CursorKey(kind, company)) != fromCursor ||
            prefs.getString(v2ScopeKey(kind, company)) != fromScope) return false;
        if (decoded is! Map ||
            decoded['invalid'] == true ||
            decoded['scope'] != fromScope ||
            decoded['next_cursor'] is! String ||
            (decoded['next_cursor'] as String).isEmpty ||
            decoded['items'] is! List) return false;
        final box = CachePartitions.box(_boxes[kind]!);
        final localStamp = <String, DateTime?>{};
        for (final key in box.keys) {
          final raw = box.get(key);
          if (raw is! List) continue;
          for (final v in raw) {
            if (v is Map) localStamp[v['id']?.toString() ?? ''] = StagedChanges.stamp(v['updated_at']);
          }
        }
        final scopeBefore = PermissionsService().effectiveScopeSignature();
        final fresh = <Map<String, dynamic>>[];
        for (final raw in decoded['items'] as List) {
          if (raw is! Map) return false;
          final m = Map<String, dynamic>.from(raw.map((k, x) => MapEntry(k.toString(), x)));
          if (m['company_code']?.toString() != company) return false;
          final id = m['id']?.toString() ?? '';
          if (id.isEmpty) return false;
          final l = localStamp[id];
          final i = StagedChanges.stamp(m['updated_at']);
          if (l != null && i != null && l.isAfter(i)) continue;
          m.remove('tombstone');
          fresh.add(m);
        }
        if (fresh.isNotEmpty) {
          if (!SyncReadAccess.allows(section) || epoch != ReadAuthorizationEpoch.value) return false;
          await _mergeServerRecords(kind, company, fresh, snapshot: false);
        }
        if (!SyncReadAccess.allows(section) ||
            PermissionsService().effectiveScopeSignature() != scopeBefore) {
          // Scope (rights, branches, role, policy) moved while writing: take back this batch's synced rows.
          for (final m in fresh) {
            if (m['action'] == 'delete' || m['is_deleted'] == true) continue;
            final id = m['id'].toString();
            final cur = _localRecordById(kind, id);
            if (cur != null && cur['sync_status'] == 'synced') await _removeLocalById(kind, id);
          }
          return false;
        }
        await prefs.setString(v2CursorKey(kind, company), decoded['next_cursor'] as String);
        try {
          onCheckpointChanged?.call(kind, company);
        } catch (_) {}
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic>? _localRecordById(String kind, String id) {
    final box = CachePartitions.box(_boxes[kind]!);
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! List) continue;
      for (final v in raw) {
        if (v is Map && v['id']?.toString() == id) return Map<String, dynamic>.from(v);
      }
    }
    return null;
  }

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
return CachePartitions.run(() async {

    final box = CachePartitions.box(_boxes[kind]!);
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
});
}
}
