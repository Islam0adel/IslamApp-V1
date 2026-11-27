// frontend/lib/services/employee_service.dart
import 'cache_partitions.dart';
import 'read_authorization_snapshot.dart';

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/employee_model.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'staged_changes.dart';
import 'sync_read_access.dart';
import 'permissions_service.dart';

// خدمة الموظفين: تجلب بيانات الموظفين وتخزنها محليًا وتزامنها مع الخادم
class EmployeeService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;

  // ============================================================
  // Hive
  // ============================================================

  // يعيد صندوق الترميز المحلي
  Box get _codingBox => CachePartitions.box('coding_box');

  // ============================================================
  // مفتاح Hive (بنفس نمط CodingService للتوافق)
  // ============================================================

  // يبني مفتاح تخزين الموظفين للشركة
  String _localKey(String companyCode) => "${companyCode}_employees";

  // ============================================================
  // 1. جلب قائمة الموظفين (من Hive أو السيرفر)
  // ============================================================

  // يجلب قائمة الموظفين من التخزين المحلي
  Future<List<EmployeeModel>> getEmployeesList({
    required String companyCode,
    bool forceRefresh = false, // ⭐ جديد
    bool throwOnError = false,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      final String localKey = _localKey(companyCode);

      // ----------------------------------------------------------
      // 1) Hive (لو !forceRefresh)
      // ----------------------------------------------------------
      if (!forceRefresh && _codingBox.containsKey(localKey)) {
        final dynamic rawData = _codingBox.get(localKey);

        if (rawData is List) {
          print("⚡ الموظفين من Hive");

          final List<EmployeeModel> result = [];

          for (final item in rawData) {
            if (item is! Map) continue;

            final map = Map<String, dynamic>.from(item);

            if (map['is_deleted'] == true) continue;

            try {
              result.add(EmployeeModel.fromMap(map));
            } catch (e) {
              print("⚠️ خطأ في تحويل موظف: $e");
            }
          }

          return result;
        }
      }

      // ----------------------------------------------------------
      // 2) السيرفر (لو forceRefresh، أو Hive فاضي)
      // ----------------------------------------------------------
      print(
        forceRefresh
            ? "🔄 تحديث الموظفين من السيرفر (forceRefresh)"
            : "⚠️ لا توجد بيانات محلية للموظفين، جاري تحميلها من السيرفر...",
      );

      try {
        readScope.check();
        final response = await AuthHttp.get(
          Uri.parse("$baseUrl/employees/list/$companyCode"),
        );
        readScope.check();

        if (response.statusCode != 200) {
          print(
            "❌ خطأ من السيرفر [employees]: ${response.statusCode}",
          );
          if (throwOnError)
            throw StateError('Employee list HTTP ${response.statusCode}');
          return [];
        }

        final List<dynamic> decodedData = jsonDecode(response.body);

        final List<Map<String, dynamic>> cleanList = [];

        for (final item in decodedData) {
          if (item is! Map) continue;

          final map = Map<String, dynamic>.from(item);

          if (map['is_deleted'] == true) continue;

          map['is_deleted'] = false;
          cleanList.add(map);
        }

        cleanList.sort((a, b) {
          final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
          final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
          return aCode.compareTo(bCode);
        });

        readScope.check();
        await _codingBox.put(localKey, cleanList);
        readScope.check();

        print(
          "✅ تم جلب الموظفين من السيرفر "
          "وحفظهم في Hive (${cleanList.length})",
        );

        return cleanList.map((item) => EmployeeModel.fromMap(item)).toList();
      } catch (e) {
        print("❌ فشل الاتصال بالسيرفر [employees]: $e");
        if (throwOnError) rethrow;
        return [];
      }
    });
  }

  // ============================================================
  // 2. Full Sync (جهاز جديد — lastSync == null)
  // ============================================================

  // يجلب كل الموظفين من الخادم
  Future<void> fetchAllEmployees(String companyCode) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      print("📥 الموظفين: بدء FULL SYNC للشركة $companyCode");
      final v2Candidate = await _captureV2(companyCode);

      try {
        readScope.check();
        final response = await AuthHttp.get(
          Uri.parse('$baseUrl/employees/list/$companyCode'),
        );
        readScope.check();

        if (response.statusCode != 200) {
          throw Exception(
            'فشل تحميل الموظفين. '
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }

        final List<dynamic> data = jsonDecode(response.body);

        final List<Map<String, dynamic>> list = [];

        for (final item in data) {
          if (item is! Map) continue;

          final map = Map<String, dynamic>.from(item);

          if (map['is_deleted'] == true) continue;

          map['is_deleted'] = false;
          list.add(map);
        }

        list.sort((a, b) {
          final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
          final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
          return aCode.compareTo(bCode);
        });

        final String localKey = _localKey(companyCode);
        readScope.check();
        await _codingBox.put(localKey, list);
        readScope.check();

        print("✅ FULL SYNC: [employees] (${list.length})");
        print("✅ اكتمل FULL SYNC للموظفين للشركة $companyCode");
        await _commitV2(companyCode, v2Candidate);
      } catch (e) {
        print("❌ فشل FULL SYNC للموظفين: $e");
        rethrow;
      }
    });
  }

  // ============================================================
  // 3. المزامنة التزايدية (lastSync موجود)
  // ============================================================

  // يزامن تغييرات الموظفين من الخادم
  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      final prefs = await CachePartitions.preferences();
      readScope.check();

      final String lastSyncKey =
          '${ApiConstants.LAST_SYNC_CODING}_employees_$companyCode';

      final String? lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

      // ----------------------------------------------------------
      // جهاز جديد
      // ----------------------------------------------------------

      if (lastSyncValue == null || lastSyncValue.isEmpty) {
        print("📥 الموظفين: لا يوجد lastSync → FULL SYNC");

        await fetchAllEmployees(companyCode);
        readScope.check();
        await prefs.setString(
          lastSyncKey,
          DateTime.now().toUtc().toIso8601String(),
        );
        readScope.check();

        return;
      }

      // ----------------------------------------------------------
      // جهاز قديم
      // ----------------------------------------------------------

      print("📡 الموظفين: INCREMENTAL SYNC منذ $lastSyncValue");

      try {
        final v2Candidate = await _captureV2(companyCode);
        // The server feed was re-applied since this device last reconciled: one full reconcile that
        // REPLACES the cached list (rows gone from the server or hidden from this viewer disappear).
        final String? storedEpoch = prefs.getString(v2EpochKey(companyCode));
        if (v2Candidate != null &&
            storedEpoch != null &&
            storedEpoch != v2Candidate.epoch) {
          print("📥 الموظفين: feed epoch changed → FULL SYNC");
          final startedAt = DateTime.now().toUtc();
          await fetchAllEmployees(companyCode);
          readScope.check();
          await prefs.setString(lastSyncKey, startedAt.toIso8601String());
          return;
        }

        final DateTime syncStartedAt = DateTime.now().toUtc();

        final DateTime sinceDt = DateTime.parse(lastSyncValue).toUtc();

        final String effectiveSince = sinceDt.toIso8601String();

        readScope.check();
        final response = await AuthHttp.get(
          Uri.parse(
            '$baseUrl/employees/changes/'
            '$companyCode'
            '?since=$effectiveSince',
          ),
        );
        readScope.check();

        if (response.statusCode != 200) {
          throw Exception(
            'فشل مزامنة الموظفين. '
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }

        final List<dynamic> changes = jsonDecode(response.body);

        // ------------------------------------------------------
        // لا يوجد تغييرات
        // ------------------------------------------------------

        if (changes.isEmpty) {
          print("⏭️ [employees] لا يوجد تغييرات");

          readScope.check();
          await prefs.setString(
            lastSyncKey,
            syncStartedAt.toIso8601String(),
          );
          readScope.check();
          await _commitV2(companyCode, v2Candidate);
          return;
        }

        readScope.check();
        await _applyChanges(companyCode, changes, readScope.check);

        // ------------------------------------------------------
        // حفظ lastSync (فقط بعد النجاح)
        // ------------------------------------------------------

        readScope.check();
        await prefs.setString(
          lastSyncKey,
          syncStartedAt.toIso8601String(),
        );
        readScope.check();

        await _commitV2(companyCode, v2Candidate);

        print(
          "✅ تم تحديث الموظفين "
          "(${changes.length} تغيير)",
        );
      } catch (e) {
        print("❌ فشل INCREMENTAL SYNC للموظفين: $e");
        rethrow;
      }
    });
  }

  // يطبق التغييرات على القائمة المحلية
  /// Applies a list of employee changes (insert/update/delete/tombstone) to the cached list.
  /// Shared by the live incremental sync and by staged batches. `check` is the caller's
  /// authorization-epoch check, run before each write.
  Future<void> _applyChanges(
      String companyCode, List<dynamic> changes, void Function() check) async {
    final String localKey = _localKey(companyCode);
    // ------------------------------------------------------
    // قراءة القائمة المحلية
    // ------------------------------------------------------

    List<Map<String, dynamic>> currentList = [];

    if (_codingBox.containsKey(localKey)) {
      final dynamic raw = _codingBox.get(localKey);

      if (raw is List) {
        currentList = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['is_deleted'] != true)
            .toList();
      }
    }

    // ------------------------------------------------------
    // تطبيق التغييرات
    // ------------------------------------------------------

    for (final item in changes) {
      if (item is! Map) continue;

      final Map<String, dynamic> map = Map<String, dynamic>.from(item);

      final String action = map['action']?.toString() ??
          (map['is_deleted'] == true ? 'delete' : 'update');

      final String? code = map['code']?.toString();

      if (code == null || code.isEmpty) {
        print("⚠️ تحديث موظف بدون code");
        continue;
      }

      // إزالة النسخة القديمة
      currentList.removeWhere(
        (e) => e['code']?.toString() == code,
      );

      // DELETE
      if (action == 'delete' || map['is_deleted'] == true) {
        print("🗑️ حذف موظف [$code]");
        continue;
      }

      // INSERT / UPDATE
      map.remove('action');
      map['is_deleted'] = false;
      currentList.add(map);

      print("✅ تحديث موظف [$code]");
    }

    // ------------------------------------------------------
    // إزالة أي تكرارات + ترتيب
    // ------------------------------------------------------

    final Map<String, Map<String, dynamic>> uniqueItems = {};

    for (final item in currentList) {
      final code = item['code']?.toString() ?? '';
      if (code.isNotEmpty) {
        uniqueItems[code] = item;
      }
    }

    currentList = uniqueItems.values.toList();

    currentList.sort((a, b) {
      final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
      final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
      return aCode.compareTo(bCode);
    });

    // ------------------------------------------------------
    // حفظ
    // ------------------------------------------------------

    if (currentList.isEmpty) {
      await _codingBox.delete(localKey);
      check();
    } else {
      check();
      await _codingBox.put(localKey, currentList);
      check();
    }
  }

  // ============================================================
  // Closed-app staging: commit-safe feed /employees/changes-v2 (checkpoint, apply)
  // ============================================================

  /// Set by StagedInbox so the worker learns the new employees checkpoint.
  static void Function(String company)? onCheckpointChanged;

  // يعيد مفتاح مؤشر النسخة الثانية للمزامنة
  static String v2CursorKey(String company) =>
      '${ApiConstants.LAST_SYNC_CODING}_employees_${company}_v2';

  // يعيد مفتاح نطاق النسخة الثانية للمزامنة
  static String v2ScopeKey(String company) =>
      '${ApiConstants.LAST_SYNC_CODING}_employees_${company}_v2scope';

  // يعيد مفتاح عهد النسخة الثانية للمزامنة
  static String v2EpochKey(String company) =>
      '${ApiConstants.LAST_SYNC_CODING}_employees_${company}_v2epoch';

  // يلتقط مؤشر المزامنة ونطاقه وعهده قبل الجلب
  Future<({String cursor, String scope, String epoch})?> _captureV2(
      String company) async {
    try {
      final r = await AuthHttp.get(
              Uri.parse('$baseUrl/employees/changes-v2/$company?cursor=latest'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body);
      if (m is! Map ||
          m['invalid'] == true ||
          m['next_cursor'] is! String ||
          m['scope'] is! String ||
          (m['next_cursor'] as String).isEmpty ||
          (m['scope'] as String).isEmpty) return null;
      return (
        cursor: m['next_cursor'] as String,
        scope: m['scope'] as String,
        epoch: (m['epoch'] ?? '').toString()
      );
    } catch (_) {
      return null;
    }
  }

  // يثبّت المؤشر الملتقط بعد نجاح التطبيق
  Future<void> _commitV2(String company,
      ({String cursor, String scope, String epoch})? cand) async {
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

  // يعيد نقطة تحقق للعمل المرحلي للشركة
  Future<({String cursor, String scope})?> stagedCheckpoint(
      String company) async {
    try {
      if (!SyncReadAccess.allows('employees')) return null;
      final prefs = await CachePartitions.preferences();
      final c = prefs.getString(v2CursorKey(company));
      final s = prefs.getString(v2ScopeKey(company));
      if (c == null || c.isEmpty || s == null || s.isEmpty) return null;
      return (cursor: c, scope: s);
    } catch (_) {
      return null;
    }
  }

  // يحدد هل يحق للمستخدم رؤية الرواتب
  bool _maySeeSalary() {
    final p = PermissionsService();
    return p.canBypassPermissions ||
        p.hasPermission('الموارد البشرية', 'canViewSalaryAmounts');
  }

  // يطبق دفعة مرحلية واحدة من استجابة التغييرات
  /// Applies one /employees/changes-v2 response fetched by the service worker while the app was
  /// closed. Applied only when it continues exactly from the stored cursor and scope, under the
  /// employees read right held NOW. An item (or removal) older than the cached row is skipped, so a
  /// removal can never delete a row the live sync brought back later. Returns true when applied.
  Future<bool> applyStagedBatch(String company, dynamic decoded,
      {required String fromCursor, required String fromScope}) async {
    try {
      return await CachePartitions.run(() async {
        final epoch = ReadAuthorizationEpoch.value;
        if (!SyncReadAccess.allows('employees')) return false;
        final prefs = await CachePartitions.preferences();
        if (prefs.getString(v2CursorKey(company)) != fromCursor ||
            prefs.getString(v2ScopeKey(company)) != fromScope) return false;
        if (decoded is! Map ||
            decoded['invalid'] == true ||
            decoded['scope'] != fromScope ||
            decoded['next_cursor'] is! String ||
            (decoded['next_cursor'] as String).isEmpty ||
            decoded['items'] is! List) return false;
        final stored = _codingBox.get(_localKey(company));
        final localStamp = <String, DateTime?>{};
        if (stored is List) {
          for (final r in stored) {
            if (r is Map) {
              localStamp[r['code']?.toString() ?? ''] =
                  StagedChanges.stamp(r['updated_at']);
            }
          }
        }
        final uid = FirebaseAuth.instance.currentUser?.uid;
        final scopeBefore = PermissionsService().effectiveScopeSignature();
        final fresh = <Map<String, dynamic>>[];
        for (final raw in decoded['items'] as List) {
          if (raw is! Map) return false;
          final m = Map<String, dynamic>.from(raw);
          if (m['company_code'] != company) return false;
          final l = localStamp[m['code']?.toString() ?? ''];
          final i = StagedChanges.stamp(m['updated_at']);
          if (l != null && i != null && l.isAfter(i)) continue;
          // Defense in depth: never store a salary the client has no right to now (the viewer's own
          // record is the only exception, as on the server).
          if (m['tombstone'] != true &&
              m.containsKey('salary') &&
              !_maySeeSalary() &&
              !(uid != null && m['user_uid'] == uid)) {
            m['salary'] = null;
          }
          m.remove('tombstone');
          fresh.add(m);
        }
        if (fresh.isNotEmpty) {
          if (!SyncReadAccess.allows('employees') ||
              epoch != ReadAuthorizationEpoch.value) return false;
          await _applyChanges(company, fresh, () {});
          // Writing the viewer's own employee row can itself refresh the account link and move the
          // authorization epoch, so after the write compare the FULL effective scope (rights,
          // branches, viewable list, role, policy, account) instead of the epoch.
        }
        if (!SyncReadAccess.allows('employees') ||
            PermissionsService().effectiveScopeSignature() != scopeBefore) {
          // The viewer's scope changed while the write was in flight. The revocation may already have
          // purged before this write landed, so take back every row this batch just wrote: they were
          // fetched under the old scope and must not outlive it. (Removals stay removed.)
          final written = {
            for (final m in fresh)
              if (m['action'] != 'delete') m['code']?.toString()
          };
          final raw = _codingBox.get(_localKey(company));
          if (raw is List && written.isNotEmpty) {
            final keep = raw
                .where((e) =>
                    !(e is Map && written.contains(e['code']?.toString())))
                .toList();
            if (keep.isEmpty) {
              await _codingBox.delete(_localKey(company));
            } else {
              await _codingBox.put(_localKey(company), keep);
            }
          }
          return false;
        }
        await prefs.setString(
            v2CursorKey(company), decoded['next_cursor'] as String);
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
  // 4. حفظ موظف (إضافة أو تحديث)
  // ============================================================

  // يحفظ بيانات موظف جديد أو معدّل
  Future<Map<String, dynamic>> saveEmployee({
    required String companyCode,
    required EmployeeModel model,
  }) async {
    return CachePartitions.run(() async {
      final cacheScope = await ReadAuthorizationSnapshot.capture();
      try {
        final Map<String, dynamic> bodyData =
            Map<String, dynamic>.from(model.toMap());

        bodyData['company_code'] = companyCode;

        cacheScope.check();
        final response = await AuthHttp.post(
          Uri.parse("$baseUrl/employees/save"),
          headers: {"Content-Type": "application/json"},
          body: json.encode(bodyData),
        );

        if (response.statusCode != 200) {
          return {
            'success': false,
            'error': 'فشل الحفظ من السيرفر. '
                'كود الخطأ: ${response.statusCode}',
          };
        }

        final Map<String, dynamic> result = json.decode(response.body);

        final String newCode = result['code']?.toString() ?? model.code;

        final String action = result['action']?.toString() ?? 'update';

        if (!cacheScope.isCurrent)
          return {
            'success': true,
            'code': newCode,
            'action': action,
            'scope_changed': true
          };

        final String localKey = _localKey(companyCode);

        // --------------------------------------------------------
        // قراءة القائمة الحالية
        // --------------------------------------------------------

        List<Map<String, dynamic>> currentList = [];

        if (_codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);

          if (rawData is List) {
            currentList = rawData
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .where((item) => item['is_deleted'] != true)
                .toList();
          }
        }

        // --------------------------------------------------------
        // البيانات الجديدة
        // --------------------------------------------------------

        final Map<String, dynamic> newItem =
            Map<String, dynamic>.from(model.toMap());

        newItem['code'] = newCode;
        newItem['company_code'] = companyCode;
        newItem['is_deleted'] = false;

        // --------------------------------------------------------
        // حذف النسخة القديمة + إضافة الجديدة
        // --------------------------------------------------------

        currentList.removeWhere(
          (item) => item['code']?.toString() == newCode,
        );

        currentList.add(newItem);

        // --------------------------------------------------------
        // إزالة التكرار + ترتيب
        // --------------------------------------------------------

        final Map<String, Map<String, dynamic>> uniqueItems = {};

        for (final item in currentList) {
          final String code = item['code']?.toString() ?? '';
          if (code.isNotEmpty) {
            uniqueItems[code] = item;
          }
        }

        currentList = uniqueItems.values.toList();

        currentList.sort((a, b) {
          final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
          final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
          return aCode.compareTo(bCode);
        });

        await _codingBox.put(localKey, currentList);

        print("✅ تم الحفظ المحلي للموظف [$newCode]");

        return {
          'success': true,
          'code': newCode,
          'action': action,
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
  // 5. حذف موظف
  // ============================================================

  // يحذف موظفًا
  Future<bool> deleteEmployee({
    required String companyCode,
    required String code,
  }) async {
    return CachePartitions.run(() async {
      try {
        final response = await AuthHttp.delete(
          Uri.parse(
            "$baseUrl/employees/delete/$companyCode/$code",
          ),
        );

        if (response.statusCode != 200) {
          print(
            "❌ السيرفر رفض حذف الموظف [$code] "
            "HTTP ${response.statusCode}",
          );
          return false;
        }

        // --------------------------------------------------------
        // حذف محلي فوري
        // --------------------------------------------------------

        final String localKey = _localKey(companyCode);

        if (_codingBox.containsKey(localKey)) {
          final dynamic rawData = _codingBox.get(localKey);

          if (rawData is List) {
            final List<Map<String, dynamic>> safeList = [];

            for (final item in rawData) {
              if (item is! Map) continue;

              final Map<String, dynamic> safeMap =
                  Map<String, dynamic>.from(item);

              if (safeMap['code']?.toString() == code.toString()) {
                continue;
              }

              if (safeMap['is_deleted'] == true) {
                continue;
              }

              safeList.add(safeMap);
            }

            if (safeList.isEmpty) {
              await _codingBox.delete(localKey);
            } else {
              await _codingBox.put(localKey, safeList);
            }

            print("✅ تم حذف الموظف [$code] من Hive");
          }
        }

        return true;
      } catch (e) {
        print("❌ خطأ أثناء حذف الموظف: $e");
        return false;
      }
    });
  }

  // ============================================================
  // 6. جلب موظف واحد بالتفصيل
  // ============================================================

  // يجلب موظفًا واحدًا
  Future<EmployeeModel?> getEmployee({
    required String companyCode,
    required String code,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      try {
        readScope.check();
        final response = await AuthHttp.get(
          Uri.parse(
            "$baseUrl/employees/get/$companyCode/$code",
          ),
        );
        readScope.check();

        if (response.statusCode != 200) {
          print(
            "❌ فشل جلب الموظف [$code]: "
            "${response.statusCode}",
          );
          return null;
        }

        final Map<String, dynamic> data = jsonDecode(response.body);
        return EmployeeModel.fromMap(data);
      } catch (e) {
        print("❌ خطأ في جلب الموظف: $e");
        return null;
      }
    });
  }
}
