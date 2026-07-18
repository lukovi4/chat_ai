import 'package:example/src/voice_probe/probe_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Defect 6: closers run newest-first (LIFO) so the DataChannel closes before
  // its PeerConnection and a track before its MediaStream.
  test('releaseAll runs closers in LIFO order', () async {
    final order = <String>[];
    final release = ProbeRelease();
    await release.register(() async => order.add('stream'));
    await release.register(() async => order.add('track'));
    await release.register(() async => order.add('peer'));
    await release.register(() async => order.add('channel'));

    await release.releaseAll();

    expect(order, <String>['channel', 'peer', 'track', 'stream']);
  });

  test('adopt registers in LIFO order too', () async {
    final order = <String>[];
    final release = ProbeRelease();
    await release.adopt(
      Future<String>.value('s'),
      (String _) async => order.add('stream'),
    );
    await release.adopt(
      Future<String>.value('p'),
      (String _) async => order.add('peer'),
    );

    await release.releaseAll();
    expect(order, <String>['peer', 'stream']);
  });

  test('one closer failing does not stop the others', () async {
    final order = <String>[];
    final release = ProbeRelease();
    await release.register(() async => order.add('x'));
    await release.register(() async => throw StateError('boom'));
    await release.register(() async => order.add('y'));

    await release.releaseAll();
    // LIFO: y, (boom swallowed), x.
    expect(order, <String>['y', 'x']);
  });

  test(
    'a late register after release runs immediately, exactly once',
    () async {
      final order = <String>[];
      final release = ProbeRelease();
      await release.register(() async => order.add('early'));
      await release.releaseAll();
      expect(order, <String>['early']);

      // Registered after the sweep — closed on the spot.
      await release.register(() async => order.add('late'));
      expect(order, <String>['early', 'late']);
    },
  );

  test('releaseAll is memoized — each closer runs exactly once', () async {
    var count = 0;
    final release = ProbeRelease();
    await release.register(() async => count++);
    await release.releaseAll();
    await release.releaseAll();
    expect(count, 1);
    expect(release.isReleased, isTrue);
  });
}
