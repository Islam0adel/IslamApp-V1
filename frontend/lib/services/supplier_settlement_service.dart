import 'cache_partitions.dart';
import 'journal_cache.dart';
// lib/services/supplier_settlement_service.dart

import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'daily_service.dart';
import '../core/constants.dart';
import '../models/supplier_settlement_model.dart';
import 'auth_http.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';
import 'staged_changes.dart';
import 'sync_read_access.dart';

class SupplierSettlementService {
  final String baseUrl = ApiConstants.baseUrl;
  Box get _box => CachePartitions.box('supplier_settlement_box');

  String newLinkId() => 'supplier-${DateTime.now().microsecondsSinceEpoch}';

  // ============================================================
  // هل الفرع = كل الفروع؟
  // ============================================================

  bool _isAllBranches(String? branchCode) =>
      branchCode == null ||
      branchCode.isEmpty ||
      branchCode == 'all' ||
      branchCode == 'الكل' ||
      branchCode == 'كل الفروع';

  // ============================================================
  // رصيد التسويات لمورد
  //
  // لو الفرع = all يتم حساب كل الفروع.
  // ============================================================

  Future<double> getSupplierSettlementTotal(
    String companyCode,
    String branchCode,
    String supplierName,
  ) async {
return CachePartitions.run(() async {

    double total = 0.0;

    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw is! List) continue;

      for (final item in raw) {
        final map = _toMap(item);

        if (map.isEmpty || map['is_deleted'] == true) continue;
        if (map['company_code']?.toString() != companyCode) continue;

        if (!_isAllBranches(branchCode) &&
            map['branch_code']?.toString() != branchCode) {
          continue;
        }

        if (map['supplier_name']?.toString() != supplierName) {
          continue;
        }

        total += _toDouble(map['amount']);
      }
    }

    return total;
});
}

  // ============================================================
  // السيريال التالي
  //
  // يتم الترقيم لكل شركة + فرع.
  // ============================================================

  // lib/services/supplier_settlement_service.dart

int _getNextSerial(String companyCode, String branchCode) {
  int maxSerial = 0;

  for (final key in _box.keys) {
    final raw = _box.get(key);
    if (raw is! List) continue;

    for (final item in raw) {
      final map = _toMap(item);
      if (map.isEmpty) continue; // تشمل السجلات المحذوفة

      if (map['company_code']?.toString() != companyCode ||
          map['branch_code']?.toString() != branchCode) {
        continue;
      }

      final serial = _toInt(map['serial']);
      if (serial > maxSerial) maxSerial = serial;
    }
  }

  return maxSerial + 1;
}

  // ============================================================
  // حفظ تسوية
  // ============================================================

  Future<Map<String, dynamic>> saveSettlement(
    SupplierSettlementModel model,
  ) async {
return CachePartitions.run(() async {

    try {
      // --------------------------------------------------------
      // التأكد من رقم الإذن
      // --------------------------------------------------------

      if (model.serial <= 0) {
        model.serial = _getNextSerial(
          model.companyCode,
          model.branchCode,
        );
      }

      // --------------------------------------------------------
      // تحديث وقت التعديل
      // --------------------------------------------------------

      model.updatedAt = DateTime.now();

      // --------------------------------------------------------
      // إرسال للسيرفر
      // --------------------------------------------------------

      final response = await AuthHttp.post(
        Uri.parse('$baseUrl/supplier-settlement/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(model.toMap()),
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error':
              'HTTP ${response.statusCode}: ${response.body}',
        };
      }

      final result = jsonDecode(response.body)
          as Map<String, dynamic>;

      final docId = result['doc_id']?.toString() ?? '';

      if (docId.isEmpty) {
        return {
          'success': false,
          'error': 'السيرفر لم يرجع doc_id',
        };
      }

      // --------------------------------------------------------
      // حفظ doc_id
      // --------------------------------------------------------

      model.docId = docId;

      // لو السيرفر رجع serial نستخدمه
      if (result['serial'] is num) {
        model.serial = (result['serial'] as num).toInt();
      }
      if (model.unlinkDaily) model.linkId = null;

      // --------------------------------------------------------
      // حفظ محلي
      // --------------------------------------------------------

      await _saveLocal(model);

final linkedRaw = result['linked_transaction'];
      if (linkedRaw is Map) {
        final linked = Map<String, dynamic>.from(linkedRaw);
        final dailyBox = CachePartitions.box('daily_transactions_box');
        for (final oldKey in dailyBox.keys.toList()) {
          final old = dailyBox.get(oldKey);
          if (old is Map && old['company_code']?.toString() == model.companyCode && old['link_id']?.toString() == linked['link_id']?.toString()) {
            await dailyBox.delete(oldKey);
          }
        }
        if (linked['is_deleted'] != true) {
          await JournalCache.put(dailyBox, linked, expectedCompany: model.companyCode);
        }

        final String targetBranch =
            linked['branch_code']?.toString() ?? model.branchCode;
        await DailyService().getDailySummaryLocal(
          model.companyCode,
          branchCode: targetBranch,
        );
        if (!_isAllBranches(targetBranch)) {
          await DailyService().getDailySummaryLocal(
            model.companyCode,
            branchCode: 'all',
          );
        }
      }

      return {
        'success': true,
        'doc_id': model.docId,
        'serial': model.serial,
        'action':
            result['action']?.toString() ?? 'insert',
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
});
}

  // ============================================================
  // حفظ محلي
  // ============================================================

  Future<void> _saveLocal(
    SupplierSettlementModel model,
  ) async {
return CachePartitions.run(() async {

    final key =
        '${model.companyCode}_${model.branchCode}_${model.date}';

    List<Map<String, dynamic>> list = [];

    final raw = _box.get(key);

    if (raw is List) {
      list = raw
          .whereType<Map>()
          .map(_toMap)
          .where((e) => e.isNotEmpty && e['is_deleted'] != true)
          .toList();
    }

    final item = _toMap(model.toMap());

    item['doc_id'] = model.docId;
    item['serial'] = model.serial;
    item['employee'] = model.employee;
    item['is_deleted'] = false;

    list.removeWhere(
      (e) =>
          e['doc_id']?.toString() ==
          model.docId?.toString(),
    );

    list.add(item);

    await _box.put(key, list);
});
}

  // ============================================================
  // جلب التسويات
  //
  // all = كل الفروع
  // ============================================================

  Future<List<SupplierSettlementModel>> getSettlements({
    required String companyCode,
    String? branchCode,
    String? supplierName,
    String? startDate,
    String? endDate,
  }) async {
return CachePartitions.run(() async {

    final List<SupplierSettlementModel> result = [];

    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw is! List) continue;

      for (final item in raw) {
        final map = _toMap(item);

        if (map.isEmpty || map['is_deleted'] == true) continue;
        if (map['company_code']?.toString() != companyCode) continue;

        if (!_isAllBranches(branchCode) &&
            map['branch_code']?.toString() != branchCode) {
          continue;
        }

        if (supplierName != null &&
            supplierName.isNotEmpty &&
            map['supplier_name']?.toString() != supplierName) {
          continue;
        }

        final date = map['date']?.toString() ?? '';

        if (startDate != null &&
            date.compareTo(startDate) < 0) {
          continue;
        }

        if (endDate != null &&
            date.compareTo(endDate) > 0) {
          continue;
        }

        try {
          result.add(
            SupplierSettlementModel.fromMap(map),
          );
        } catch (e) {
          print(
            '⚠️ خطأ في تحويل التسوية: $e',
          );
        }
      }
    }

    result.sort((a, b) {
      final dateCompare = b.date.compareTo(a.date);

      if (dateCompare != 0) return dateCompare;

      return b.serial.compareTo(a.serial);
    });

    return result;
});
}

  // ============================================================
  // حذف تسوية
  // ============================================================

  Future<bool> deleteSettlement(
  String companyCode,
  String docId,
) async {
return CachePartitions.run(() async {

  try {
    String? linkedDailyId;
    for (final raw in _box.values.whereType<List>().expand((items) => items)) {
      if (raw is Map && raw['doc_id']?.toString() == docId) {
        linkedDailyId = raw['link_id']?.toString();
        break;
      }
    }
    final response = await AuthHttp.delete(
      Uri.parse(
        '$baseUrl/supplier-settlement/delete/'
        '$companyCode/$docId',
      ),
    );

    if (response.statusCode != 200) {
      print(
        '❌ فشل حذف التسوية: ${response.statusCode}',
      );
      return false;
    }

    // ============================================================
    // Soft Delete محلياً
    // ============================================================

    final keys = _box.keys.toList();

    for (final key in keys) {
      final raw = _box.get(key);
      if (raw is! List) continue;

      final List<Map<String, dynamic>> updated = [];
      bool found = false;

      for (final item in raw) {
        final map = _toMap(item);

        if (map.isEmpty) continue;

        if (map['doc_id']?.toString() == docId.toString()) {
          found = true;

          // ✅ نحتفظ به مع علامة محذوف
          map['is_deleted'] = true;
          map['updated_at'] = DateTime.now().toUtc().toIso8601String();

          updated.add(map);
          continue;
        }

        if (map['is_deleted'] == true) {
          continue;
        }

        updated.add(map);
      }

      if (!found) continue;

      if (updated.isEmpty) {
        await _box.delete(key);
      } else {
        await _box.put(key, updated);
      }

      break;
    }

    if (linkedDailyId != null && linkedDailyId.isNotEmpty) {
      final dailyBox = CachePartitions.box('daily_transactions_box');
      for (final key in dailyBox.keys.toList()) {
        final raw = dailyBox.get(key);
        if (raw is Map && raw['company_code']?.toString() == companyCode && raw['link_id']?.toString() == linkedDailyId) {
          await dailyBox.delete(key);
        }
      }
    }

    return true;
  } catch (e) {
    print(
      '❌ خطأ حذف التسوية: $e',
    );
    return false;
  }

});
}

  // ============================================================
  // Full Sync
  // ============================================================

  Future<void> fetchAllSettlements(
    String companyCode, {
    bool replace = false,
  }) async {
return CachePartitions.run(() async {

    final v2Candidate = await _captureV2(companyCode);

    try {
      final response = await AuthHttp.get(
        Uri.parse(
          '$baseUrl/supplier-settlement/list/$companyCode',
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'فشل تحميل التسويات: '
          '${response.statusCode}: '
          '${response.body}',
        );
      }

      final List<dynamic> data =
          jsonDecode(response.body);

      // --------------------------------------------------------
      // نضع فقط السجلات النشطة.
      // --------------------------------------------------------

      final models = <SupplierSettlementModel>[];
      for (final raw in data) {
        final map = _toMap(raw);

        if (map.isEmpty || map['is_deleted'] == true) {
          continue;
        }

        map['is_deleted'] = false;

        models.add(SupplierSettlementModel.fromMap(map));
      }

      // Epoch reconcile: replace this company's cached lists with the server copy. The old lists are
      // kept in memory and put back if a write fails, so a failed reconcile never leaves a half list.
      final Map<dynamic, dynamic> snapshot = {};
      if (replace) {
        final prefix = '${companyCode}_';
        for (final k in _box.keys.toList()) {
          if (k.toString().startsWith(prefix)) {
            snapshot[k] = _box.get(k);
            await _box.delete(k);
          }
        }
      }
      try {
        for (final model in models) {
          await _saveLocal(model);
        }
      } catch (_) {
        if (replace) {
          for (final k in _box.keys.toList()) {
            if (k.toString().startsWith('${companyCode}_')) await _box.delete(k);
          }
          for (final e in snapshot.entries) {
            await _box.put(e.key, e.value);
          }
        }
        rethrow;
      }

      print(
        '✅ تم FULL SYNC للتسويات '
        '(${data.length} سجل)',
      );
      await _commitV2(companyCode, v2Candidate);
    } catch (e) {
      print(
        '❌ فشل FULL SYNC للتسويات: $e',
      );
      rethrow;
    }
});
}

  // ============================================================
  // Staged feed (/supplier-settlement/changes-v2) checkpoint + merge
  // ============================================================

  static void Function(String company)? onCheckpointChanged;
  static String v2CursorKey(String c) => '${ApiConstants.LAST_SYNC_SETTLEMENT}${c}_v2';
  static String v2ScopeKey(String c) => '${ApiConstants.LAST_SYNC_SETTLEMENT}${c}_v2scope';
  static String v2EpochKey(String c) => '${ApiConstants.LAST_SYNC_SETTLEMENT}${c}_v2epoch';

  Future<({String cursor, String scope, String epoch})?> _captureV2(String company) async {
    try {
      final r = await AuthHttp.get(Uri.parse('$baseUrl/supplier-settlement/changes-v2/$company?cursor=latest'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body);
      if (m is! Map ||
          m['invalid'] == true ||
          m['next_cursor'] is! String ||
          m['scope'] is! String ||
          (m['next_cursor'] as String).isEmpty ||
          (m['scope'] as String).isEmpty) return null;
      return (cursor: m['next_cursor'] as String, scope: m['scope'] as String, epoch: (m['epoch'] ?? '').toString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _commitV2(String company, ({String cursor, String scope, String epoch})? cand) async {
    if (cand == null) return;
    try {
      final prefs = await CachePartitions.preferences();
      await prefs.setString(v2CursorKey(company), cand.cursor);
      await prefs.setString(v2ScopeKey(company), cand.scope);
      await prefs.setString(v2EpochKey(company), cand.epoch);
      try {
        onCheckpointChanged?.call(company);
      } catch (_) {}
    } catch (_) {}
  }

  Future<({String cursor, String scope})?> stagedCheckpoint(String company) async {
    try {
      final allowed = SyncReadAccess.allows('settlement');
      final prefs = await CachePartitions.preferences();
      final c = prefs.getString(v2CursorKey(company));
      final s = prefs.getString(v2ScopeKey(company));
      if (!allowed) return null;
      if (c == null || c.isEmpty || s == null || s.isEmpty) return null;
      return (cursor: c, scope: s);
    } catch (_) {
      return null;
    }
  }

  /// Applies one /supplier-settlement/changes-v2 response fetched by the service worker while the app was
  /// closed. Applied only when it continues exactly from the stored cursor and scope, under the
  /// settlement read right held NOW. Returns true when applied.
  Future<bool> applyStagedBatch(String company, dynamic decoded,
      {required String fromCursor, required String fromScope}) async {
    try {
      return await CachePartitions.run(() async {
        final epoch = ReadAuthorizationEpoch.value;
        if (!SyncReadAccess.allows('settlement')) return false;
        final prefs = await CachePartitions.preferences();
        if (prefs.getString(v2CursorKey(company)) != fromCursor ||
            prefs.getString(v2ScopeKey(company)) != fromScope) return false;
        if (decoded is! Map ||
            decoded['invalid'] == true ||
            decoded['scope'] != fromScope ||
            decoded['next_cursor'] is! String ||
            (decoded['next_cursor'] as String).isEmpty ||
            decoded['items'] is! List) return false;
        final localStamp = <String, DateTime?>{};
        for (final key in _box.keys) {
          final raw = _box.get(key);
          if (raw is! List) continue;
          for (final v in raw) {
            if (v is Map) localStamp[v['doc_id']?.toString() ?? ''] = StagedChanges.stamp(v['updated_at']);
          }
        }
        final scopeBefore = PermissionsService().effectiveScopeSignature();
        final fresh = <Map<String, dynamic>>[];
        for (final raw in decoded['items'] as List) {
          if (raw is! Map) return false;
          final m = _toMap(raw);
          if (m['company_code']?.toString() != company) return false;
          final id = m['doc_id']?.toString() ?? '';
          if (id.isEmpty) return false;
          final l = localStamp[id];
          final i = StagedChanges.stamp(m['updated_at']);
          if (l != null && i != null && l.isAfter(i)) continue;
          m.remove('tombstone');
          fresh.add(m);
        }
        if (fresh.isNotEmpty) {
          if (!SyncReadAccess.allows('settlement') || epoch != ReadAuthorizationEpoch.value) return false;
          await _applyChanges(company, fresh);
        }
        if (!SyncReadAccess.allows('settlement') ||
            PermissionsService().effectiveScopeSignature() != scopeBefore) {
          // Scope (rights, branches, role, policy) moved while writing: take back this batch's rows.
          final written = {for (final m in fresh) if (m['action'] != 'delete') m['doc_id']?.toString()};
          if (written.isNotEmpty) {
            for (final key in _box.keys.toList()) {
              final raw = _box.get(key);
              if (raw is! List) continue;
              final keep = raw.where((e) => !(e is Map && written.contains(e['doc_id']?.toString()))).toList();
              if (keep.length == raw.length) continue;
              if (keep.isEmpty) {
                await _box.delete(key);
              } else {
                await _box.put(key, keep);
              }
            }
          }
          return false;
        }
        await prefs.setString(v2CursorKey(company), decoded['next_cursor'] as String);
        try {
          onCheckpointChanged?.call(company);
        } catch (_) {}
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  // ============================================================
  // Incremental Sync
  // ============================================================

  // lib/services/supplier_settlement_service.dart

  /// Applies a list of settlement changes (update/delete/tombstone) to the cached lists. Shared by the
  /// live incremental sync and by staged batches.
  Future<void> _applyChanges(String companyCode, List<dynamic> changes) async {
    for (final raw in changes) {
      final map = _toMap(raw);
      if (map.isEmpty) continue;

      final docId = map['doc_id']?.toString();
      if (docId == null || docId.isEmpty) {
        print('⚠️ تحديث تسوية بدون doc_id');
        continue;
      }

      final action = map['action']?.toString() ??
          (map['is_deleted'] == true ? 'delete' : 'update');

      // ========================================================
      // 1. حذف doc_id من جميع المفاتيح
      // ========================================================

      final keys = _box.keys.toList();

      for (final oldKey in keys) {
        final rawList = _box.get(oldKey);
        if (rawList is! List) continue;

        final List<Map<String, dynamic>> updatedList = [];
        bool found = false;

        for (final item in rawList) {
          final itemMap = _toMap(item);
          if (itemMap.isEmpty) continue;

          if (itemMap['doc_id']?.toString() == docId) {
            found = true;
            continue;
          }

          if (itemMap['is_deleted'] == true) continue;

          updatedList.add(itemMap);
        }

        if (!found) continue;

        if (updatedList.isEmpty) {
          await _box.delete(oldKey);
        } else {
          await _box.put(oldKey, updatedList);
        }
      }

      // ========================================================
      // 2. لو حذف → خلاص
      // ========================================================

      if (action == 'delete' || map['is_deleted'] == true) {
        print('🗑️ تم حذف التسوية [$docId] من Hive (Incremental Sync)');
        continue;
      }

      // ========================================================
      // 3. إضافة أو تحديث في المفتاح الجديد
      // ========================================================

      final company = map['company_code']?.toString() ?? companyCode;
      final branch = map['branch_code']?.toString() ?? 'all';
      final date = map['date']?.toString() ?? '';

      if (company.isEmpty || branch.isEmpty || date.isEmpty) {
        print('⚠️ بيانات المفتاح ناقصة للتسوية [$docId]');
        continue;
      }

      final newKey = '${company}_${branch}_$date';

      List<Map<String, dynamic>> list = [];

      final rawList = _box.get(newKey);
      if (rawList is List) {
        list = rawList
            .whereType<Map>()
            .map(_toMap)
            .where(
              (e) => e.isNotEmpty && e['is_deleted'] != true,
            )
            .toList();
      }

      // منع التكرار
      list.removeWhere(
        (item) => item['doc_id']?.toString() == docId,
      );

      map.remove('action');
      map['is_deleted'] = false;

      list.add(map);

      await _box.put(newKey, list);

      print('✅ تم تحديث التسوية [$docId] في المفتاح [$newKey]');
    }

  }

Future<void> syncChangesFromServer(
  String companyCode, [
  String? lastSync,
]) async {
return CachePartitions.run(() async {

  final prefs = await CachePartitions.preferences();
  final String lastSyncKey =
      '${ApiConstants.LAST_SYNC_SETTLEMENT}$companyCode';
  final String? savedLastSync = lastSync ?? prefs.getString(lastSyncKey);

  // ==========================================================
  // جهاز جديد → Full Sync
  // ==========================================================

  if (savedLastSync == null || savedLastSync.isEmpty) {
    print('📥 التسويات: لا يوجد lastSync → FULL SYNC');
    await fetchAllSettlements(companyCode);
    await prefs.setString(
      lastSyncKey,
      DateTime.now().toUtc().toIso8601String(),
    );
    return;
  }

  try {
    final v2Candidate = await _captureV2(companyCode);
    final String? storedEpoch = prefs.getString(v2EpochKey(companyCode));
    if (v2Candidate != null && storedEpoch != null && storedEpoch != v2Candidate.epoch) {
      print('📥 التسويات: feed epoch changed → FULL SYNC');
      final startedAt = DateTime.now().toUtc();
      await fetchAllSettlements(companyCode, replace: true);
      await prefs.setString(lastSyncKey, startedAt.toIso8601String());
      return;
    }
    final DateTime syncStartedAt = DateTime.now().toUtc();
    DateTime since = DateTime.parse(savedLastSync).toUtc();
    since = since.subtract(const Duration(minutes: 1));

    final response = await AuthHttp.get(
      Uri.parse(
        '$baseUrl/supplier-settlement/changes/$companyCode'
        '?since=${since.toIso8601String()}',
      ),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'فشل مزامنة التسويات: ${response.statusCode}: ${response.body}',
      );
    }

    final List<dynamic> changes = jsonDecode(response.body);

    await _applyChanges(companyCode, changes);

    // ========================================================
    // تحديث lastSync فقط بعد نجاح الكل
    // ========================================================

    await prefs.setString(
      lastSyncKey,
      syncStartedAt.toIso8601String(),
    );
    await _commitV2(companyCode, v2Candidate);

    print(
      '✅ تمت مزامنة ${changes.length} تحديث للتسويات (Incremental Sync)',
    );
  } catch (e) {
    print('❌ فشل مزامنة التسويات: $e');
    rethrow;
  }

});
}

  // ============================================================
  // Helpers
  // ============================================================

  Map<String, dynamic> _toMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }

    if (value is Map) {
      return Map<String, dynamic>.from(
        value.map(
          (key, value) =>
              MapEntry(
                key.toString(),
                value,
              ),
        ),
      );
    }

    return {};
  }

  double _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(
          value?.toString() ?? '',
        ) ??
        0.0;
  }

  int _toInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
  }
}
