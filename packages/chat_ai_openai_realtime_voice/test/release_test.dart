// Required test 16 (release half): late peer/channel/stream resources are
// closed exactly once, and a resource adopted after the sweep is closed right
// here — the caller's future settles only once that close has finished.
import 'package:chat_ai_openai_realtime_voice/src/voice_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('releaseAll runs closers in LIFO order (newest first)', () async {
    final order = <int>[];
    final release = RealtimeVoiceRelease();
    await release.register(() async => order.add(1));
    await release.register(() async => order.add(2));
    await release.register(() async => order.add(3));
    await release.releaseAll();
    expect(order, <int>[3, 2, 1]);
  });

  test('one closer failing does not stop the others', () async {
    final order = <int>[];
    final release = RealtimeVoiceRelease();
    await release.register(() async => order.add(1));
    await release.register(() async => throw StateError('boom'));
    await release.register(() async => order.add(3));
    await release.releaseAll();
    expect(order, <int>[3, 1]);
  });

  test('releaseAll is memoized — each closer runs exactly once', () async {
    var runs = 0;
    final release = RealtimeVoiceRelease();
    await release.register(() async => runs++);
    await release.releaseAll();
    await release.releaseAll();
    await release.releaseAll();
    expect(runs, 1);
  });

  test(
    'a late register after release runs immediately, exactly once',
    () async {
      var runs = 0;
      final release = RealtimeVoiceRelease();
      await release.releaseAll();
      await release.register(() async => runs++);
      expect(runs, 1);
    },
  );

  test(
    'adopt after release closes the late resource, awaited before return',
    () async {
      final release = RealtimeVoiceRelease();
      await release.releaseAll();

      var closed = false;
      // The resource materializes only after the sweep; its (async) close must
      // finish before adopt() returns — the settlement waits for the close.
      final value = await release.adopt<String>(
        Future<String>.value('late-peer'),
        (String _) async {
          await Future<void>.delayed(Duration.zero);
          closed = true;
        },
      );
      expect(value, 'late-peer');
      expect(closed, isTrue);
    },
  );
}
