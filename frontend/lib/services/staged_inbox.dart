// frontend/lib/services/staged_inbox.dart
//
// Connects StagedChanges to the real app: daily journal box, partition-scoped
// cursor, Firebase token, permission scope. Every failure is swallowed on
// purpose: the normal incremental sync that runs right after is authoritative.

import 'package:firebase_core/firebase_core.dart';
import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import 'cache_partitions.dart';
import 'journal_cache.dart';
import 'permissions_service.dart';
import 'treasury_transfer_service.dart';
import 'coding_service.dart';
import 'employee_service.dart';
import 'supplier_service.dart';
import 'supplier_settlement_service.dart';
import 'inventory_service.dart';
import 'commercial_service.dart';
import 'hr_service.dart';
import 'read_authorization_snapshot.dart';
import 'auth_http.dart';
import 'staged_changes.dart';
import 'staged_inbox_stub.dart'
    if (dart.library.js_interop) 'staged_inbox_web.dart';

// مخزن مرحلي يعمل على الويب
class _WebStore implements StagedStore {
  // يقرأ الدفعات المرحلية للنطاق
  @override
  Future<List<StagedBatch>> read(String scopeKey) async {
    final raw = jsonDecode(await jsStagedRead(scopeKey)) as List;
    return raw
        .whereType<Map>()
        .map((e) => StagedBatch.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // يزيل الدفعات المرحلية المحددة
  @override
  Future<void> remove(String scopeKey, List<String> ids) =>
      jsStagedRemove(scopeKey, jsonEncode(ids));

  // يسجّل فشل تطبيق دفعة ويعيد عدد مرات الفشل
  @override
  Future<int> recordFailure(String scopeKey, String id) =>
      jsStagedRecordFailure(scopeKey, id);
}

// هدف الدمج الخاص باليومية
class _DailyTarget implements StagedTarget {
  _DailyTarget(
      this.company, this.box, this.prefs, this.cursorKey, this.publishCursor);
  final String company;
  final Box box;
  final CachePreferences prefs;
  final String cursorKey;
  final Future<void> Function(DateTime) publishCursor;

  // يعيد ختم الوقت المحلي للقيد
  @override
  DateTime? localStamp(Map<String, dynamic> item) {
    final v = box.get(JournalCache.key(
        company,
        (item['branch_code'] ?? '1').toString(),
        (item['serial'] ?? '').toString()));
    return v is Map ? StagedChanges.stamp(v['updated_at']) : null;
  }

  // يطبق عنصر اليومية المرحلي
  @override
  Future<void> apply(Map<String, dynamic> item) async {
    final serial = item['serial']?.toString() ?? '';
    final branch = (item['branch_code'] ?? '1').toString();
    if (serial.isEmpty) throw StateError('journal change without serial');
    if (item['action'] == 'delete' || item['is_deleted'] == true) {
      await JournalCache.delete(box,
          company: company, branch: branch, serial: serial);
      return;
    }
    final map = Map<String, dynamic>.from(item)..remove('action');
    map['is_deleted'] = false;
    await JournalCache.put(box, map, expectedCompany: company);
  }

  // يقرأ مؤشر اليومية المحفوظ
  @override
  Future<DateTime?> readCursor() async {
    final v = prefs.getString(cursorKey);
    return v == null ? null : DateTime.tryParse(v)?.toUtc();
  }

  // يكتب مؤشر اليومية
  @override
  Future<void> writeCursor(DateTime value) async {
    await prefs.setString(cursorKey, value.toIso8601String());
    await publishCursor(value);
  }
}

// صندوق وارد التغييرات المرحلية لكل الأقسام
class StagedInbox {
  static Future<void>? _ttInFlight;
  static Future<void>? _cdInFlight;
  static Future<void>? _emInFlight;
  static Future<void>? _spInFlight;
  static Future<void>? _slInFlight;
  static Future<void>? _ivInFlight;
  static final Map<String, Future<void>> _cmInFlight = {};
  static final Map<String, String> lastCommercialOutcome = {};

  /// Staged-batch key prefix and worker meta prefix per commercial feed kind.
  static const commercialPrefix = {
    'sales': 'c1',
    'returns': 'c2',
    'customer-payments': 'c3',
    'transfers': 'c4',
    'hr-attendance': 'c5',
    'hr-vacations': 'c6',
    'hr-adjustments': 'c7',
    'hr-settings': 'c8'
  };
  static String lastInventoryOutcome = '';
  static String lastSettlementOutcome = '';
  static String lastSupplierOutcome = '';
  static String lastEmployeesOutcome = '';
  static String lastCodingOutcome = '';
  static String lastTreasuryOutcome = '';

  // يحسب مفتاح النطاق الحالي للمستخدم والشركة
  /// Hash of everything that decides what this account may read.
  static String currentScopeKey(String uid, String company) {
    final p = PermissionsService();
    return StagedChanges.scopeKey(
      uid: uid,
      company: company,
      role: p.currentRole ?? '',
      branches: p.allowedBranches ?? const <String>[],
      permissionSignature: p.stagedPermissionSignature,
    );
  }

  /// Call before the daily incremental sync. Never throws.
  static Future<void>? _mergeInFlight;

  /// Short text of how the last merge ended (for the startup console line).
  static String lastOutcome = 'not run';

  // يعيد عدد الدفعات المرحلية للنطاق الحالي
  /// Staged batches for the current scope, from the startup prefetch. -1 = unknown (run the merge).
  static Future<int> peekStagedCount() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final company =
          (await CachePartitions.preferences()).getString('company_code');
      if (user == null || company == null) return -1;
      return await peekStagedCountFor(user.uid, company);
    } catch (_) {
      return -1;
    }
  }

  // يعيد عدد الدفعات المرحلية لمستخدم وشركة محددين
  /// Same peek with an explicit identity: usable at startup before the cache
  /// boxes finish opening (the staged store is a separate IndexedDB database).
  static Future<int> peekStagedCountFor(String uid, String company) async {
    try {
      return await jsStagedPeek(currentScopeKey(uid, company));
    } catch (_) {
      return -1;
    }
  }

  // يدمج دفعات اليومية
  static Future<void> mergeDaily(String companyCode,
      {bool eagerVerify = false}) {
    // Single flight: a concurrent second call would read the same batch before the first removes it.
    final running = _mergeInFlight;
    if (running != null) return running;
    final f = _mergeDailyOnce(companyCode, eagerVerify: eagerVerify)
        .whenComplete(() => _mergeInFlight = null);
    _mergeInFlight = f;
    return f;
  }

  // ينفذ دمج اليومية مرة واحدة
  static Future<void> _mergeDailyOnce(String companyCode,
      {bool eagerVerify = false}) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final prefs = await CachePartitions.preferences();
      final cursorKey = '${ApiConstants.LAST_SYNC_DAILY}$companyCode';
      final target = _DailyTarget(
          companyCode,
          CachePartitions.box('daily_transactions_box'),
          prefs,
          cursorKey,
          (c) => _publish(user, companyCode, key, c));
      final v2Key = '${cursorKey}_v2';
      // The server check runs IN PARALLEL with the local store read, so its latency hides behind
      // the (slower) IndexedDB open. It is only awaited before anything is shown.
      final Stopwatch swVerify = Stopwatch()..start();
      // eagerVerify is used only by the startup call; later calls verify only when something is staged.
      final String? storedScope = prefs.getString('${v2Key}scope');
      final Future<_FeedProbe>? verifyFuture =
          eagerVerify ? _probeDailyFeed(companyCode) : null;
      final Stopwatch swRead = Stopwatch()..start();
      final staged = await _WebStore().read(key);
      swRead.stop();
      // Nothing staged: nothing to show, so the verdict is not needed.
      if (staged.isEmpty) {
        lastOutcome = 'nothing staged';
        return;
      }
      // Staged rows were fetched while access was valid. Before they are shown the server has
      // been asked NOW (permission + read-scope fingerprint). Refused or changed scope: drop the
      // staging. Could not ask (offline/timeout): leave it staged and show nothing from it.
      // الباكند الجديد يرجع بصمة النطاق مع ملف الصلاحيات الموثق نفسه، فلا
      // حاجة لطلب منفصل. الباكند القديم: نتيجة الفحص المبكر لو بدأت، أو طلب الآن.
      final profileScope = PermissionsService().transactionsScopeFingerprint;
      final _Verdict verdict;
      if (profileScope != null) {
        // The fingerprint answers the check locally; an early probe that was
        // started before the profile arrived is stale now, so drop it.
        _earlyDailyProbe = null;
        verdict = (storedScope != null &&
                storedScope.isNotEmpty &&
                profileScope != storedScope)
            ? _Verdict.denied
            : _Verdict.ok;
      } else {
        final early = _earlyDailyProbe;
        _earlyDailyProbe = null;
        final probe =
            await (verifyFuture ?? early ?? _probeDailyFeed(companyCode));
        verdict = _probeVerdict(probe, storedScope);
      }
      swVerify.stop();
      if (verdict == _Verdict.unreachable) {
        debugPrint('📥 staged daily: not verified (offline), left staged');
        lastOutcome = 'verification not completed, data left staged';
        return;
      }
      if (verdict == _Verdict.denied) {
        await _WebStore().remove(key, staged.map((b) => b.id).toList());
        debugPrint('📥 staged daily: access or scope changed, staging dropped');
        lastOutcome = 'access or scope changed, staged data dropped';
        return;
      }
      // Snapshot taken AFTER the server verdict: an authorization epoch change that happened while
      // we waited must not make an otherwise valid merge fail halfway (rows applied, cursor not written).
      final Stopwatch swMerge = Stopwatch()..start();
      Future<StagedMergeReport> attempt() async {
        final scope = await ReadAuthorizationSnapshot.capture();
        final StagedMergeReport r;
        if (prefs.getString(v2Key) != null) {
          r = await StagedChanges.mergeV2(
            currentScopeKey: key,
            store: _WebStore(),
            target: target,
            currentFingerprint: prefs.getString('${v2Key}scope'),
            deletedStamp: (item) async {
              final led = JournalCache.readLedger(
                  prefs.getString(JournalCache.ledgerKey(companyCode)));
              final id = JournalCache.key(companyCode,
                  item['branch_code'].toString(), item['serial'].toString());
              final v = led[id];
              return v == null ? null : StagedChanges.stamp(v);
            },
            readCursor: () async => prefs.getString(v2Key),
            writeCursor: (c) async {
              await prefs.setString(v2Key, c);
              await _publish(user, companyCode, key,
                  DateTime.parse(prefs.getString(cursorKey)!).toUtc(),
                  v2: c, v2Scope: prefs.getString('${cursorKey}_v2scope'));
            },
            scopeStillCurrent: () => scope.isCurrent,
          );
        } else {
          r = await StagedChanges.merge(
            currentScopeKey: key,
            store: _WebStore(),
            target: target,
            scopeStillCurrent: () => scope.isCurrent,
          );
        }
        return r;
      }

      // Permissions can reload while the merge runs (the epoch moves). Applying is idempotent and the
      // cursor only moves after a whole batch, so if the SAME scope is still current, run it once more.
      var r = await attempt();
      for (var again = 0; again < 6 && r.failed; again++) {
        // Slow permission reconciliation moves the epoch more than once: let it settle between tries.
        await Future.delayed(Duration(milliseconds: 300 * (again + 1)));
        final nowKey = currentScopeKey(user.uid, companyCode);
        if (nowKey != key) break;
        debugPrint(
            '📥 staged daily: authorization epoch moved mid-merge, same scope, retrying (attempt $again: $r)');
        r = await attempt();
      }
      swMerge.stop();
      debugPrint('📥 staged daily: $r');
      lastOutcome = '$r';
      debugPrint(
          '⏱ staged merge timing: read=${swRead.elapsedMilliseconds}ms verify=${swVerify.elapsedMilliseconds}ms merge=${swMerge.elapsedMilliseconds}ms items=${staged.fold<int>(0, (a, b) => a + b.items.length)}');
    } catch (e) {
      lastOutcome = 'error: $e';
      debugPrint('staged daily merge skipped: $e');
    }
  }

  // ينشر بيانات النطاق بعد المزامنة
  /// Call after any successful daily sync so the worker knows where the app is.
  static Future<void> publishAfterSync(String companyCode) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final prefs = await CachePartitions.preferences();
      final c = prefs.getString('${ApiConstants.LAST_SYNC_DAILY}$companyCode');
      // A user without a daily cursor (no daily right, or daily never synced) still publishes the
      // scope so modules with their own checkpoint (coding, treasury) can stage. Daily staging
      // needs appCursor, which is then absent, and the worker skips it ("no-app-cursor").
      await _publish(user, companyCode, currentScopeKey(user.uid, companyCode),
          c == null ? null : DateTime.parse(c).toUtc(),
          v2: prefs
              .getString('${ApiConstants.LAST_SYNC_DAILY}${companyCode}_v2'),
          v2Scope: prefs.getString(
              '${ApiConstants.LAST_SYNC_DAILY}${companyCode}_v2scope'));
    } catch (e) {
      debugPrint('staged publish skipped: $e');
    }
  }

  /// Startup only: the daily freshness probe can start before the cache boxes
  /// finish opening (it needs only the company code), so its wait overlaps
  /// init. The scope comparison still happens at merge time, when the stored
  /// cursor scope is readable. Consumed once by the first mergeDaily that runs.
  static Future<_FeedProbe>? _earlyDailyProbe;

  // يبدأ فحص اليومية المبكر
  static void startEarlyDailyProbe(String companyCode) {
    _earlyDailyProbe ??= _probeDailyFeed(companyCode);
  }

  // يفحص حداثة خلاصة اليومية
  /// One freshness probe of the daily feed. status 0 = could not ask.
  static Future<_FeedProbe> _probeDailyFeed(String companyCode) async {
    try {
      final r = await AuthHttp.get(Uri.parse(
              '${ApiConstants.baseUrl}/transactions/changes-v2/$companyCode?cursor=latest'))
          .timeout(const Duration(seconds: 3));
      String? scope;
      if (r.statusCode == 200) {
        try {
          scope =
              (jsonDecode(r.body) as Map<String, dynamic>)['scope']?.toString();
        } catch (_) {}
      }
      return _FeedProbe(r.statusCode, scope);
    } catch (_) {
      return _FeedProbe(0, null);
    }
  }

  // يحدد حكم الفحص
  static _Verdict _probeVerdict(_FeedProbe probe, String? storedScope) {
    if (probe.status == 401 || probe.status == 403) return _Verdict.denied;
    if (probe.status != 200) return _Verdict.unreachable;
    final now = probe.scope ?? '';
    if (storedScope != null && storedScope.isNotEmpty && now != storedScope) {
      return _Verdict.denied;
    }
    return _Verdict.ok;
  }

  // يمسح دفعات الخزائن
  static Future<void> clearTreasury(String uid, String company) async {
    try {
      await jsStagedClearTreasury(uid, company);
    } catch (_) {}
  }

  // يمسح كل الدفعات المرحلية
  static Future<void> clear() async {
    try {
      await jsStagedClearAll();
    } catch (_) {}
  }

  // يمسح دفعات مستخدم وشركة ويؤكد الحذف
  /// Confirmed deletion of this account's access: drop staged bytes that belong to this
  /// uid + company only. Another account's staged scope is untouched.
  static Future<bool> clearFor(String uid, String company) async {
    try {
      return await jsStagedClearFor(uid, company);
    } catch (_) {
      return false;
    }
  }

  // يجهّز بيانات النطاق للموظفين
  static Future<Map<String, dynamic>> _employeesMeta(String company) async {
    final c = await EmployeeService().stagedCheckpoint(company);
    return c == null ? const {} : {'empCursor': c.cursor, 'empScope': c.scope};
  }

  // يجهّز بيانات النطاق للموردين
  static Future<Map<String, dynamic>> _supplierMeta(String company) async {
    final c = await SupplierService().stagedCheckpoint(company);
    return c == null ? const {} : {'supCursor': c.cursor, 'supScope': c.scope};
  }

  // يجهّز بيانات النطاق للمخزون
  static Future<Map<String, dynamic>> _inventoryMeta(String company) async {
    final c = await InventoryService().stagedCheckpoint(company);
    return c == null ? const {} : {'invCursor': c.cursor, 'invScope': c.scope};
  }

  // يجهّز بيانات النطاق للأقسام التجارية
  static Future<Map<String, dynamic>> _commercialMeta(String company) async {
    final out = <String, dynamic>{};
    for (final e in commercialPrefix.entries) {
      final dynamic svc =
          e.key.startsWith('hr-') ? HRService() : CommercialService();
      final c = await svc.stagedCheckpoint(e.key, company) as ({
        String cursor,
        String scope
      })?;
      if (c != null) {
        out['${e.value}Cursor'] = c.cursor;
        out['${e.value}Scope'] = c.scope;
      }
    }
    return out;
  }

  // يجهّز بيانات النطاق للتسويات
  static Future<Map<String, dynamic>> _settlementMeta(String company) async {
    final c = await SupplierSettlementService().stagedCheckpoint(company);
    return c == null ? const {} : {'setCursor': c.cursor, 'setScope': c.scope};
  }

  // يجهّز بيانات النطاق للترميز
  static Future<Map<String, dynamic>> _codingMeta(String company) async {
    final c = await CodingService().stagedCheckpoint(company);
    return c == null ? const {} : {'codCursor': c.cursor, 'codScope': c.scope};
  }

  // يجهّز بيانات النطاق للخزائن
  static Map<String, dynamic> _treasuryMeta(String company) {
    final c = TreasuryTransferService().stagedCheckpoint(company);
    return c == null ? const {} : {'ttCursor': c.cursor, 'ttScope': c.scope};
  }

  // يدمج دفعات الخزائن
  static Future<void> mergeTreasury(String companyCode) {
    final running = _ttInFlight;
    if (running != null) return running;
    final f =
        _mergeTreasuryOnce(companyCode).whenComplete(() => _ttInFlight = null);
    _ttInFlight = f;
    return f;
  }

  // يركّب خطاف نقطة تحقق الخزائن
  static void _installTreasuryHook() {
    TreasuryTransferService.onCheckpointChanged ??= (company) {
      unawaited(publishAfterSync(company));
    };
  }

  // ينفذ دمج الخزائن مرة واحدة
  static Future<void> _mergeTreasuryOnce(String companyCode) async {
    try {
      _installTreasuryHook();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final raw = jsonDecode(await jsStagedReadTreasury(key)) as List;
      if (raw.isEmpty) {
        lastTreasuryOutcome = 'nothing staged';
        debugPrint('📥 staged treasury: nothing staged');
        return;
      }
      var applied = 0, dropped = 0;
      final done = <String>[];
      // Apply in chain order by cursor continuity, not by key order: pick the batch that starts at
      // the stored checkpoint, apply it, and repeat. Whatever never connects is dropped.
      final pending = raw.whereType<Map>().toList();
      while (pending.isNotEmpty) {
        final cp = TreasuryTransferService().stagedCheckpoint(companyCode);
        final i = cp == null
            ? -1
            : pending.indexWhere((b) =>
                b['scopeKey'] == key &&
                b['fromCursor'] == cp.cursor &&
                b['fromScope'] == cp.scope);
        if (i < 0) break;
        final b = pending.removeAt(i);
        done.add(b['id']?.toString() ?? '');
        final ok = await TreasuryTransferService().applyStagedRecords(
            companyCode, b['response'],
            fromCursor: b['fromCursor'] as int,
            fromScope: b['fromScope'] as String);
        if (ok) {
          applied++;
        } else {
          dropped++;
          break;
        }
      }
      for (final b in pending) {
        dropped++;
        done.add(b['id']?.toString() ?? '');
      }
      await jsStagedRemoveTreasury(key, jsonEncode(done));
      lastTreasuryOutcome = 'applied $applied, dropped $dropped';
      debugPrint('📥 staged treasury: $lastTreasuryOutcome');
      if (applied > 0) await publishAfterSync(companyCode);
    } catch (e) {
      lastTreasuryOutcome = 'error: $e';
    }
  }

  // يدمج دفعات الترميز
  static Future<void> mergeCoding(String companyCode) {
    final running = _cdInFlight;
    if (running != null) return running;
    final f =
        _mergeCodingOnce(companyCode).whenComplete(() => _cdInFlight = null);
    _cdInFlight = f;
    return f;
  }

  // يدمج دفعات الموظفين
  static Future<void> mergeEmployees(String companyCode) {
    final running = _emInFlight;
    if (running != null) return running;
    final f =
        _mergeEmployeesOnce(companyCode).whenComplete(() => _emInFlight = null);
    _emInFlight = f;
    return f;
  }

  // يدمج دفعات الموردين
  static Future<void> mergeSupplier(String companyCode) {
    final running = _spInFlight;
    if (running != null) return running;
    final f = _mergeSupplierOnce(companyCode).whenComplete(() {
      _spInFlight = null;
      debugPrint('📥 staged supplier outcome: $lastSupplierOutcome');
    });
    _spInFlight = f;
    return f;
  }

  // يدمج دفعات المخزون
  static Future<void> mergeInventory(String companyCode) {
    final running = _ivInFlight;
    if (running != null) return running;
    final f = _mergeInventoryOnce(companyCode).whenComplete(() {
      _ivInFlight = null;
      debugPrint('📥 staged inventory outcome: $lastInventoryOutcome');
    });
    _ivInFlight = f;
    return f;
  }

  // يدمج دفعات التسويات
  static Future<void> mergeSettlement(String companyCode) {
    final running = _slInFlight;
    if (running != null) return running;
    final f = _mergeSettlementOnce(companyCode).whenComplete(() {
      _slInFlight = null;
      debugPrint('📥 staged settlement outcome: $lastSettlementOutcome');
    });
    _slInFlight = f;
    return f;
  }

  // يركّب كل الخطافات
  static void installHooks() {
    _installSupplierHook();
    _installSettlementHook();
    _installInventoryHook();
    _installCommercialHook();
    _installTreasuryHook();
    _installCodingHook();
    _installEmployeesHook();
  }

  // يركّب خطاف نقطة تحقق الترميز
  static void _installCodingHook() {
    CodingService.onCheckpointChanged ??= (company) {
      unawaited(publishAfterSync(company));
    };
  }

  // يركّب خطاف نقطة تحقق الموردين
  static void _installSupplierHook() {
    SupplierService.onCheckpointChanged ??= (company) {
      unawaited(publishAfterSync(company));
    };
  }

  // يركّب خطاف نقطة تحقق القسم التجاري
  static void _installCommercialHook() {
    CommercialService.onCheckpointChanged ??= (kind, company) {
      unawaited(publishAfterSync(company));
    };
    HRService.onCheckpointChanged ??= (kind, company) {
      unawaited(publishAfterSync(company));
    };
  }

  // يركّب خطاف نقطة تحقق المخزون
  static void _installInventoryHook() {
    InventoryService.onCheckpointChanged ??= (company) {
      unawaited(publishAfterSync(company));
    };
  }

  // يركّب خطاف نقطة تحقق التسويات
  static void _installSettlementHook() {
    SupplierSettlementService.onCheckpointChanged ??= (company) {
      unawaited(publishAfterSync(company));
    };
  }

  // يركّب خطاف نقطة تحقق الموظفين
  static void _installEmployeesHook() {
    EmployeeService.onCheckpointChanged ??= (company) {
      unawaited(publishAfterSync(company));
    };
  }

  // ينفذ دمج الترميز مرة واحدة
  static Future<void> _mergeCodingOnce(String companyCode) async {
    try {
      _installCodingHook();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final raw = jsonDecode(await jsStagedReadCoding(key)) as List;
      if (raw.isEmpty) {
        lastCodingOutcome = 'nothing staged';
        return;
      }
      final service = CodingService();
      final cp0 = await service.stagedCheckpoint(companyCode);
      final all = raw.whereType<Map>().toList();
      final ids = all.map((b) => b['id']?.toString() ?? '').toList();
      if (cp0 == null) {
        // No stored checkpoint (or no read right now): nothing can be shown from these.
        await jsStagedRemoveCoding(key, jsonEncode(ids));
        lastCodingOutcome = 'no checkpoint, staging dropped';
        return;
      }
      // Staged items were fetched while access was valid. Ask the server NOW (permission + what the
      // caller may read, including the cost right). Refused or changed: drop. Unreachable: leave staged.
      final verdict = await _verifyCoding(companyCode, cp0.scope);
      if (verdict == _Verdict.unreachable) {
        lastCodingOutcome = 'verification not completed, data left staged';
        return;
      }
      if (verdict == _Verdict.denied) {
        await jsStagedRemoveCoding(key, jsonEncode(ids));
        lastCodingOutcome = 'access or scope changed, staged data dropped';
        return;
      }
      var applied = 0, dropped = 0;
      final pending = [...all];
      while (pending.isNotEmpty) {
        final cp = await service.stagedCheckpoint(companyCode);
        final i = cp == null
            ? -1
            : pending.indexWhere((b) =>
                b['scopeKey'] == key &&
                b['fromCursor'] == cp.cursor &&
                b['fromScope'] == cp.scope);
        if (i < 0) break;
        final b = pending.removeAt(i);
        final ok = await service.applyStagedBatch(companyCode, b['response'],
            fromCursor: b['fromCursor'] as String,
            fromScope: b['fromScope'] as String);
        if (ok) {
          applied++;
        } else {
          dropped++;
          break;
        }
      }
      dropped += pending.length;
      await jsStagedRemoveCoding(key, jsonEncode(ids));
      lastCodingOutcome = 'applied $applied, dropped $dropped';
      debugPrint('📥 staged coding: $lastCodingOutcome');
    } catch (e) {
      lastCodingOutcome = 'error: $e';
    }
  }

  // يتحقق من الترميز مع الخادم
  static Future<_Verdict> _verifyCoding(
      String companyCode, String storedScope) async {
    try {
      final r = await AuthHttp.get(Uri.parse(
              '${ApiConstants.baseUrl}/coding/changes-v2/$companyCode?cursor=latest'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 401 || r.statusCode == 403) return _Verdict.denied;
      if (r.statusCode != 200) return _Verdict.unreachable;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      return (m['scope'] ?? '').toString() == storedScope
          ? _Verdict.ok
          : _Verdict.denied;
    } catch (_) {
      return _Verdict.unreachable;
    }
  }

  // يمسح دفعات الترميز
  static Future<void> clearCoding(String uid, String company) async {
    try {
      await jsStagedClearCoding(uid, company);
    } catch (_) {}
  }

  // ينفذ دمج الموظفين مرة واحدة
  static Future<void> _mergeEmployeesOnce(String companyCode) async {
    try {
      _installEmployeesHook();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final raw = jsonDecode(await jsStagedReadEmployees(key)) as List;
      if (raw.isEmpty) {
        lastEmployeesOutcome = 'nothing staged';
        return;
      }
      final service = EmployeeService();
      final cp0 = await service.stagedCheckpoint(companyCode);
      final all = raw.whereType<Map>().toList();
      final ids = all.map((b) => b['id']?.toString() ?? '').toList();
      if (cp0 == null) {
        // No stored checkpoint (or no read right now): nothing can be shown from these.
        await jsStagedRemoveEmployees(key, jsonEncode(ids));
        lastEmployeesOutcome = 'no checkpoint, staging dropped';
        return;
      }
      // Staged items were fetched while access was valid. Ask the server NOW (permission + what the
      // caller may read, including the cost right). Refused or changed: drop. Unreachable: leave staged.
      final verdict = await _verifyEmployees(companyCode, cp0.scope);
      if (verdict == _Verdict.unreachable) {
        lastEmployeesOutcome = 'verification not completed, data left staged';
        return;
      }
      if (verdict == _Verdict.denied) {
        await jsStagedRemoveEmployees(key, jsonEncode(ids));
        lastEmployeesOutcome = 'access or scope changed, staged data dropped';
        return;
      }
      var applied = 0, dropped = 0;
      final pending = [...all];
      while (pending.isNotEmpty) {
        final cp = await service.stagedCheckpoint(companyCode);
        final i = cp == null
            ? -1
            : pending.indexWhere((b) =>
                b['scopeKey'] == key &&
                b['fromCursor'] == cp.cursor &&
                b['fromScope'] == cp.scope);
        if (i < 0) break;
        final b = pending.removeAt(i);
        final ok = await service.applyStagedBatch(companyCode, b['response'],
            fromCursor: b['fromCursor'] as String,
            fromScope: b['fromScope'] as String);
        if (ok) {
          applied++;
        } else {
          dropped++;
          break;
        }
      }
      dropped += pending.length;
      await jsStagedRemoveEmployees(key, jsonEncode(ids));
      lastEmployeesOutcome = 'applied $applied, dropped $dropped';
      debugPrint('📥 staged employees: $lastEmployeesOutcome');
    } catch (e) {
      lastEmployeesOutcome = 'error: $e';
    }
  }

  // يتحقق من الموظفين مع الخادم
  static Future<_Verdict> _verifyEmployees(
      String companyCode, String storedScope) async {
    try {
      final r = await AuthHttp.get(Uri.parse(
              '${ApiConstants.baseUrl}/employees/changes-v2/$companyCode?cursor=latest'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 401 || r.statusCode == 403) return _Verdict.denied;
      if (r.statusCode != 200) return _Verdict.unreachable;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      return (m['scope'] ?? '').toString() == storedScope
          ? _Verdict.ok
          : _Verdict.denied;
    } catch (_) {
      return _Verdict.unreachable;
    }
  }

  // يمسح دفعات الموظفين
  static Future<void> clearEmployees(String uid, String company) async {
    try {
      await jsStagedClearEmployees(uid, company);
    } catch (_) {}
  }

  // ينفذ دمج الموردين مرة واحدة
  static Future<void> _mergeSupplierOnce(String companyCode) async {
    try {
      _installSupplierHook();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final raw = jsonDecode(await jsStagedReadSupplier(key)) as List;
      if (raw.isEmpty) {
        lastSupplierOutcome = 'nothing staged';
        return;
      }
      final service = SupplierService();
      final cp0 = await service.stagedCheckpoint(companyCode);
      final all = raw.whereType<Map>().toList();
      final ids = all.map((b) => b['id']?.toString() ?? '').toList();
      if (cp0 == null) {
        // No stored checkpoint (or no read right now): nothing can be shown from these.
        await jsStagedRemoveSupplier(key, jsonEncode(ids));
        lastSupplierOutcome = 'no checkpoint, staging dropped';
        return;
      }
      // Staged items were fetched while access was valid. Ask the server NOW (permission + what the
      // caller may read, including the cost right). Refused or changed: drop. Unreachable: leave staged.
      final verdict = await _verifySupplier(companyCode, cp0.scope);
      if (verdict == _Verdict.unreachable) {
        lastSupplierOutcome = 'verification not completed, data left staged';
        return;
      }
      if (verdict == _Verdict.denied) {
        await jsStagedRemoveSupplier(key, jsonEncode(ids));
        lastSupplierOutcome = 'access or scope changed, staged data dropped';
        return;
      }
      var applied = 0, dropped = 0;
      final pending = [...all];
      while (pending.isNotEmpty) {
        final cp = await service.stagedCheckpoint(companyCode);
        final i = cp == null
            ? -1
            : pending.indexWhere((b) =>
                b['scopeKey'] == key &&
                b['fromCursor'] == cp.cursor &&
                b['fromScope'] == cp.scope);
        if (i < 0) break;
        final b = pending.removeAt(i);
        final ok = await service.applyStagedBatch(companyCode, b['response'],
            fromCursor: b['fromCursor'] as String,
            fromScope: b['fromScope'] as String);
        if (ok) {
          applied++;
        } else {
          dropped++;
          break;
        }
      }
      dropped += pending.length;
      await jsStagedRemoveSupplier(key, jsonEncode(ids));
      lastSupplierOutcome = 'applied $applied, dropped $dropped';
      debugPrint('📥 staged supplier: $lastSupplierOutcome');
    } catch (e) {
      lastSupplierOutcome = 'error: $e';
    }
  }

  // يتحقق من الموردين مع الخادم
  static Future<_Verdict> _verifySupplier(
      String companyCode, String storedScope) async {
    try {
      final r = await AuthHttp.get(Uri.parse(
              '${ApiConstants.baseUrl}/supplier/changes-v2/$companyCode?cursor=latest'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 401 || r.statusCode == 403) return _Verdict.denied;
      if (r.statusCode != 200) return _Verdict.unreachable;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      return (m['scope'] ?? '').toString() == storedScope
          ? _Verdict.ok
          : _Verdict.denied;
    } catch (_) {
      return _Verdict.unreachable;
    }
  }

  // يمسح دفعات الموردين
  static Future<void> clearSupplier(String uid, String company) async {
    try {
      await jsStagedClearSupplier(uid, company);
    } catch (_) {}
  }

  // ينفذ دمج المخزون مرة واحدة
  static Future<void> _mergeInventoryOnce(String companyCode) async {
    try {
      _installInventoryHook();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final raw = jsonDecode(await jsStagedReadInventory(key)) as List;
      if (raw.isEmpty) {
        lastInventoryOutcome = 'nothing staged';
        return;
      }
      final service = InventoryService();
      final cp0 = await service.stagedCheckpoint(companyCode);
      final all = raw.whereType<Map>().toList();
      final ids = all.map((b) => b['id']?.toString() ?? '').toList();
      if (cp0 == null) {
        // No stored checkpoint (or no read right now): nothing can be shown from these.
        await jsStagedRemoveInventory(key, jsonEncode(ids));
        lastInventoryOutcome = 'no checkpoint, staging dropped';
        return;
      }
      // Staged items were fetched while access was valid. Ask the server NOW (permission + what the
      // caller may read, including the cost right). Refused or changed: drop. Unreachable: leave staged.
      final verdict = await _verifyInventory(companyCode, cp0.scope);
      if (verdict == _Verdict.unreachable) {
        lastInventoryOutcome = 'verification not completed, data left staged';
        return;
      }
      if (verdict == _Verdict.denied) {
        await jsStagedRemoveInventory(key, jsonEncode(ids));
        lastInventoryOutcome = 'access or scope changed, staged data dropped';
        return;
      }
      var applied = 0, dropped = 0;
      final pending = [...all];
      while (pending.isNotEmpty) {
        final cp = await service.stagedCheckpoint(companyCode);
        final i = cp == null
            ? -1
            : pending.indexWhere((b) =>
                b['scopeKey'] == key &&
                b['fromCursor'] == cp.cursor &&
                b['fromScope'] == cp.scope);
        if (i < 0) break;
        final b = pending.removeAt(i);
        final ok = await service.applyStagedBatch(companyCode, b['response'],
            fromCursor: b['fromCursor'] as String,
            fromScope: b['fromScope'] as String);
        if (ok) {
          applied++;
        } else {
          dropped++;
          break;
        }
      }
      dropped += pending.length;
      await jsStagedRemoveInventory(key, jsonEncode(ids));
      lastInventoryOutcome = 'applied $applied, dropped $dropped';
      debugPrint('📥 staged inventory: $lastInventoryOutcome');
    } catch (e) {
      lastInventoryOutcome = 'error: $e';
    }
  }

  // يتحقق من المخزون مع الخادم
  static Future<_Verdict> _verifyInventory(
      String companyCode, String storedScope) async {
    try {
      final r = await AuthHttp.get(Uri.parse(
              '${ApiConstants.baseUrl}/inventory/changes-v2/$companyCode?cursor=latest'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 401 || r.statusCode == 403) return _Verdict.denied;
      if (r.statusCode != 200) return _Verdict.unreachable;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      return (m['scope'] ?? '').toString() == storedScope
          ? _Verdict.ok
          : _Verdict.denied;
    } catch (_) {
      return _Verdict.unreachable;
    }
  }

  // يمسح دفعات المخزون
  static Future<void> clearInventory(String uid, String company) async {
    try {
      await jsStagedClearInventory(uid, company);
    } catch (_) {}
  }

  // يدمج دفعات قسم تجاري
  static Future<void> mergeCommercial(String kind, String companyCode) {
    final running = _cmInFlight[kind];
    if (running != null) return running;
    final f = _mergeCommercialOnce(kind, companyCode).whenComplete(() {
      _cmInFlight.remove(kind);
      debugPrint('📥 staged $kind outcome: ${lastCommercialOutcome[kind]}');
    });
    _cmInFlight[kind] = f;
    return f;
  }

  // يدمج دفعات كل الأقسام التجارية
  static Future<void> mergeAllCommercial(String companyCode) async {
    for (final kind in commercialPrefix.keys) {
      await mergeCommercial(kind, companyCode);
    }
  }

  // ينفذ دمج قسم تجاري مرة واحدة
  static Future<void> _mergeCommercialOnce(
      String kind, String companyCode) async {
    try {
      _installCommercialHook();
      final pfx = '${commercialPrefix[kind]}:';
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final raw = jsonDecode(await jsStagedReadCommercial(key, pfx)) as List;
      if (raw.isEmpty) {
        lastCommercialOutcome[kind] = 'nothing staged';
        return;
      }
      final dynamic service =
          kind.startsWith('hr-') ? HRService() : CommercialService();
      final cp0 = await service.stagedCheckpoint(kind, companyCode) as ({
        String cursor,
        String scope
      })?;
      final all = raw.whereType<Map>().toList();
      final ids = all.map((b) => b['id']?.toString() ?? '').toList();
      if (cp0 == null) {
        await jsStagedRemoveCommercial(key, pfx, jsonEncode(ids));
        lastCommercialOutcome[kind] = 'no checkpoint, staging dropped';
        return;
      }
      // Ask the server NOW (permission + the scope fingerprint). Refused or changed: drop. Unreachable: leave staged.
      final verdict = await _verifyCommercial(kind, companyCode, cp0.scope);
      if (verdict == _Verdict.unreachable) {
        lastCommercialOutcome[kind] =
            'verification not completed, data left staged';
        return;
      }
      if (verdict == _Verdict.denied) {
        await jsStagedRemoveCommercial(key, pfx, jsonEncode(ids));
        lastCommercialOutcome[kind] =
            'access or scope changed, staged data dropped';
        return;
      }
      var applied = 0, dropped = 0;
      final pending = [...all];
      while (pending.isNotEmpty) {
        final cp = await service.stagedCheckpoint(kind, companyCode);
        final i = cp == null
            ? -1
            : pending.indexWhere((b) =>
                b['scopeKey'] == key &&
                b['fromCursor'] == cp.cursor &&
                b['fromScope'] == cp.scope);
        if (i < 0) break;
        final b = pending.removeAt(i);
        final ok = await service.applyStagedBatch(
            kind, companyCode, b['response'],
            fromCursor: b['fromCursor'] as String,
            fromScope: b['fromScope'] as String);
        if (ok) {
          applied++;
        } else {
          dropped++;
          break;
        }
      }
      dropped += pending.length;
      await jsStagedRemoveCommercial(key, pfx, jsonEncode(ids));
      lastCommercialOutcome[kind] = 'applied $applied, dropped $dropped';
      debugPrint('📥 staged $kind: ${lastCommercialOutcome[kind]}');
    } catch (e) {
      lastCommercialOutcome[kind] = 'error: $e';
    }
  }

  // يتحقق من القسم التجاري مع الخادم
  static Future<_Verdict> _verifyCommercial(
      String kind, String companyCode, String storedScope) async {
    try {
      final url = kind.startsWith('hr-')
          ? '${ApiConstants.baseUrl}${HRService.routeFor(kind)}/changes-v2/$companyCode?cursor=latest'
          : '${ApiConstants.baseUrl}/commercial/$kind/changes-v2/$companyCode?cursor=latest';
      final r = await AuthHttp.get(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 401 || r.statusCode == 403) return _Verdict.denied;
      if (r.statusCode != 200) return _Verdict.unreachable;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      return (m['scope'] ?? '').toString() == storedScope
          ? _Verdict.ok
          : _Verdict.denied;
    } catch (_) {
      return _Verdict.unreachable;
    }
  }

  // يمسح دفعات قسم تجاري
  static Future<void> clearCommercial(
      String uid, String company, String kind) async {
    try {
      await jsStagedClearCommercial(uid, company, '${commercialPrefix[kind]}:');
    } catch (_) {}
  }

  // ينفذ دمج التسويات مرة واحدة
  static Future<void> _mergeSettlementOnce(String companyCode) async {
    try {
      _installSettlementHook();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final key = currentScopeKey(user.uid, companyCode);
      final raw = jsonDecode(await jsStagedReadSettlement(key)) as List;
      if (raw.isEmpty) {
        lastSettlementOutcome = 'nothing staged';
        return;
      }
      final service = SupplierSettlementService();
      final cp0 = await service.stagedCheckpoint(companyCode);
      final all = raw.whereType<Map>().toList();
      final ids = all.map((b) => b['id']?.toString() ?? '').toList();
      if (cp0 == null) {
        // No stored checkpoint (or no read right now): nothing can be shown from these.
        await jsStagedRemoveSettlement(key, jsonEncode(ids));
        lastSettlementOutcome = 'no checkpoint, staging dropped';
        return;
      }
      // Staged items were fetched while access was valid. Ask the server NOW (permission + what the
      // caller may read, including the cost right). Refused or changed: drop. Unreachable: leave staged.
      final verdict = await _verifySettlement(companyCode, cp0.scope);
      if (verdict == _Verdict.unreachable) {
        lastSettlementOutcome = 'verification not completed, data left staged';
        return;
      }
      if (verdict == _Verdict.denied) {
        await jsStagedRemoveSettlement(key, jsonEncode(ids));
        lastSettlementOutcome = 'access or scope changed, staged data dropped';
        return;
      }
      var applied = 0, dropped = 0;
      final pending = [...all];
      while (pending.isNotEmpty) {
        final cp = await service.stagedCheckpoint(companyCode);
        final i = cp == null
            ? -1
            : pending.indexWhere((b) =>
                b['scopeKey'] == key &&
                b['fromCursor'] == cp.cursor &&
                b['fromScope'] == cp.scope);
        if (i < 0) break;
        final b = pending.removeAt(i);
        final ok = await service.applyStagedBatch(companyCode, b['response'],
            fromCursor: b['fromCursor'] as String,
            fromScope: b['fromScope'] as String);
        if (ok) {
          applied++;
        } else {
          dropped++;
          break;
        }
      }
      dropped += pending.length;
      await jsStagedRemoveSettlement(key, jsonEncode(ids));
      lastSettlementOutcome = 'applied $applied, dropped $dropped';
      debugPrint('📥 staged settlement: $lastSettlementOutcome');
    } catch (e) {
      lastSettlementOutcome = 'error: $e';
    }
  }

  // يتحقق من التسويات مع الخادم
  static Future<_Verdict> _verifySettlement(
      String companyCode, String storedScope) async {
    try {
      final r = await AuthHttp.get(Uri.parse(
              '${ApiConstants.baseUrl}/supplier-settlement/changes-v2/$companyCode?cursor=latest'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 401 || r.statusCode == 403) return _Verdict.denied;
      if (r.statusCode != 200) return _Verdict.unreachable;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      return (m['scope'] ?? '').toString() == storedScope
          ? _Verdict.ok
          : _Verdict.denied;
    } catch (_) {
      return _Verdict.unreachable;
    }
  }

  // يمسح دفعات التسويات
  static Future<void> clearSettlement(String uid, String company) async {
    try {
      await jsStagedClearSettlement(uid, company);
    } catch (_) {}
  }

  // ينشر بيانات النطاق للـservice worker
  static Future<void> _publish(
      User user, String company, String key, DateTime? cursor,
      {String? v2, String? v2Scope}) async {
    final issuedAt = DateTime.now().millisecondsSinceEpoch;
    final t = await user.getIdTokenResult();
    final token = t.token;
    final exp = t.expirationTime;
    if (token == null || exp == null) return;
    await jsStagedPublish(jsonEncode({
      'scopeKey': key,
      'baseUrl': ApiConstants.baseUrl,
      'company': company,
      'token': token,
      'tokenExp': exp.millisecondsSinceEpoch,
      'issuedAt': issuedAt,
      'uid': user.uid,
      'apiKey': Firebase.app().options.apiKey,
      // The worker renews an expired ID token from the refresh token that Firebase
      // Auth itself keeps in IndexedDB. Emulator runs point it at the emulator.
      'refreshUrl': const bool.fromEnvironment('EMU')
          ? 'http://127.0.0.1:9099/securetoken.googleapis.com/v1/token'
          : 'https://securetoken.googleapis.com/v1/token',
      if (cursor != null) 'appCursor': cursor.toIso8601String(),
      ..._treasuryMeta(company),
      ...await _codingMeta(company),
      ...await _employeesMeta(company),
      ...await _supplierMeta(company),
      ...await _settlementMeta(company),
      ...await _inventoryMeta(company),
      ...await _commercialMeta(company),
      if (v2 != null) 'appCursorV2': v2,
      if (v2 != null) 'appScopeV2': v2Scope ?? '',
    }));
  }
}

// حكم الفحص: سليم أو مرفوض أو غير متاح
enum _Verdict { ok, denied, unreachable }

// نتيجة فحص حداثة خلاصة اليومية
/// Raw result of one daily-feed freshness probe. status 0 = could not ask.
class _FeedProbe {
  const _FeedProbe(this.status, this.scope);
  final int status;
  final String? scope;
}
