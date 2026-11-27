// frontend/lib/services/journal_import_batch.dart
import 'cache_partitions.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'journal_save_intent.dart';

// دفعة استيراد القيود: استرداد في المقدمة فقط
/// Foreground recovery only. A completed import is deliberately a new action
/// when selected again. This is not permanent duplicate-content prevention.
class JournalImportBatch {
  static const boxName = 'journal_import_batches_box';
  static final Map<String, Future<void>> _flights = {};
  final String ownerUid, companyCode, branchCode, fileHash, tabId;
  JournalImportBatch(
      {required this.ownerUid,
      required this.companyCode,
      required this.branchCode,
      required List<int> bytes,
      String? tabId})
      : fileHash = sha256.convert(bytes).toString(),
        tabId = tabId ?? JournalTabScope.current;

  // يعيد مفتاح الدفعة الحالية
  String get _key =>
      jsonEncode([tabId, ownerUid, companyCode, branchCode, fileHash]);

  // يفتح صندوق الدفعة
  Future<Box> _box() async => CachePartitions.isBoxOpen(boxName)
      ? CachePartitions.box(boxName)
      : await CachePartitions.openBox(boxName);

  // ينفذ الاستيراد ويمنع التكرار
  Future<void> run(
      {required List<Map<String, dynamic>> rows,
      required bool Function() stillAuthorized,
      required Future<Map<String, dynamic>> Function(
              JournalSaveIntent, JournalIntentStore)
          submit}) {
    final active = _flights[_key];
    if (active != null) return active;
    late Future<void> future;
    future = _run(rows, stillAuthorized, submit).whenComplete(() {
      if (identical(_flights[_key], future)) _flights.remove(_key);
    });
    return _flights[_key] = future;
  }

  // ينفذ دفعة الاستيراد الفعلية
  Future<void> _run(
      List<Map<String, dynamic>> rows,
      bool Function() allowed,
      Future<Map<String, dynamic>> Function(
              JournalSaveIntent, JournalIntentStore)
          submit) async {
    return CachePartitions.run(() async {
      void guard() {
        if (!allowed())
          throw StateError(
              'تغير الحساب أو صلاحية الاستيراد. المحاولة محفوظة لحسابها الأصلي.');
      }

      guard();
      final box = await _box();
      guard();
      var raw = box.get(_key);
      if (raw == null) {
        final intents = rows
            .map((row) => (JournalSaveIntent(
                    ownerUid: ownerUid,
                    companyCode: companyCode,
                    branchCode: branchCode,
                    serial: 0)
                  ..capture(row))
                .envelope())
            .toList();
        raw = {
          'version': 1,
          'batch_id': JournalSaveIntent.newId(),
          'next': 0,
          'intents': intents
        };
        await box.put(_key, raw);
        guard();
      }
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['batch_id'] is! String ||
          raw['intents'] is! List ||
          raw['next'] is! int) {
        throw StateError(
            'تعذر التحقق من الاستيراد السابق. لم يبدأ استيراد بديل.');
      }
      final intents = raw['intents'] as List;
      var next = raw['next'] as int;
      if (next < 0 || next > intents.length)
        throw StateError('حالة الاستيراد السابق غير صالحة');
      final store =
          JournalIntentStore(tabId: '$tabId:import:${raw['batch_id']}');
      while (next < intents.length) {
        guard();
        final intent = JournalSaveIntent.restore(intents[next],
            ownerUid: ownerUid,
            companyCode: companyCode,
            branchCode: branchCode,
            serial: 0);
        if (intent == null)
          throw StateError('تعذر استعادة صف الاستيراد الأصلي');
        final result = await submit(intent, store);
        guard();
        if (result['committed'] != true ||
            result['owner_changed'] == true ||
            result['intent_pending'] == true) {
          throw StateError(
              'لم يكتمل تأكيد صف الاستيراد. أعد اختيار نفس الملف لاستكمال المحاولة الأصلية.');
        }
        next++;
        raw = {...raw, 'next': next};
        await box.put(_key, raw);
      }
      guard();
      await box.delete(_key);
    });
  }
}
