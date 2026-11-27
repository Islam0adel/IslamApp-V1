// frontend/lib/services/staged_changes.dart
//
// Merges changes that the service worker downloaded while the app was closed.
// The worker never writes to Hive. It only stores batches in its own store.
// This file decides, batch by batch, what is safe to merge and when the
// incremental-sync cursor may move.

import 'dart:convert';
import 'package:crypto/crypto.dart';

// دفعة مرحلية واحدة نزّلها الـservice worker لنطاق واحد
/// One download made by the service worker for one scope.
class StagedBatch {
  StagedBatch({
    required this.id,
    required this.scopeKey,
    required this.sinceUsed,
    required this.to,
    required this.items,
    this.fromCursor,
    this.toCursor,
    this.fingerprint,
  });

  /// Read-scope fingerprint the batch was fetched under (company + allowed branches).
  final String? fingerprint;

  /// Commit-safe feed cursors ("tx:id") when the batch came from /changes-v2.
  final String? fromCursor;
  final String? toCursor;

  /// Unique, increasing per scope.
  final String id;

  /// Hash of account + company + role + branches + permission signature.
  final String scopeKey;

  /// The `since` value the worker really sent to the server (overlap included).
  final DateTime sinceUsed;

  /// Highest `updated_at` the batch contains (or [sinceUsed] when empty).
  final DateTime to;
  final List<Map<String, dynamic>> items;

  // ينشئ كائنًا من بيانات JSON
  factory StagedBatch.fromJson(Map<String, dynamic> j) => StagedBatch(
        id: j['id'].toString(),
        scopeKey: j['scopeKey'].toString(),
        sinceUsed: j['sinceUsed'] == null
            ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
            : DateTime.parse(j['sinceUsed'].toString()).toUtc(),
        to: j['to'] == null
            ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
            : DateTime.parse(j['to'].toString()).toUtc(),
        fromCursor: j['fromCursor']?.toString(),
        toCursor: j['toCursor']?.toString(),
        fingerprint: j['fingerprint']?.toString(),
        items: (j['items'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );
}

// واجهة مخزن الدفعات المرحلية
abstract class StagedStore {
  /// Batches of exactly this scope, oldest first.
  Future<List<StagedBatch>> read(String scopeKey);
  Future<void> remove(String scopeKey, List<String> batchIds);

  /// Counts a failed merge attempt of one batch and returns the new total.
  Future<int> recordFailure(String scopeKey, String batchId);
}

// واجهة هدف دمج الدفعات المرحلية
abstract class StagedTarget {
  /// Local `updated_at` of the record the item would replace, if any.
  DateTime? localStamp(Map<String, dynamic> item);
  Future<void> apply(Map<String, dynamic> item);
  Future<DateTime?> readCursor();

  /// Must also publish the cursor where the worker can read it.
  Future<void> writeCursor(DateTime value);
}

// تقرير نتيجة دمج الدفعات المرحلية
class StagedMergeReport {
  StagedMergeReport({
    this.batchesMerged = 0,
    this.itemsApplied = 0,
    this.itemsSkippedStale = 0,
    this.batchesDiscarded = 0,
    this.stoppedAtGap = false,
    this.failed = false,
  });
  int batchesMerged, itemsApplied, itemsSkippedStale, batchesDiscarded;
  int itemsAlreadyCurrent = 0;
  bool stoppedAtGap, failed, poisonDropped = false;

  // يعيد وصف التقرير نصًا
  @override
  String toString() =>
      'merged=$batchesMerged applied=$itemsApplied same=$itemsAlreadyCurrent stale=$itemsSkippedStale '
      'discarded=$batchesDiscarded gap=$stoppedAtGap failed=$failed';
}

// فئة دمج التغييرات المرحلية
class StagedChanges {
  // يبني مفتاح النطاق
  static String scopeKey({
    required String uid,
    required String company,
    required String role,
    required Iterable<String> branches,
    required String permissionSignature,
  }) {
    final sorted = branches.toList()..sort();
    return sha256
        .convert(utf8.encode(
            jsonEncode([uid, company, role, sorted, permissionSignature])))
        .toString();
  }

  // يحوّل ختم الوقت إلى تاريخ
  /// The backend writes updated_at as UTC without a zone suffix. DateTime.parse
  /// would treat that as local time (wrong by hours in Cairo), so no suffix = UTC.
  static DateTime? stamp(Object? v) {
    if (v == null) return null;
    final text = v.toString();
    final hasZone = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(text);
    return DateTime.tryParse(hasZone ? text : '${text}Z')?.toUtc();
  }

  // يدمج الدفعات المرحلية المحفوظة
  /// Safe to call at every open. Anything unclear is left to the normal
  /// incremental sync, which stays authoritative.
  static Future<StagedMergeReport> merge({
    required String currentScopeKey,
    required StagedStore store,
    required StagedTarget target,
    required bool Function() scopeStillCurrent,
    String? currentFingerprint,
    Future<DateTime?> Function(Map<String, dynamic> item)? deletedStamp,
    int maxAttempts = 3,
  }) async {
    final report = StagedMergeReport();
    final batches = await store.read(currentScopeKey);
    if (batches.isEmpty) return report;
    var cursor = await target.readCursor();
    if (cursor == null) {
      // Never fully synced here: a full download is needed first.
      await store.remove(currentScopeKey, batches.map((b) => b.id).toList());
      report.batchesDiscarded = batches.length;
      return report;
    }
    final done = <String>[];
    for (final batch in batches) {
      if (batch.scopeKey != currentScopeKey) continue; // defensive
      if (!scopeStillCurrent()) {
        report.failed = true;
        break;
      }
      if (!batch.to.isAfter(cursor!) && !batch.sinceUsed.isAfter(cursor)) {
        // Already covered by a sync that ran after it was downloaded.
        done.add(batch.id);
        report.batchesDiscarded++;
        continue;
      }
      if (batch.sinceUsed.isAfter(cursor)) {
        // A hole between what the app has and what this batch starts at.
        // Do not skip it. Drop staging and let the incremental sync cover it.
        report.stoppedAtGap = true;
        done.addAll(batches.map((b) => b.id));
        break;
      }
      try {
        for (final item in batch.items) {
          if (!scopeStillCurrent()) throw StateError('scope changed');
          final incoming = stamp(item['updated_at']);
          final local = target.localStamp(item);
          if (incoming != null && local != null && local.isAfter(incoming)) {
            report.itemsSkippedStale++;
            continue;
          }
          await target.apply(item);
          report.itemsApplied++;
        }
        if (!scopeStillCurrent()) throw StateError('scope changed');
        // Cursor moves only after the whole batch is in Hive.
        if (batch.to.isAfter(cursor)) {
          await target.writeCursor(batch.to);
          cursor = batch.to;
        }
        done.add(batch.id);
        report.batchesMerged++;
      } catch (_) {
        // Batch stays in staging, cursor untouched. Re-merge is idempotent.
        report.failed = true;
        if (scopeStillCurrent()) {
          final tries = await store.recordFailure(currentScopeKey, batch.id);
          if (tries >= maxAttempts) {
            // Poison batch: stop retrying. The normal incremental sync from the
            // untouched cursor downloads these changes instead.
            done.addAll(batches.map((b) => b.id));
            report.poisonDropped = true;
          }
        }
        break;
      }
    }
    // A batch in `done` is fully applied and its cursor is written, so removing it is safe even if
    // the scope moved afterwards. Keeping it would only be discarded at the next open.
    if (done.isNotEmpty) {
      await store.remove(currentScopeKey, done);
    }
    return report;
  }

  // يحلل المؤشر إلى زوج قابل للمقارنة
  /// "tx:id" -> comparable pair, null when malformed.
  static List<BigInt>? parseCursor(String? c) {
    if (c == null) return null;
    final p = c.split(':');
    if (p.length != 2) return null;
    final a = BigInt.tryParse(p[0]), b = BigInt.tryParse(p[1]);
    return (a == null || b == null) ? null : [a, b];
  }

  // يقارن مؤشرين
  static int compareCursor(List<BigInt> x, List<BigInt> y) {
    final c = x[0].compareTo(y[0]);
    return c != 0 ? c : x[1].compareTo(y[1]);
  }

  // يدمج الدفعات المرحلية للنسخة الثانية من الخلاصة
  /// Merge for the commit-safe feed. Same safety rules as [merge]: contiguity (a batch must
  /// start at the app cursor), cursor moves only after a whole batch is applied, stale guard,
  /// scope checks, poison batch drop. Anything unclear is left to the normal sync.
  static Future<StagedMergeReport> mergeV2({
    required String currentScopeKey,
    required StagedStore store,
    required StagedTarget target,
    required Future<String?> Function() readCursor,
    required Future<void> Function(String) writeCursor,
    required bool Function() scopeStillCurrent,
    String? currentFingerprint,
    Future<DateTime?> Function(Map<String, dynamic> item)? deletedStamp,
    DateTime? now,
    Duration maxBatchAge = const Duration(days: 7),
    int maxAttempts = 3,
  }) async {
    final report = StagedMergeReport();
    final batches = (await store.read(currentScopeKey))
        .where((b) => b.toCursor != null)
        .toList();
    if (batches.isEmpty) return report;
    var cursorStr = await readCursor();
    var cursor = parseCursor(cursorStr);
    if (cursor == null) {
      await store.remove(currentScopeKey, batches.map((b) => b.id).toList());
      report.batchesDiscarded = batches.length;
      return report;
    }
    final done = <String>[];
    for (final batch in batches) {
      if (batch.scopeKey != currentScopeKey) continue;
      if (!scopeStillCurrent()) {
        report.failed = true;
        break;
      }
      // Batches older than maxBatchAge are not trusted (the delete ledger only covers 14 days).
      final ms = batch.id.contains('-')
          ? int.tryParse(batch.id.split('-').first)
          : null;
      if (ms != null &&
          (now ?? DateTime.now()).toUtc().difference(
                  DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)) >
              maxBatchAge) {
        done.add(batch.id);
        report.batchesDiscarded++;
        continue;
      }
      if (currentFingerprint != null &&
          currentFingerprint.isNotEmpty &&
          batch.fingerprint != currentFingerprint) {
        done.add(batch.id);
        report.batchesDiscarded++;
        continue;
      }
      final to = parseCursor(batch.toCursor);
      final from = parseCursor(batch.fromCursor);
      if (to == null || from == null) {
        done.add(batch.id);
        report.batchesDiscarded++;
        continue;
      }
      if (compareCursor(to, cursor!) <= 0) {
        done.add(batch.id);
        report.batchesDiscarded++;
        continue;
      }
      if (compareCursor(from, cursor) > 0) {
        report.stoppedAtGap = true;
        done.addAll(batches.map((b) => b.id));
        break;
      }
      try {
        for (final item in batch.items) {
          if (!scopeStillCurrent()) throw StateError('scope changed');
          final incoming = stamp(item['updated_at']);
          final local = target.localStamp(item);
          if (incoming != null && local != null && local.isAfter(incoming)) {
            report.itemsSkippedStale++;
            continue;
          }
          // Same version already stored (an earlier attempt applied it): do not write it again.
          if (item['action'] != 'delete' &&
              incoming != null &&
              local != null &&
              local == incoming) {
            report.itemsAlreadyCurrent++;
            continue;
          }
          if (item['action'] != 'delete' &&
              deletedStamp != null &&
              incoming != null) {
            final ds = await deletedStamp(item);
            if (ds != null && !incoming.isAfter(ds)) {
              report.itemsSkippedStale++;
              continue;
            }
          }
          await target.apply(item);
          report.itemsApplied++;
        }
        if (!scopeStillCurrent()) throw StateError('scope changed');
        await writeCursor(batch.toCursor!);
        cursor = to;
        done.add(batch.id);
        report.batchesMerged++;
      } catch (_) {
        report.failed = true;
        if (scopeStillCurrent()) {
          final tries = await store.recordFailure(currentScopeKey, batch.id);
          if (tries >= maxAttempts) {
            done.addAll(batches.map((b) => b.id));
            report.poisonDropped = true;
          }
        }
        break;
      }
    }
    // A batch in `done` is fully applied and its cursor is written, so removing it is safe even if
    // the scope moved afterwards. Keeping it would only be discarded at the next open.
    if (done.isNotEmpty) {
      await store.remove(currentScopeKey, done);
    }
    return report;
  }
}

// نتيجة التحقق من الخادم: مسموح أو مرفوض أو غير متاح
/// Result of the server check that decides whether staged rows may stay visible.
enum StagedVerdict { allowed, denied, unreachable }

// تقرير نتيجة الدمج مع التحقق اللاحق
/// Outcome of [StagedChanges.mergeShowThenVerify] (experiment mode "b").
class ShowThenVerifyReport {
  ShowThenVerifyReport(this.merge, this.verdict, {this.rolledBack = 0});
  final StagedMergeReport merge;
  final StagedVerdict verdict;

  /// Rows removed or restored because the verdict was [StagedVerdict.denied].
  final int rolledBack;
}

// هدف دمج يسجّل تراجعًا لكل تغيير
class _UndoTarget implements StagedTarget {
  _UndoTarget(this.inner, this.capture);
  final StagedTarget inner;
  final Future<Future<void> Function()> Function(Map<String, dynamic> item)
      capture;
  final List<Future<void> Function()> undo = [];

  // يعيد ختم الوقت المحلي للعنصر
  @override
  DateTime? localStamp(Map<String, dynamic> item) => inner.localStamp(item);

  // يطبق العنصر ويسجّل نسخة للتراجع
  @override
  Future<void> apply(Map<String, dynamic> item) async {
    undo.add(await capture(item));
    await inner.apply(item);
  }

  // يقرأ المؤشر المحفوظ
  @override
  Future<DateTime?> readCursor() => inner.readCursor();

  // يكتب المؤشر
  @override
  Future<void> writeCursor(DateTime v) => inner.writeCursor(v);
}

// فئة الدمج ثم التحقق التجريبية
class StagedShowThenVerify {
  // تشغّل الدمج ثم التحقق التجريبي
  /// EXPERIMENT (mode b): merge per the last saved permissions first, then ask the server.
  /// Denied: every row this merge applied is restored or removed and the cursor goes back.
  /// Unreachable: rows stay shown and are reported unverified. Not used by the app.
  static Future<ShowThenVerifyReport> run({
    required String currentScopeKey,
    required StagedStore store,
    required StagedTarget target,
    required Future<String?> Function() readCursor,
    required Future<void> Function(String) writeCursor,
    required bool Function() scopeStillCurrent,
    required Future<Future<void> Function()> Function(Map<String, dynamic> item)
        capture,
    required Future<StagedVerdict> Function() verify,
    void Function()? onShown,
    String? currentFingerprint,
  }) async {
    final cursorBefore = await readCursor();
    final wrapped = _UndoTarget(target, capture);
    final r = await StagedChanges.mergeV2(
      currentScopeKey: currentScopeKey,
      store: store,
      target: wrapped,
      readCursor: readCursor,
      writeCursor: writeCursor,
      scopeStillCurrent: scopeStillCurrent,
      currentFingerprint: currentFingerprint,
    );
    onShown?.call();
    final v = await verify();
    var n = 0;
    if (v == StagedVerdict.denied) {
      for (final u in wrapped.undo.reversed) {
        await u();
        n++;
      }
      if (cursorBefore != null) await writeCursor(cursorBefore);
    }
    return ShowThenVerifyReport(r, v, rolledBack: n);
  }
}
