import 'dart:async';

/// FIFO bounded execution. The queued closure keeps its originating Zone.
class WorkPool {
  WorkPool(this.limit) {
    if (limit < 1) throw ArgumentError.value(limit);
  }
  final int limit;
  int active = 0;
  final _waiting = <Completer<void>>[];
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

/// A companion starts independently, but must settle before the whole run ends.
/// Business failures still drain the companion before propagating.
Future<void> awaitWithCompanion(
    Future<void> companion, Future<void> Function() business) async {
  // Attach the error handler now, even if business takes longer.
  Object? failure;
  StackTrace? trace;
  final settled = companion.then<void>((_) {}, onError: (Object e, StackTrace s) {
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
