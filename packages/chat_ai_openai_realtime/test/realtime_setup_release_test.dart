// The resource coordinator's ownership discipline (corrective regressions
// 3 and 4): concurrent cleanup triggers share one actual cleanup and both
// await its completion; a delayed close is never reported finished early;
// close errors are swallowed; a resource adopted after release began is
// closed immediately, exactly once.

import 'dart:async';

import 'package:chat_ai_openai_realtime/src/realtime_setup_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two concurrent cleanup triggers share one actual cleanup and both '
      'await its completion (regression 3)', () async {
    final release = RealtimeSetupRelease();
    var closeCalls = 0;
    final closeGate = Completer<void>();
    release.register(
      RealtimeSetupRelease.once(() {
        closeCalls++;
        return closeGate.future;
      }),
    );

    final first = release.releaseAll();
    final second = release.releaseAll();
    var firstDone = false;
    var secondDone = false;
    unawaited(first.then((_) => firstDone = true));
    unawaited(second.then((_) => secondDone = true));

    await pumpEventQueue();
    expect(closeCalls, 1); // one actual cleanup
    // Neither trigger claims completion while the close is still running.
    expect(firstDone, isFalse);
    expect(secondDone, isFalse);

    closeGate.complete();
    await pumpEventQueue();
    expect(firstDone, isTrue);
    expect(secondDone, isTrue);
    expect(closeCalls, 1); // and never a second native close
  });

  test('close errors are swallowed: releaseAll completes normally and a '
      'late throwing closer never becomes unhandled (regression 4)', () async {
    final release = RealtimeSetupRelease();
    release.register(() async => throw StateError('native close defect'));
    await expectLater(release.releaseAll(), completes);

    // Registered after release began: closed immediately, error swallowed —
    // an unhandled zone error here would fail this test.
    release.register(() async => throw StateError('late close defect'));
    await pumpEventQueue();
  });

  test('a resource adopted after release began is closed immediately, '
      'exactly once', () async {
    final release = RealtimeSetupRelease();
    await release.releaseAll(); // the sweep ran before the resource existed

    var closeCalls = 0;
    final owned = await release.adopt(Future<int>.value(7), (_) async {
      closeCalls++;
    });
    await pumpEventQueue();
    expect(closeCalls, 1); // owned and released despite missing the sweep

    await owned.close(); // the shared closer stays exactly-once
    expect(closeCalls, 1);
  });

  test(
    'adopt after a finished releaseAll does not resolve until the late '
    'resource\'s DELAYED close completes (increment-3 regression 1)',
    () async {
      final release = RealtimeSetupRelease();
      await release.releaseAll(); // release fully finished before adoption

      var closeCalls = 0;
      final closeGate = Completer<void>();
      var adopted = false;
      final adoptFuture = release
          .adopt(Future<int>.value(7), (_) {
            closeCalls++;
            return closeGate.future; // the native close is still running
          })
          .then((owned) {
            adopted = true;
            return owned;
          });

      await pumpEventQueue();
      expect(closeCalls, 1); // the late close started immediately…
      expect(adopted, isFalse); // …and adopt is held until it finishes

      closeGate.complete();
      final owned = await adoptFuture;
      expect(adopted, isTrue);

      await owned.close(); // the closer stays exactly-once
      expect(closeCalls, 1);
    },
  );

  test(
    'releaseAll releases newest first and every closer exactly once',
    () async {
      final release = RealtimeSetupRelease();
      final order = <String>[];
      release.register(RealtimeSetupRelease.once(() async => order.add('old')));
      release.register(RealtimeSetupRelease.once(() async => order.add('new')));
      await release.releaseAll();
      await release.releaseAll(); // memoized — nothing runs twice
      expect(order, ['new', 'old']);
    },
  );
}
