import 'dart:js_interop';

@JS('stagedSync.publish')
external JSPromise<JSAny?> _publish(JSString metaJson);
@JS('stagedSync.clearAll')
external JSPromise<JSAny?> _clearAll();
@JS('stagedSync.clearFor')
external JSPromise<JSAny?> _clearFor(JSString uid, JSString company);
@JS('stagedSync.readTreasury')
external JSPromise<JSString> _readTt(JSString scopeKey);
@JS('stagedSync.removeTreasury')
external JSPromise<JSAny?> _removeTt(JSString scopeKey, JSString idsJson);
@JS('stagedSync.clearTreasury')
external JSPromise<JSAny?> _clearTt(JSString uid, JSString company);
@JS('stagedSync.readCoding')
external JSPromise<JSString> _readCd(JSString scopeKey);
@JS('stagedSync.removeCoding')
external JSPromise<JSAny?> _removeCd(JSString scopeKey, JSString idsJson);
@JS('stagedSync.clearCoding')
external JSPromise<JSAny?> _clearCd(JSString uid, JSString company);
@JS('stagedSync.readEmployees')
external JSPromise<JSString> _readEm(JSString scopeKey);
@JS('stagedSync.removeEmployees')
external JSPromise<JSAny?> _removeEm(JSString scopeKey, JSString idsJson);
@JS('stagedSync.clearEmployees')
external JSPromise<JSAny?> _clearEm(JSString uid, JSString company);
@JS('stagedSync.readSupplier')
external JSPromise<JSString> _readSp(JSString scopeKey);
@JS('stagedSync.removeSupplier')
external JSPromise<JSAny?> _removeSp(JSString scopeKey, JSString idsJson);
@JS('stagedSync.clearSupplier')
external JSPromise<JSAny?> _clearSp(JSString uid, JSString company);
@JS('stagedSync.readSettlement')
external JSPromise<JSString> _readSl(JSString scopeKey);
@JS('stagedSync.removeSettlement')
external JSPromise<JSAny?> _removeSl(JSString scopeKey, JSString idsJson);
@JS('stagedSync.clearSettlement')
external JSPromise<JSAny?> _clearSl(JSString uid, JSString company);
@JS('stagedSync.readInventory')
external JSPromise<JSString> _readIv(JSString scopeKey);
@JS('stagedSync.removeInventory')
external JSPromise<JSAny?> _removeIv(JSString scopeKey, JSString idsJson);
@JS('stagedSync.clearInventory')
external JSPromise<JSAny?> _clearIv(JSString uid, JSString company);
@JS('stagedSync.readCommercial')
external JSPromise<JSString> _readCm(JSString scopeKey, JSString pfx);
@JS('stagedSync.removeCommercial')
external JSPromise<JSAny?> _removeCm(JSString scopeKey, JSString pfx, JSString idsJson);
@JS('stagedSync.clearCommercial')
external JSPromise<JSAny?> _clearCm(JSString uid, JSString company, JSString pfx);
@JS('stagedSync.read')
external JSPromise<JSString> _read(JSString scopeKey);
@JS('stagedSync.peekCount')
external JSPromise<JSNumber> _peek(JSString scopeKey);
@JS('stagedSync.remove')
external JSPromise<JSAny?> _remove(JSString scopeKey, JSString idsJson);
@JS('stagedSync.recordFailure')
external JSPromise<JSNumber> _fail(JSString scopeKey, JSString id);

Future<bool> jsStagedPublish(String metaJson) async {
  await _publish(metaJson.toJS).toDart;
  return true;
}

Future<bool> jsStagedClearAll() async {
  await _clearAll().toDart;
  return true;
}

Future<bool> jsStagedClearFor(String uid, String company) async {
  final r = await _clearFor(uid.toJS, company.toJS).toDart;
  return r != null && (r as JSBoolean).toDart;
}

Future<String> jsStagedRead(String scopeKey) async =>
    (await _read(scopeKey.toJS).toDart).toDart;
Future<void> jsStagedRemove(String scopeKey, String idsJson) async {
  await _remove(scopeKey.toJS, idsJson.toJS).toDart;
}

Future<int> jsStagedRecordFailure(String scopeKey, String id) async =>
    (await _fail(scopeKey.toJS, id.toJS).toDart).toDartInt;

/// Batches staged for [scopeKey] according to the startup prefetch; -1 = unknown.
Future<int> jsStagedPeek(String scopeKey) async =>
    (await _peek(scopeKey.toJS).toDart).toDartInt;

Future<String> jsStagedReadTreasury(String scopeKey) async =>
    (await _readTt(scopeKey.toJS).toDart).toDart;
Future<void> jsStagedRemoveTreasury(String scopeKey, String idsJson) async {
  await _removeTt(scopeKey.toJS, idsJson.toJS).toDart;
}

Future<void> jsStagedClearTreasury(String uid, String company) async {
  await _clearTt(uid.toJS, company.toJS).toDart;
}

Future<String> jsStagedReadCoding(String scopeKey) async =>
    (await _readCd(scopeKey.toJS).toDart).toDart;
Future<void> jsStagedRemoveCoding(String scopeKey, String idsJson) async {
  await _removeCd(scopeKey.toJS, idsJson.toJS).toDart;
}

Future<void> jsStagedClearCoding(String uid, String company) async {
  await _clearCd(uid.toJS, company.toJS).toDart;
}

Future<String> jsStagedReadEmployees(String scopeKey) async =>
    (await _readEm(scopeKey.toJS).toDart).toDart;
Future<void> jsStagedRemoveEmployees(String scopeKey, String idsJson) async {
  await _removeEm(scopeKey.toJS, idsJson.toJS).toDart;
}

Future<void> jsStagedClearEmployees(String uid, String company) async {
  await _clearEm(uid.toJS, company.toJS).toDart;
}

Future<String> jsStagedReadSupplier(String scopeKey) async =>
    (await _readSp(scopeKey.toJS).toDart).toDart;
Future<void> jsStagedRemoveSupplier(String scopeKey, String idsJson) async {
  await _removeSp(scopeKey.toJS, idsJson.toJS).toDart;
}

Future<void> jsStagedClearSupplier(String uid, String company) async {
  await _clearSp(uid.toJS, company.toJS).toDart;
}

Future<String> jsStagedReadSettlement(String scopeKey) async =>
    (await _readSl(scopeKey.toJS).toDart).toDart;
Future<void> jsStagedRemoveSettlement(String scopeKey, String idsJson) async {
  await _removeSl(scopeKey.toJS, idsJson.toJS).toDart;
}

Future<void> jsStagedClearSettlement(String uid, String company) async {
  await _clearSl(uid.toJS, company.toJS).toDart;
}

Future<String> jsStagedReadInventory(String scopeKey) async =>
    (await _readIv(scopeKey.toJS).toDart).toDart;
Future<void> jsStagedRemoveInventory(String scopeKey, String idsJson) async {
  await _removeIv(scopeKey.toJS, idsJson.toJS).toDart;
}

Future<void> jsStagedClearInventory(String uid, String company) async {
  await _clearIv(uid.toJS, company.toJS).toDart;
}



Future<String> jsStagedReadCommercial(String scopeKey, String pfx) async =>
    (await _readCm(scopeKey.toJS, pfx.toJS).toDart).toDart;
Future<void> jsStagedRemoveCommercial(String scopeKey, String pfx, String idsJson) async {
  await _removeCm(scopeKey.toJS, pfx.toJS, idsJson.toJS).toDart;
}

Future<void> jsStagedClearCommercial(String uid, String company, String pfx) async {
  await _clearCm(uid.toJS, company.toJS, pfx.toJS).toDart;
}
