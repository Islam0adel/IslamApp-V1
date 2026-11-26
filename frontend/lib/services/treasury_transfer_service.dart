import 'cache_partitions.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';

class TreasuryTransferFailure implements Exception {
  final int statusCode;
  const TreasuryTransferFailure(this.statusCode);
  bool get uncertain => statusCode >= 500 || statusCode == 408;
  @override
  String toString() {
    if (statusCode == 403) return 'ليس لديك صلاحية لهذه العملية.';
    if (statusCode == 409)
      return 'تغيّر التحويل أو إصدار البيانات. حدّث السجل قبل المحاولة.';
    if (statusCode == 404) return 'التحويل غير موجود أو تم حذفه. حدّث السجل.';
    if (statusCode == 400 || statusCode == 422)
      return 'رفض الحفظ. راجع المبلغ والخزينتين والفرع.';
    return 'لم يتم تأكيد الحفظ ($statusCode)';
  }
}

/// Foreground, server-confirmed transfers. This is not an offline queue.
class TreasuryTransferService {
  static const recordsBox = 'treasury_transfers_box';
  static const effectsBox = 'treasury_effects_box';
  static final Map<String, Future<void>> _reads = {};
  PermissionsService get _permissions => PermissionsService();
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  String _key(String uid, String company) => jsonEncode([uid, company]);
  String get _base => '${ApiConstants.baseUrl}/treasury-transfers';

  String newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  bool _allowed(String box) => box == recordsBox
      ? _permissions.canViewTreasuryTransfers
      : _permissions.canReadTreasuryEffects;

  List<Map<String, dynamic>> _scoped(dynamic value, String company) {
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .where((row) =>
            row['company_code'] == company &&
            row['is_deleted'] != true &&
            _permissions.canAccessBranch(row['branch_code']?.toString() ?? ''))
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  List<Map<String, dynamic>> _local(String boxName, String company) {
    final uid = _uid;
    if (uid == null ||
        !_allowed(boxName) ||
        !CachePartitions.isBoxOpen(boxName)) return [];
    final envelope = CachePartitions.box(boxName).get(_key(uid, company));
    if (envelope is! Map ||
        envelope['owner_uid'] != uid ||
        envelope['company_code'] != company) return [];
    return _scoped(envelope['records'], company);
  }

  String _readScope(String box) {
    final branches = List<String>.from(_permissions.allowedBranches ?? [])
      ..sort();
    return jsonEncode([_allowed(box), branches]);
  }

  /// Empty verified snapshots are data too, not a reason to fetch on every open.
  bool hasSnapshot(String box, String company) {
    final uid = _uid;
    if (uid == null || !_allowed(box) || !CachePartitions.isBoxOpen(box))
      return false;
    final value = CachePartitions.box(box).get(_key(uid, company));
    return value is Map &&
        (box != recordsBox || value['protocol'] == 2) &&
        value['owner_uid'] == uid &&
        value['company_code'] == company &&
        value['records'] is List &&
        value['read_scope'] == _readScope(box);
  }

  Future<void> ensureCached(String company) async {
    return CachePartitions.run(() async {
      await Future.wait([
        if (_allowed(recordsBox) && !hasSnapshot(recordsBox, company))
          refreshRecords(company),
        if (_allowed(effectsBox) && !hasSnapshot(effectsBox, company))
          refreshEffects(company),
      ]);
    });
  }

  List<Map<String, dynamic>> localRecords(String company,
      {String? branchCode}) {
    final records = _local(recordsBox, company)
        .where((r) => _branchMatches(branchCode, r['branch_code']))
        .toList();
    records.sort((a, b) => (b['serial'] as num).compareTo(a['serial'] as num));
    return records;
  }

  bool _branchMatches(String? filter, dynamic value) =>
      filter == null ||
      {'', 'all', 'الكل', 'كل الفروع'}.contains(filter) ||
      value?.toString() == filter;

  /// Minimal signed effects only. They must not enter gross receipts/payments.
  Map<String, double> balanceEffects(String company,
      {String? branchCode, DateTime? fromDate, DateTime? toDate}) {
    final result = <String, double>{};
    String day(DateTime date) => date.toIso8601String().substring(0, 10);
    for (final row in _local(effectsBox, company)) {
      if (!_branchMatches(branchCode, row['branch_code'])) continue;
      final date = row['date']?.toString() ?? '';
      if (fromDate != null && date.compareTo(day(fromDate)) < 0) continue;
      if (toDate != null && date.compareTo(day(toDate)) > 0) continue;
      final treasury = row['treasury']?.toString() ?? '';
      final amount =
          double.tryParse(row['signed_amount']?.toString() ?? '') ?? 0;
      if (treasury.isNotEmpty && amount.isFinite)
        result[treasury] = (result[treasury] ?? 0) + amount;
    }
    return result;
  }

  Map<String, dynamic> _projectEntry(Map raw, String box) =>
      Map<String, dynamic>.from(raw);

  List<Map<String, dynamic>> _records(
          List<Map<String, dynamic>> entries, String box, String company) =>
      entries.where((e) => e['is_deleted'] != true).toList();

  static Future<void> _eventTail = Future<void>.value();
  Future<void> applyEvent(Map<String, dynamic> raw, {required bool effects}) {
    final receivedUid = _uid;
    final receivedEpoch = ReadAuthorizationEpoch.value;
    final work = _eventTail.then((_) => CachePartitions.run(() async {
          if (_uid != receivedUid ||
              ReadAuthorizationEpoch.value != receivedEpoch) return;
          final boxName = effects ? effectsBox : recordsBox;
          if (effects) {
            await _refresh(effectsBox, raw['company_code']?.toString() ?? '');
            return;
          }
          final company = raw['company_code']?.toString() ?? '';
          final uid = _uid;
          if (uid == null ||
              !_allowed(boxName) ||
              !CachePartitions.isBoxOpen(boxName)) return;
          final box = CachePartitions.box(boxName);
          final key = _key(uid, company);
          final old = box.get(key);
          if (old is! Map ||
              old['protocol'] != 2 ||
              old['read_scope'] != _readScope(boxName)) {
            await _refresh(boxName, company);
            return;
          }
          if (raw['revision'] is! int ||
              raw['id'] is! String ||
              !_permissions.canAccessBranch(
                  raw['branch_code']?.toString() ?? '')) return;
          final entries = <String, Map<String, dynamic>>{
            for (final value in (old['entries'] as List))
              value['id'].toString(): Map<String, dynamic>.from(value)
          };
          final previous = entries[raw['id']];
          if (previous != null &&
              (previous['revision'] as int) >= (raw['revision'] as int)) return;
          entries[raw['id']] = _projectEntry(raw, boxName);
          await box.put(key, {
            ...Map<String, dynamic>.from(old),
            'entries': entries.values.toList(),
            'records': _records(entries.values.toList(), boxName, company)
          });
        }));
    _eventTail = work.catchError((Object _) {});
    return work;
  }

  Future<List<Map<String, dynamic>>> _refresh(
      String boxName, String company) async {
    return CachePartitions.run(() async {
      final epoch = ReadAuthorizationEpoch.value;
      final readScope = _readScope(boxName);
      final uid = _uid;
      if (uid == null) throw StateError('يلزم تسجيل الدخول');
      if (!CachePartitions.isBoxOpen(boxName))
        await CachePartitions.openBox(boxName);
      final box = CachePartitions.box(boxName);
      final key = _key(uid, company);
      if (!_allowed(boxName)) {
        await box.delete(key);
        return [];
      }
      // Serialize reads of this exact snapshot, including the network portion.
      final lockKey = '$boxName:$key';
      final previous = _reads[lockKey] ?? Future<void>.value();
      final completer = Completer<List<Map<String, dynamic>>>();
      final work = previous.then((_) async {
        try {
          if (_uid != uid || !_allowed(boxName)) {
            await box.delete(key);
            completer.complete([]);
            return;
          }
          final old = box.get(key);
          final valid = old is Map &&
              old['protocol'] == 2 &&
              old['read_scope'] == readScope &&
              old['owner_uid'] == uid &&
              old['company_code'] == company;
          final mode = boxName == recordsBox ? 'records' : 'effects';
          final uri = boxName == effectsBox
              ? Uri.parse('$_base/effects/$company')
              : Uri.parse('$_base/changes/$mode/$company')
                  .replace(queryParameters: {
                  'cursor': valid ? (old['cursor'] ?? 0).toString() : '0',
                  'scope': valid ? (old['server_scope'] ?? '').toString() : '',
                });
          final response =
              await AuthHttp.get(uri).timeout(const Duration(seconds: 20));
          if (response.statusCode != 200) {
            if (response.statusCode == 403) await box.delete(key);
            throw StateError(
                'تعذر تحديث بيانات تحويلات الخزائن (${response.statusCode})');
          }
          final decoded = jsonDecode(response.body);
          if (_uid != uid || !_allowed(boxName)) {
            await box.delete(key);
            completer.complete([]);
            return;
          }
          if (epoch != ReadAuthorizationEpoch.value ||
              readScope != _readScope(boxName)) {
            throw const ReadAuthorizationChanged();
          }
          if (boxName == effectsBox) {
            if (decoded is! List)
              throw const FormatException('استجابة تحويلات غير صالحة');
            // Preserve the original server aggregate, row order and five-field
            // projection. No per-transfer client re-summing or new rounding.
            final records = _scoped(decoded, company)
                .map((row) => <String, dynamic>{
                      for (final field in [
                        'company_code',
                        'branch_code',
                        'date',
                        'treasury',
                        'signed_amount'
                      ])
                        field: row[field],
                    })
                .toList();
            await box.put(key, {
              'owner_uid': uid,
              'company_code': company,
              'records': records,
              'read_scope': readScope
            });
            completer.complete(records);
            return;
          }
          final records = await _applyRecordsResponse(
            decoded: decoded,
            old: old,
            valid: valid,
            box: box,
            key: key,
            uid: uid,
            company: company,
            readScope: readScope,
            boxName: boxName,
            mode: mode,
          );
          completer.complete(records);
        } catch (error, stack) {
          completer.completeError(error, stack);
        }
      });
      _reads[lockKey] = work;
      unawaited(work.whenComplete(() {
        if (identical(_reads[lockKey], work)) _reads.remove(lockKey);
      }));
      return completer.future;
    });
  }

  /// Set by StagedInbox so the worker learns the new treasury checkpoint after each applied
  /// response (live or staged). Failures never affect the refresh.
  static void Function(String company)? onCheckpointChanged;

  /// Validates a /changes/records response against the stored envelope and writes the merged
  /// result. Used by the live refresh and (later) by staged responses, so both go through the same
  /// protocol, scope, cursor and per-ID revision rules. Moved out of _refresh unchanged.
  Future<List<Map<String, dynamic>>> _applyRecordsResponse({
    required dynamic decoded,
    required dynamic old,
    required bool valid,
    required dynamic box,
    required dynamic key,
    required String uid,
    required String company,
    required dynamic readScope,
    required String boxName,
    required String mode,
  }) async {
    if (decoded is! Map ||
        decoded['protocol'] != 2 ||
        decoded['mode'] != mode ||
        decoded['company_code'] != company ||
        decoded['cursor'] is! int ||
        decoded['scope'] is! String ||
        decoded['reset'] is! bool ||
        decoded['items'] is! List ||
        decoded['cursor'] < 0 ||
        (decoded['scope'] as String).isEmpty ||
        (valid &&
            decoded['reset'] != true &&
            (decoded['scope'] != old['server_scope'] ||
                decoded['cursor'] < old['cursor']))) {
      throw const FormatException('استجابة مزامنة تحويلات غير صالحة');
    }
    final current = box.get(key);
    // A socket may have updated rows during this HTTP request. Merge its
    // newer per-ID revisions, but never advance the contiguous HTTP cursor
    // from a socket event alone.
    final entries = <String, Map<String, dynamic>>{};
    if (decoded['reset'] != true && valid && current is Map) {
      for (final raw in (current['entries'] as List? ?? [])) {
        if (raw is Map)
          entries[raw['id'].toString()] = Map<String, dynamic>.from(raw);
      }
    }
    for (final raw in decoded['items'] as List) {
      if (raw is! Map ||
          raw['id'] is! String ||
          raw['revision'] is! int ||
          raw['company_code'] != company ||
          raw['branch_code'] is! String ||
          raw['is_deleted'] is! bool ||
          raw['revision'] <= 0 ||
          raw['revision'] > decoded['cursor'])
        throw const FormatException('Invalid treasury entry');
      if (!_permissions.canAccessBranch(raw['branch_code'])) continue;
      final row = _projectEntry(raw, boxName);
      final previous = entries[row['id']];
      if (previous == null ||
          (previous['revision'] as int) <= (row['revision'] as int)) {
        entries[row['id']] = row;
      }
    }
    if (current is Map &&
        current['protocol'] == 2 &&
        current['read_scope'] == readScope &&
        current['server_scope'] == decoded['scope']) {
      for (final raw in (current['entries'] as List? ?? [])) {
        if (raw is Map &&
            raw['revision'] is int &&
            raw['revision'] > decoded['cursor']) {
          // On server reset, preserve only an event that actually arrived
          // during this request, not old ahead-of-server restored data.
          final before =
              old is Map ? (old['entries'] as List? ?? []) : [];
          final wasPresent = before.whereType<Map>().any((e) =>
              e['id'] == raw['id'] && e['revision'] == raw['revision']);
          if (decoded['reset'] == true && wasPresent) continue;
          entries[raw['id'].toString()] = Map<String, dynamic>.from(raw);
        }
      }
    }
    final records = _records(entries.values.toList(), boxName, company);
    await box.put(key, {
      'protocol': 2,
      'owner_uid': uid,
      'company_code': company,
      'entries': entries.values.toList(),
      'records': records,
      'read_scope': readScope,
      'cursor': decoded['cursor'],
      'server_scope': decoded['scope']
    });
    try { onCheckpointChanged?.call(company); } catch (_) {}
    return records;
  }

  /// Cursor and server scope of this owner's current valid records snapshot, for the worker to
  /// continue from. Null when there is no valid snapshot or read access is not held now.
  ({int cursor, String scope})? stagedCheckpoint(String company) {
    try {
      final uid = _uid;
      if (uid == null || !_allowed(recordsBox) || !CachePartitions.isBoxOpen(recordsBox)) return null;
      final old = CachePartitions.box(recordsBox).get(_key(uid, company));
      if (old is Map &&
          old['protocol'] == 2 &&
          old['read_scope'] == _readScope(recordsBox) &&
          old['owner_uid'] == uid &&
          old['company_code'] == company &&
          old['cursor'] is int &&
          (old['server_scope'] ?? '').toString().isNotEmpty) {
        return (cursor: old['cursor'] as int, scope: old['server_scope'].toString());
      }
    } catch (_) {}
    return null;
  }

  /// Applies a /changes/records response that the service worker fetched while the app was
  /// closed. Same validation as the live refresh (_applyRecordsResponse), run against the CURRENT
  /// permission, owner and read scope, not the ones at staging time. The response is applied
  /// only when it continues exactly from the stored cursor and server scope (the cursor-in the
  /// worker used); otherwise it is dropped and the normal refresh covers the gap.
  /// Returns true when applied. Throws nothing for stale or unusable input.
  Future<bool> applyStagedRecords(String company, dynamic decoded,
      {required int fromCursor, required String fromScope}) async {
    try {
      return await CachePartitions.run(() async {
        final epoch = ReadAuthorizationEpoch.value;
        final readScope = _readScope(recordsBox);
        final uid = _uid;
        if (uid == null) return false;
        if (!_allowed(recordsBox)) {
          if (CachePartitions.isBoxOpen(recordsBox))
            await CachePartitions.box(recordsBox).delete(_key(uid, company));
          return false;
        }
        if (!CachePartitions.isBoxOpen(recordsBox))
          await CachePartitions.openBox(recordsBox);
        final box = CachePartitions.box(recordsBox);
        final key = _key(uid, company);
        final lockKey = '$recordsBox:$key';
        final previous = _reads[lockKey] ?? Future<void>.value();
        final completer = Completer<bool>();
        final work = previous.then((_) async {
          try {
            if (_uid != uid || !_allowed(recordsBox) ||
                epoch != ReadAuthorizationEpoch.value ||
                readScope != _readScope(recordsBox)) {
              completer.complete(false);
              return;
            }
            final old = box.get(key);
            final valid = old is Map &&
                old['protocol'] == 2 &&
                old['read_scope'] == readScope &&
                old['owner_uid'] == uid &&
                old['company_code'] == company;
            final curCursor = valid ? (old['cursor'] as int? ?? 0) : 0;
            final curScope = valid ? (old['server_scope'] ?? '').toString() : '';
            if (curCursor != fromCursor || curScope != fromScope) {
              completer.complete(false);
              return;
            }
            await _applyRecordsResponse(
              decoded: decoded,
              old: old,
              valid: valid,
              box: box,
              key: key,
              uid: uid,
              company: company,
              readScope: readScope,
              boxName: recordsBox,
              mode: 'records',
            );
            completer.complete(true);
          } catch (_) {
            completer.complete(false);
          }
        });
        _reads[lockKey] = work;
        unawaited(work.whenComplete(() {
          if (identical(_reads[lockKey], work)) _reads.remove(lockKey);
        }));
        return completer.future;
      });
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> refreshRecords(String company) =>
      _refresh(recordsBox, company);
  Future<List<Map<String, dynamic>>> refreshEffects(String company) =>
      _refresh(effectsBox, company);
  Future<void> sync(String company) async {
    return CachePartitions.run(() async {
      await Future.wait([refreshRecords(company), refreshEffects(company)]);
    });
  }

  Future<void> reset(String company) async {
    return CachePartitions.run(() async {
      final uid = _uid;
      if (uid == null) throw StateError('يلزم تسجيل الدخول');
      for (final name in [recordsBox, effectsBox]) {
        if (CachePartitions.isBoxOpen(name))
          await CachePartitions.box(name).delete(_key(uid, company));
      }
      if (_uid == uid) await sync(company);
    });
  }

  Future<Map<String, dynamic>> save(Map<String, dynamic> transfer) async {
    return CachePartitions.run(() async {
      final uid = _uid;
      if (uid == null) throw StateError('يلزم تسجيل الدخول');
      final response = await AuthHttp.post(Uri.parse('$_base/save'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(transfer))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200)
        throw TreasuryTransferFailure(response.statusCode);
      final decoded = jsonDecode(response.body);
      if (decoded is! Map ||
          decoded['status'] != 'success' ||
          decoded['record'] is! Map ||
          decoded['record']['id'] != transfer['id'] ||
          decoded['record']['company_code'] != transfer['company_code'] ||
          transfer.entries
              .where((e) => !{'base_updated_at', 'serial'}.contains(e.key))
              .any((e) => decoded['record'][e.key] != e.value)) {
        throw const FormatException(
            'لم تصل نتيجة حفظ صالحة، أعد المحاولة بنفس التحويل');
      }
      var refreshPending = false;
      if (_uid == uid) {
        try {
          await sync(transfer['company_code'].toString());
        } catch (_) {
          refreshPending = true;
        }
      }
      return {
        ...Map<String, dynamic>.from(decoded),
        'refresh_pending': refreshPending
      };
    });
  }

  Future<Map<String, dynamic>> delete(Map<String, dynamic> transfer) async {
    return CachePartitions.run(() async {
      final uid = _uid;
      if (uid == null) throw StateError('يلزم تسجيل الدخول');
      final uri = Uri.parse(
              '$_base/delete/${transfer['company_code']}/${transfer['id']}')
          .replace(queryParameters: {
        'base_updated_at': transfer['updated_at'].toString()
      });
      final response =
          await AuthHttp.post(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200)
        throw StateError('لم يتم تأكيد حذف التحويل (${response.statusCode})');
      final decoded = jsonDecode(response.body);
      if (decoded is! Map ||
          decoded['status'] != 'success' ||
          decoded['record'] is! Map ||
          decoded['record']['id'] != transfer['id'] ||
          decoded['record']['company_code'] != transfer['company_code'] ||
          decoded['record']['is_deleted'] != true) {
        throw const FormatException('لم تصل نتيجة حذف صالحة');
      }
      var refreshPending = false;
      if (_uid == uid) {
        try {
          await sync(transfer['company_code'].toString());
        } catch (_) {
          refreshPending = true;
        }
      }
      return {
        ...Map<String, dynamic>.from(decoded),
        'refresh_pending': refreshPending
      };
    });
  }
}
