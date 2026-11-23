import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/scoped_sync_queue.dart';

void main() {
  test(
      'in-flight incremental run settles before invalidation, later modules not reset mid-batch',
      () async {
    final coding = Completer<void>(), events = <String>[];
    var running = true;
    final queue = ScopedSyncQueue(waitForData: () async {
      events.add('wait');
      if (running) await coding.future;
    }, reconcile: (company, modules) async {
      events.add('invalidate:$company:${modules.join(',')}');
    });
    final first = queue.add('C1', {'sales'});
    queue.add('C1', {'returns'});
    await Future<void>.delayed(Duration.zero);
    expect(events, ['wait']);
    events.add('old-all-batches-finished');
    running = false;
    coding.complete();
    await first;
    expect(events,
        ['wait', 'old-all-batches-finished', 'invalidate:C1:sales,returns']);
  });
  test(
      'scope request arriving during reconciliation runs afterward, never ignored',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    final runs = <Set<String>>[];
    final queue = ScopedSyncQueue(
        waitForData: () async {},
        reconcile: (c, m) async {
          runs.add(m);
          if (runs.length == 1) {
            entered.complete();
            await release.future;
          }
        });
    final first = queue.add('C1', {'sales'});
    await entered.future;
    final second = queue.add('C1', {'hr'});
    release.complete();
    await first;
    await second;
    expect(runs, [
      {'sales'},
      {'hr'}
    ]);
  });
}
