// frontend/lib/services/staged_inbox_stub.dart
import 'dart:convert';

// مخزن مرحلي في الذاكرة للمنصات غير الويب
/// Non-web builds have no service worker. This in-memory store mirrors the web page API closely
/// enough for VM tests of the purge and clear rules. In a non-web app nothing ever writes to it
/// except publish (which only records the scope), so staging stays effectively empty.
class StubStagedStore {
  static final Map<String, dynamic> batches = {};
  static Map<String, dynamic>? scope;
  static int clearedAt = 0;

  // يفرغ المخزن
  static void reset() {
    batches.clear();
    scope = null;
    clearedAt = 0;
  }
}

// ينشر بيانات النطاق (بديل)
Future<bool> jsStagedPublish(String metaJson) async {
  final m = jsonDecode(metaJson) as Map<String, dynamic>;
  final issued = (m['issuedAt'] as int?) ?? 0;
  if (issued != 0 && StubStagedStore.clearedAt >= issued) return false;
  StubStagedStore.scope = m;
  final keep = m['scopeKey'];
  StubStagedStore.batches.removeWhere((k, _) => !(k.startsWith('$keep|') ||
      k.startsWith('tt:$keep|') ||
      k.startsWith('cd:$keep|') ||
      k.startsWith('em:$keep|')));
  return true;
}

// يمسح كل الدفعات (بديل)
Future<bool> jsStagedClearAll() async {
  StubStagedStore.scope = null;
  StubStagedStore.clearedAt = DateTime.now().millisecondsSinceEpoch;
  StubStagedStore.batches.clear();
  return true;
}

// يمسح دفعات مستخدم وشركة (بديل)
Future<bool> jsStagedClearFor(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company))
    return false;
  await jsStagedClearAll();
  return true;
}

// يمسح دفعات الخزائن (بديل)
Future<void> jsStagedClearTreasury(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('tt:'));
}

// يقرأ الدفعات بحسب البادئة
String _read(String prefix) {
  final keys = StubStagedStore.batches.keys
      .where((k) => k.startsWith(prefix))
      .toList()
    ..sort();
  return jsonEncode([for (final k in keys) StubStagedStore.batches[k]]);
}

// يقرأ دفعات اليومية (بديل)
Future<String> jsStagedRead(String scopeKey) async => _read('$scopeKey|');

// يزيل دفعات اليومية المحددة (بديل)
Future<void> jsStagedRemove(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('$scopeKey|$i');
  }
}

// يسجّل فشل دفعة (بديل)
Future<int> jsStagedRecordFailure(String scopeKey, String id) async => 1;

// يعيد عدد الدفعات المنتظرة (بديل)
Future<int> jsStagedPeek(String scopeKey) async => -1;

// يقرأ دفعات الخزائن (بديل)
Future<String> jsStagedReadTreasury(String scopeKey) async =>
    _read('tt:$scopeKey|');

// يزيل دفعات الخزائن المحددة (بديل)
Future<void> jsStagedRemoveTreasury(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('tt:$scopeKey|$i');
  }
}

// يمسح دفعات الترميز (بديل)
Future<void> jsStagedClearCoding(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('cd:'));
}

// يقرأ دفعات الترميز (بديل)
Future<String> jsStagedReadCoding(String scopeKey) async =>
    _read('cd:$scopeKey|');

// يزيل دفعات الترميز المحددة (بديل)
Future<void> jsStagedRemoveCoding(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('cd:$scopeKey|$i');
  }
}

// يمسح دفعات الموظفين (بديل)
Future<void> jsStagedClearEmployees(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('em:'));
}

// يقرأ دفعات الموظفين (بديل)
Future<String> jsStagedReadEmployees(String scopeKey) async =>
    _read('em:$scopeKey|');

// يزيل دفعات الموظفين المحددة (بديل)
Future<void> jsStagedRemoveEmployees(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('em:$scopeKey|$i');
  }
}

// يمسح دفعات الموردين (بديل)
Future<void> jsStagedClearSupplier(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('sp:'));
}

// يقرأ دفعات الموردين (بديل)
Future<String> jsStagedReadSupplier(String scopeKey) async =>
    _read('sp:$scopeKey|');

// يزيل دفعات الموردين المحددة
Future<void> jsStagedRemoveSupplier(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('sp:$scopeKey|$i');
  }
}

// يمسح دفعات التسويات
Future<void> jsStagedClearSettlement(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('sl:'));
}

// يقرأ دفعات التسويات
Future<String> jsStagedReadSettlement(String scopeKey) async =>
    _read('sl:$scopeKey|');

// يزيل دفعات التسويات المحددة
Future<void> jsStagedRemoveSettlement(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('sl:$scopeKey|$i');
  }
}

// يمسح دفعات المخزون
Future<void> jsStagedClearInventory(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('iv:'));
}

// يقرأ دفعات المخزون
Future<String> jsStagedReadInventory(String scopeKey) async =>
    _read('iv:$scopeKey|');

// يزيل دفعات المخزون المحددة
Future<void> jsStagedRemoveInventory(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('iv:$scopeKey|$i');
  }
}

// يمسح دفعات القسم التجاري
Future<void> jsStagedClearCommercial(
    String uid, String company, String pfx) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith(pfx));
}

// يقرأ دفعات القسم التجاري
Future<String> jsStagedReadCommercial(String scopeKey, String pfx) async =>
    _read('$pfx$scopeKey|');

// يزيل دفعات القسم التجاري المحددة
Future<void> jsStagedRemoveCommercial(
    String scopeKey, String pfx, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('$pfx$scopeKey|$i');
  }
}
