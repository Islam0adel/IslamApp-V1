import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/work_pool.dart';

void main() {
  test('bounded worker pool overlaps work, keeps count and drains failures',
      () async {
    final pool = WorkPool(3), release = Completer<void>();
    var running = 0, peak = 0, started = 0;
    final jobs = List.generate(
        12,
        (i) => pool.run(() async {
              started++;
              running++;
              if (running > peak) peak = running;
              await release.future;
              running--;
              if (i == 2) throw StateError('synthetic');
              return i;
            }).then<Object>((v) => v, onError: (Object e) => e));
    await Future<void>.delayed(Duration.zero);
    expect(started, 3);
    expect(peak, 3);
    release.complete();
    final result = await Future.wait(jobs);
    expect(started, 12);
    expect(result.whereType<StateError>().length, 1);
    expect(pool.active, 0);
  });
  test('queued work retains originating zone rather than releasing worker zone',
      () async {
    final pool = WorkPool(1), gate = Completer<void>();
    final first =
        runZoned(() => pool.run(() => gate.future), zoneValues: {#owner: 'A'});
    final second = runZoned(() => pool.run(() async => Zone.current[#owner]),
        zoneValues: {#owner: 'B'});
    gate.complete();
    await first;
    expect(await second, 'B');
  });
  test('blocked companion does not block business but is joined at completion', () async {
    final admin = Completer<void>(), pulled = Completer<void>();
    var done = false;
    final run = awaitWithCompanion(admin.future, () async { pulled.complete(); })
        .then((_) { done = true; });
    await pulled.future; await Future<void>.delayed(Duration.zero);
    expect(done, false); admin.complete(); await run; expect(done, true);
  });
  test('business failure waits for companion and then propagates', () async {
    final admin = Completer<void>();var settled = false;
    final run = awaitWithCompanion(admin.future, () async { throw StateError('business'); })
        .then<Object>((_) => 'ok', onError: (Object e) {settled=true;return e;});
    await Future<void>.delayed(Duration.zero);expect(settled,false);
    admin.complete();expect(await run,isA<StateError>());
  });
}
