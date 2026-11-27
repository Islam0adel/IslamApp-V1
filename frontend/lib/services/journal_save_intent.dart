// frontend/lib/services/journal_save_intent.dart
import 'cache_partitions.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:universal_html/html.dart' as html;

// نية حفظ قيد: عملية منطقية واحدة بمعرّف ثابت
/// One logical submission. A retry must keep its ID and immutable payload.
class JournalSaveIntent {
  final String ownerUid;
  final String companyCode;
  final String branchCode;
  final int serial;
  final String operationId;
  Map<String, dynamic>? _payload;

  // ينشئ نية حفظ جديدة بعد التحقق من بياناتها
  JournalSaveIntent(
      {required this.ownerUid,
      required this.companyCode,
      required this.branchCode,
      required this.serial,
      String? operationId})
      : operationId = operationId ?? newId() {
    if (ownerUid.isEmpty || companyCode.isEmpty || branchCode.isEmpty) {
      throw StateError(
          'A journal intention needs an authenticated owner and scope');
    }
  }

  // ينشئ معرّفًا عشوائيًا جديدًا
  static String newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex =
        bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  // يحوّل القيمة إلى صورة قياسية ثابتة
  static dynamic _canonical(dynamic value) {
    if (value is Map) {
      return SplayTreeMap<String, dynamic>.from(value
          .map((key, child) => MapEntry(key.toString(), _canonical(child))));
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  // ينسخ الخريطة نسخة عميقة
  static Map<String, dynamic> _copy(Map value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  // يحدد هل أُرسلت النية
  bool get submitted => _payload != null;

  // يعيد نسخة من الحمولة
  Map<String, dynamic>? get payload =>
      _payload == null ? null : _copy(_payload!);

  // يلتقط قيم القيد ويثبتها
  Map<String, dynamic> capture(Map<String, dynamic> values) {
    if (values['company_code'] != companyCode ||
        values['branch_code'] != branchCode ||
        values['serial'] != serial) {
      throw StateError('Journal intention scope mismatch');
    }
    final candidate = _copy({...values, 'operation_id': operationId});
    if (_payload != null &&
        jsonEncode(_canonical(_payload)) != jsonEncode(_canonical(candidate))) {
      throw StateError(
          'An unconfirmed journal intention cannot change its payload');
    }
    _payload ??= candidate;
    return payload!;
  }

  // يعيد غلاف النية للتخزين
  Map<String, dynamic> envelope() => {
        'version': 1,
        'owner_uid': ownerUid,
        'company_code': companyCode,
        'branch_code': branchCode,
        'serial': serial,
        'operation_id': operationId,
        'payload': payload,
      };

  // يستعيد النية من التخزين
  static JournalSaveIntent? restore(dynamic raw,
      {required String ownerUid,
      required String companyCode,
      required String branchCode,
      required int serial}) {
    if (ownerUid.isEmpty || companyCode.isEmpty || branchCode.isEmpty) {
      return null;
    }
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['owner_uid'] != ownerUid ||
        raw['company_code'] != companyCode ||
        raw['branch_code'] != branchCode ||
        raw['serial'] != serial ||
        raw['payload'] is! Map) return null;
    final id = raw['operation_id'];
    if (id is! String || id.length < 16 || id.length > 64) return null;
    final candidate = JournalSaveIntent(
        ownerUid: ownerUid,
        companyCode: companyCode,
        branchCode: branchCode,
        serial: serial,
        operationId: id);
    try {
      final values = Map<String, dynamic>.from(raw['payload'] as Map);
      if (values['operation_id'] != id) return null;
      candidate.capture(values);
    } catch (_) {
      return null;
    }
    return candidate;
  }
}

// نطاق تبويب القيد: يتيح استئناف المسودة بعد إعادة التحميل
/// A reload can resume this tab's draft; a newly opened/duplicated tab gets a
/// separate scope. No browser/session behavior is used as authentication.
class JournalTabScope {
  static String? _current;

  // يعيد معرّف التبويب الحالي
  static String get current {
    if (_current != null) return _current!;
    var id = JournalSaveIntent.newId();
    if (kIsWeb) {
      try {
        const key = 'islamapp.journal.tab.v1';
        final dynamic performance = html.window.performance;
        final old = html.window.sessionStorage[key];
        if (performance.navigation.type == 1 && old != null && old.length >= 16)
          id = old;
        html.window.sessionStorage[key] = id;
      } catch (_) {
        // If tab storage is unavailable, never merge unrelated intentions.
      }
    }
    return _current = id;
  }
}

// مخزن نوايا القيود: يُفتح عند الحاجة فقط
/// Open only when journal work needs it, not during application startup.
class JournalIntentStore {
  static const boxName = 'journal_save_intents_box';
  final String tabId;
  JournalIntentStore({String? tabId})
      : tabId = tabId ?? JournalTabScope.current;

  // يفتح صندوق النوايا
  Future<Box> _box() async => CachePartitions.isBoxOpen(boxName)
      ? CachePartitions.box(boxName)
      : await CachePartitions.openBox(boxName);

  // يبني مفتاح النية
  String _key(String owner, String company, String branch, int serial) =>
      jsonEncode([tabId, owner, company, branch, serial]);

  // يحمّل النية المحفوظة
  Future<JournalSaveIntent?> load(
      {required String ownerUid,
      required String companyCode,
      required String branchCode,
      required int serial}) async {
    return CachePartitions.run(() async {
      final raw =
          (await _box()).get(_key(ownerUid, companyCode, branchCode, serial));
      if (raw == null) return null;
      final intent = JournalSaveIntent.restore(raw,
          ownerUid: ownerUid,
          companyCode: companyCode,
          branchCode: branchCode,
          serial: serial);
      if (intent == null)
        throw StateError('Saved journal work requires reconciliation');
      return intent;
    });
  }

  // يحفظ النية
  Future<void> save(JournalSaveIntent intent) async {
    return CachePartitions.run(() async {
      if (!intent.submitted)
        throw StateError('No journal submission to preserve');
      final box = await _box();
      final key = _key(intent.ownerUid, intent.companyCode, intent.branchCode,
          intent.serial);
      final old = box.get(key);
      if (old != null &&
          (old is! Map || old['operation_id'] != intent.operationId)) {
        throw StateError(
            'Another unconfirmed journal intention occupies this form');
      }
      if (old != null) {
        final saved = JournalSaveIntent.restore(old,
            ownerUid: intent.ownerUid,
            companyCode: intent.companyCode,
            branchCode: intent.branchCode,
            serial: intent.serial);
        if (saved == null ||
            jsonEncode(JournalSaveIntent._canonical(saved.payload)) !=
                jsonEncode(JournalSaveIntent._canonical(intent.payload))) {
          throw StateError('Unconfirmed journal payload cannot be replaced');
        }
      }
      await box.put(key, intent.envelope());
    });
  }

  // يؤكد استلام النية ويزيلها
  Future<void> acknowledge(JournalSaveIntent intent) async {
    return CachePartitions.run(() async {
      final box = await _box();
      final key = _key(intent.ownerUid, intent.companyCode, intent.branchCode,
          intent.serial);
      final old = box.get(key);
      if (old is Map &&
          old['owner_uid'] == intent.ownerUid &&
          old['operation_id'] == intent.operationId) {
        await box.delete(key);
      }
    });
  }
}
