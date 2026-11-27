// frontend/lib/services/work_pool.dart
import 'dart:async';

// مجمع أعمال محدود يعمل بالدور
/// FIFO bounded execution. The queued closure keeps its originating Zone.
class WorkPool {
  // ينشئ المجمع بالحد الأقصى للتنفيذ المتزامن
  WorkPool(this.limit) {
    if (limit < 1) throw ArgumentError.value(limit);
  }
  final int limit;
  int active = 0;
  final _waiting = <Completer<void>>[];

  // ينفذ عملًا ضمن حدود المجمع
  Future<T> run<T>(Future<T> Function() work) async {
    if (active >= limit) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      active++;
    }
    try {
      return await work();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        active--;
      }
    }
  }
}

// ينتظر عملًا مع عمل مرافق
/// A companion starts independently, but must settle before the whole run ends.
/// Business failures still drain the companion before propagating.
Future<void> awaitWithCompanion(
    Future<void> companion, Future<void> Function() business) async {
  // Attach the error handler now, even if business takes longer.
  Object? failure;
  StackTrace? trace;
  final settled =
      companion.then<void>((_) {}, onError: (Object e, StackTrace s) {
    failure = e;
    trace = s;
  });
  try {
    await business();
  } finally {
    await settled;
  }
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
}
