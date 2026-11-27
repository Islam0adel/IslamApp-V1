// frontend/lib/services/refresh_barrier.dart
import 'dart:async';

// حاجز التحديث: يعد المهام الجارية حتى تنتهي كلها
/// Counts every running task from its first synchronous line, so a waiter sees tasks that
/// were called but have not yet registered anywhere else. Does not decide anything about access.
class RefreshBarrier {
  int _active = 0;
  Completer<void>? _idle;

  // يعيد عدد المهام الجارية
  int get active => _active;

  // ينفذ مهمة ويحتسبها ضمن الجارية
  Future<T> run<T>(Future<T> Function() task) async {
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_active == 0) {
        final c = _idle;
        _idle = null;
        if (c != null && !c.isCompleted) c.complete();
      }
    }
  }

  // ينتظر حتى لا تبقى أي مهمة جارية
  /// Completes when nothing is running. Tasks started while waiting are waited for too.
  Future<void> whenIdle() async {
    while (_active > 0) {
      await (_idle ??= Completer<void>()).future;
    }
  }
}
