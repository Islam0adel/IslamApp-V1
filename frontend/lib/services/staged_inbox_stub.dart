import 'dart:convert';

/// Non-web builds have no service worker. This in-memory store mirrors the web page API closely
/// enough for VM tests of the purge and clear rules. In a non-web app nothing ever writes to it
/// except publish (which only records the scope), so staging stays effectively empty.
class StubStagedStore {
  static final Map<String, dynamic> batches = {};
  static Map<String, dynamic>? scope;
  static int clearedAt = 0;
  static void reset() {
    batches.clear();
    scope = null;
    clearedAt = 0;
  }
}

Future<bool> jsStagedPublish(String metaJson) async {
  final m = jsonDecode(metaJson) as Map<String, dynamic>;
  final issued = (m['issuedAt'] as int?) ?? 0;
  if (issued != 0 && StubStagedStore.clearedAt >= issued) return false;
  StubStagedStore.scope = m;
  final keep = m['scopeKey'];
  StubStagedStore.batches.removeWhere(
      (k, _) => !(k.startsWith('$keep|') || k.startsWith('tt:$keep|') || k.startsWith('cd:$keep|') || k.startsWith('em:$keep|')));
  return true;
}

Future<bool> jsStagedClearAll() async {
  StubStagedStore.scope = null;
  StubStagedStore.clearedAt = DateTime.now().millisecondsSinceEpoch;
  StubStagedStore.batches.clear();
  return true;
}

Future<bool> jsStagedClearFor(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return false;
  await jsStagedClearAll();
  return true;
}

Future<void> jsStagedClearTreasury(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('tt:'));
}

String _read(String prefix) {
  final keys = StubStagedStore.batches.keys.where((k) => k.startsWith(prefix)).toList()..sort();
  return jsonEncode([for (final k in keys) StubStagedStore.batches[k]]);
}

Future<String> jsStagedRead(String scopeKey) async => _read('$scopeKey|');
Future<void> jsStagedRemove(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('$scopeKey|$i');
  }
}

Future<int> jsStagedRecordFailure(String scopeKey, String id) async => 1;
Future<int> jsStagedPeek(String scopeKey) async => -1;
Future<String> jsStagedReadTreasury(String scopeKey) async => _read('tt:$scopeKey|');
Future<void> jsStagedRemoveTreasury(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('tt:$scopeKey|$i');
  }
}

Future<void> jsStagedClearCoding(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('cd:'));
}

Future<String> jsStagedReadCoding(String scopeKey) async => _read('cd:$scopeKey|');
Future<void> jsStagedRemoveCoding(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('cd:$scopeKey|$i');
  }
}

Future<void> jsStagedClearEmployees(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('em:'));
}

Future<String> jsStagedReadEmployees(String scopeKey) async => _read('em:$scopeKey|');
Future<void> jsStagedRemoveEmployees(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('em:$scopeKey|$i');
  }
}

Future<void> jsStagedClearSupplier(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('sp:'));
}

Future<String> jsStagedReadSupplier(String scopeKey) async => _read('sp:$scopeKey|');
Future<void> jsStagedRemoveSupplier(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('sp:$scopeKey|$i');
  }
}
Future<void> jsStagedClearSettlement(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('sl:'));
}

Future<String> jsStagedReadSettlement(String scopeKey) async => _read('sl:$scopeKey|');
Future<void> jsStagedRemoveSettlement(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('sl:$scopeKey|$i');
  }
}

Future<void> jsStagedClearInventory(String uid, String company) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith('iv:'));
}

Future<String> jsStagedReadInventory(String scopeKey) async => _read('iv:$scopeKey|');
Future<void> jsStagedRemoveInventory(String scopeKey, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('iv:$scopeKey|$i');
  }
}


Future<void> jsStagedClearCommercial(String uid, String company, String pfx) async {
  final sc = StubStagedStore.scope;
  if (sc != null && (sc['uid'] != uid || sc['company'] != company)) return;
  StubStagedStore.batches.removeWhere((k, _) => k.startsWith(pfx));
}

Future<String> jsStagedReadCommercial(String scopeKey, String pfx) async => _read('$pfx$scopeKey|');
Future<void> jsStagedRemoveCommercial(String scopeKey, String pfx, String idsJson) async {
  for (final i in jsonDecode(idsJson) as List) {
    StubStagedStore.batches.remove('$pfx$scopeKey|$i');
  }
}
