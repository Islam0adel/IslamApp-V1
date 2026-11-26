/// Cursor bootstrap for the commit-safe change feed, kept free of Flutter/Firebase so it can
/// be tested with failures injected.
///
/// Order matters: the cursor is taken BEFORE the full download and stored only AFTER the
/// download succeeded, so a failure at any point leaves the stored cursor untouched
/// (the next run bootstraps again) and rows committed during the download are re-delivered.
class V2CursorStore {
  V2CursorStore(this.get, this.set, this.remove, this.key);
  final String? Function(String) get;
  final Future<void> Function(String, String) set;
  final Future<void> Function(String) remove;
  final String key; // e.g. last_sync_daily_C1

  String get cursorKey => '${key}_v2';
  String get scopeKey => '${key}_v2scope';
}

class V2Bootstrap {
  /// [fetchLatest] returns "cursor|scope" or null (offline / refused).
  static Future<bool> run({
    required V2CursorStore store,
    required Future<String?> Function() fetchLatest,
    required Future<void> Function() fullSync,
  }) async {
    final latest = await fetchLatest();
    await fullSync(); // throws -> nothing stored
    if (latest == null) return false;
    final parts = latest.split('|');
    // scope first: a cursor without its scope would never be trusted by the next run
    await store.set(store.scopeKey, parts.length > 1 ? parts[1] : '');
    await store.set(store.cursorKey, parts[0]);
    return true;
  }

  static Future<void> clear(V2CursorStore store) async {
    await store.remove(store.cursorKey);
    await store.remove(store.scopeKey);
  }
}
