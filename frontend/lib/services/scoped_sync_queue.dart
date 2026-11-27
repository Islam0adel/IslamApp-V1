// frontend/lib/services/scoped_sync_queue.dart
// طابور المزامنة المحدودة النطاق
/// Holds scope invalidation until the old data run has settled. Coalesces
/// same-company modules but never silently drops a later request.
class ScopedSyncQueue {
  ScopedSyncQueue({required this.waitForData, required this.reconcile});
  final Future<void> Function() waitForData;
  final Future<void> Function(String, Set<String>) reconcile;
  final Map<String, Set<String>> _pending = {};
  Future<void>? _work;

  // يضيف وحدات للمزامنة في الطابور
  Future<void> add(String company, Set<String> modules) {
    if (modules.isEmpty) return _work ?? Future<void>.value();
    _pending.putIfAbsent(company, () => {}).addAll(modules);
    return _work ??= _drain().whenComplete(() => _work = null);
  }

  // يفرغ الطابور بالتتابع
  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      await waitForData();
      final company = _pending.keys.first;
      final modules = _pending.remove(company)!;
      await reconcile(company, modules);
    }
  }
}
