// The Retry Boundary (V1_SPEC §8, SERVER-CONTRACT §11, test contract §12.5):
// pre-token rate|overloaded|network retry silently under the same frozen
// request/key within the wall-clock deadline; everything else is terminal;
// the deadline is a clock consulted at decision points, never a timer into a
// live stream.
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

void main() {
  test('pre-token rate/overloaded/network retry silently: same frozen '
      'ChatRequest, same key, no second checkpoint', () async {
    final fake = FakeChatBackend()
      ..failWith(FailureCause.rate)
      ..failWith(FailureCause.overloaded)
      ..failWith(FailureCause.network)
      ..reply('finally');
    final time = FakeTime();
    var checkpoints = 0;
    final session = makeSession(
      backend: fake,
      time: time,
      checkpoint: (snapshot) async => checkpoints++,
    );

    await session.send('hi');
    await waitForState(session, (s) => s is Done);

    final requests = capturedRequestsOf(fake);
    expect(requests, hasLength(4));
    expect(
      requests.toSet(),
      hasLength(1),
      reason: 'every silent retry re-sends the identical frozen request',
    );
    expect(
      checkpoints,
      1,
      reason:
          'a silent retry of a checkpointed Attempt does not '
          'checkpoint again',
    );
    expect(time.delays, hasLength(3), reason: 'one backoff per retry');
    expect(session.snapshot.messages.first.status, MessageStatus.sent);
  });

  test('non-retryable causes are terminal at once: user failed, phase '
      'sending', () async {
    for (final cause in [
      FailureCause.auth,
      FailureCause.entitlement,
      FailureCause.quota,
      FailureCause.contentFilter,
      FailureCause.contextTooLong,
      FailureCause.upstream,
    ]) {
      final fake = FakeChatBackend();
      scriptFailureResponse(fake, cause, detail: 'raw detail');
      final time = FakeTime();
      final session = makeSession(backend: fake, time: time);
      await session.send('hi');
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, cause);
      expect(failed.phase, FailurePhase.sending);
      expect(failed.developerDetail, 'raw detail');
      expect(capturedRequestsOf(fake), hasLength(1), reason: '$cause');
      expect(time.delays, isEmpty);
      expect(
        session.snapshot.messages.single.status,
        MessageStatus.failed,
        reason:
            'an exhausted/terminal pre-token failure fails the user '
            'Message — resend is the recovery',
      );
    }
  });

  test('the wall-clock deadline lands on the LAST REAL cause', () async {
    final fake = FakeChatBackend()
      ..failWith(FailureCause.network)
      ..failWith(FailureCause.network)
      ..failWith(FailureCause.rate)
      ..failWith(FailureCause.rate)
      ..failWith(FailureCause.rate);
    final time = FakeTime();
    final session = makeSession(
      backend: fake,
      time: time,
      retryDeadline: const Duration(seconds: 1),
    );
    await session.send('hi');
    final failed = await waitForState(session, (s) => s is Failed) as Failed;
    expect(failed.cause, FailureCause.rate, reason: 'last real cause');
    expect(failed.phase, FailurePhase.sending);
    // Backoffs never exceeded the remaining budget; the total wait is
    // bounded by the deadline.
    final total = time.delays.fold(Duration.zero, (a, b) => a + b);
    expect(total, lessThanOrEqualTo(const Duration(seconds: 1)));
    expect(session.snapshot.messages.single.status, MessageStatus.failed);
  });

  group('Retry-After', () {
    test('is honoured exactly when it fits the remaining deadline', () async {
      final fake = FakeChatBackend();
      scriptFailureResponse(
        fake,
        FailureCause.rate,
        retryAfter: const Duration(seconds: 5),
      );
      fake.reply('ok');
      final time = FakeTime();
      final session = makeSession(
        backend: fake,
        time: time,
        retryDeadline: const Duration(seconds: 30),
      );
      await session.send('hi');
      await waitForState(session, (s) => s is Done);
      expect(time.delays, [
        const Duration(seconds: 5),
      ], reason: 'Retry-After replaces the jittered backoff');
    });

    test(
      'that does not fit the remaining deadline is terminal immediately',
      () async {
        final fake = FakeChatBackend();
        scriptFailureResponse(
          fake,
          FailureCause.rate,
          retryAfter: const Duration(seconds: 60),
        );
        fake.reply('never dispatched');
        final time = FakeTime();
        final session = makeSession(
          backend: fake,
          time: time,
          retryDeadline: const Duration(seconds: 30),
        );
        await session.send('hi');
        final failed =
            await waitForState(session, (s) => s is Failed) as Failed;
        expect(failed.cause, FailureCause.rate);
        expect(time.delays, isEmpty, reason: 'no partial wait is attempted');
        expect(capturedRequestsOf(fake), hasLength(1));
      },
    );
  });

  test('a live accepted stream is never cut by the deadline', () async {
    final backend = ManualBackend();
    final time = FakeTime();
    final session = makeSession(
      backend: backend,
      time: time,
      retryDeadline: const Duration(seconds: 1),
    );
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    await pumpEventQueue();
    // The model thinks silently far past the deadline…
    time.current = time.current.add(const Duration(minutes: 5));
    backend.emit(const BackendEvent.delta('slow but alive'));
    backend.emit(const BackendEvent.done());
    await pumpEventQueue();
    expect(
      session.state,
      isA<Done>(),
      reason: 'no timer ever fires into a live stream',
    );
    await session.dispose();
  });

  test('a pre-token failure after the deadline has elapsed stops without '
      'another attempt', () async {
    final backend = ManualBackend();
    final time = FakeTime();
    final session = makeSession(
      backend: backend,
      time: time,
      retryDeadline: const Duration(seconds: 1),
    );
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    await pumpEventQueue();
    time.current = time.current.add(const Duration(minutes: 5));
    backend.emit(const BackendEvent.error(FailureCause.overloaded));
    await backend.closeCurrent();
    await pumpEventQueue();
    final state = session.state;
    expect(state, isA<Failed>());
    expect((state as Failed).cause, FailureCause.overloaded);
    expect(
      backend.requests,
      hasLength(1),
      reason:
          'the elapsed deadline is '
          'seen at the next decision point',
    );
    await session.dispose();
  });

  group('cancellable backoff (real production Timer)', () {
    test('cancel during a backoff wait stops the timer: Cancelled, no '
        'second dispatch', () async {
      final backend = ManualBackend();
      // No injected clock/delay: the wait is the real backoff Timer
      // (250 ms at jitter 1.0).
      final session = makeSession(backend: backend);
      await session.send('hi');
      backend.emit(const BackendEvent.error(FailureCause.network));
      await backend.closeCurrent();
      await pumpEventQueue();
      expect(
        session.state,
        const ConversationState.sending(),
        reason: 'pre-token retry is waiting out its backoff',
      );

      session.cancel();
      expect(session.state, const ConversationState.cancelled());
      // Well past the 250 ms backoff: the interrupted wait never dispatched.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(backend.requests, hasLength(1));
      expect(session.snapshot.messages.single.status, MessageStatus.sent);
      await session.dispose();
    });

    test('dispose during a long Retry-After completes without waiting it '
        'out; no second dispatch', () async {
      final fake = FakeChatBackend();
      scriptFailureResponse(
        fake,
        FailureCause.rate,
        retryAfter: const Duration(seconds: 60),
      );
      fake.reply('never dispatched');
      final session = makeSession(
        backend: fake,
        retryDeadline: const Duration(seconds: 120),
      );
      await session.send('hi');
      // Let the failure arrive and the 60 s production timer start.
      await pumpEventQueue();
      // Completes promptly — the teardown cancels the backoff instead of
      // sleeping out the Retry-After (a hang here fails the suite timeout).
      await session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(capturedRequestsOf(fake), hasLength(1));
    });

    test(
      'an uncancelled real-timer backoff still retries and completes',
      () async {
        final fake = FakeChatBackend()
          ..failWith(FailureCause.network)
          ..reply('made it');
        // Jitter 0.0 → a 125 ms real wait; no fake clock involved.
        final session = makeSession(backend: fake, random: () => 0.0);
        await session.send('hi');
        await waitForState(session, (s) => s is Done);
        expect(capturedRequestsOf(fake), hasLength(2));
        expect(visibleText(session.snapshot.messages.last), 'made it');
      },
    );
  });

  test('post-token break keeps the partial: Failed(upstream, streaming), '
      'no silent retry', () async {
    final fake = FakeChatBackend()
      ..breakAfterFirstToken()
      ..reply('never dispatched');
    final session = makeSession(backend: fake, time: FakeTime());
    await session.send('hi');
    final failed = await waitForState(session, (s) => s is Failed) as Failed;
    expect(failed.cause, FailureCause.upstream);
    expect(failed.phase, FailurePhase.streaming);
    final assistant = session.snapshot.messages.last;
    expect(assistant.status, MessageStatus.interrupted);
    expect(visibleText(assistant), 'partial');
    expect(capturedRequestsOf(fake), hasLength(1));
    expect(session.snapshot.messages.first.status, MessageStatus.sent);
  });

  test('after the first Delta EVERY cause normalises to upstream — no '
      'retry, the original cause survives as a logs-only detail', () async {
    for (final cause in [
      FailureCause.network,
      FailureCause.rate,
      FailureCause.overloaded,
      FailureCause.auth,
      FailureCause.contentFilter,
    ]) {
      final fake = FakeChatBackend()
        ..failWith(cause, afterTokens: 2)
        ..reply('never dispatched');
      final session = makeSession(backend: fake, time: FakeTime());
      await session.send('hi');
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, FailureCause.upstream, reason: '$cause');
      expect(failed.phase, FailurePhase.streaming);
      expect(
        failed.developerDetail,
        cause.name,
        reason: 'the wire cause stays visible to logs only',
      );
      expect(visibleText(session.snapshot.messages.last), 'tok0 tok1 ');
      expect(capturedRequestsOf(fake), hasLength(1));
    }
  });

  test(
    'a ProviderStateEvent before the first Delta stays on the pre-token '
    'side: retry continues and the stale opaque partial is replaced',
    () async {
      final backend = ManualBackend();
      final time = FakeTime();
      final session = makeSession(backend: backend, time: time);
      final opaque = ProviderOpaquePart('openai', Uint8List.fromList([7, 7]));
      await session.send('hi');
      backend.emit(const BackendEvent.accepted());
      backend.emit(BackendEvent.providerState(opaque));
      await pumpEventQueue();
      // The break arrives before any Delta → still silently retryable.
      backend.emit(const BackendEvent.error(FailureCause.network));
      await backend.closeCurrent();
      await pumpEventQueue();
      expect(backend.requests, hasLength(2), reason: 'silent retry ran');
      expect(session.state, const ConversationState.sending());
      backend.emit(const BackendEvent.accepted());
      backend.emit(const BackendEvent.delta('fresh'));
      backend.emit(const BackendEvent.done());
      await pumpEventQueue();
      expect(session.state, isA<Done>());
      final assistant = session.snapshot.messages.last;
      expect(visibleText(assistant), 'fresh');
      expect(
        assistant.parts.whereType<ProviderOpaquePart>(),
        isEmpty,
        reason: 'the failed attempt\'s opaque partial was replaced',
      );
    },
  );

  test('an exhausted pre-token failure leaves no technical opaque-only '
      'assistant behind: user failed, phase sending', () async {
    final backend = ManualBackend();
    final session = makeSession(backend: backend, time: FakeTime());
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    backend.emit(
      BackendEvent.providerState(
        ProviderOpaquePart('openai', Uint8List.fromList([1])),
      ),
    );
    backend.emit(const BackendEvent.error(FailureCause.auth));
    await pumpEventQueue();
    final state = session.state;
    expect(state, isA<Failed>());
    expect((state as Failed).cause, FailureCause.auth);
    expect(state.phase, FailurePhase.sending);
    expect(
      session.snapshot.messages.single.role,
      MessageRole.user,
      reason: 'the hidden-only assistant is removed, not interrupted',
    );
    expect(session.snapshot.messages.single.status, MessageStatus.failed);
    await session.dispose();
  });

  group('silent-path 409/410 (protocol signals, never a silent fresh key)', () {
    test('410 on a plain send is terminal Failed(upstream)', () async {
      final fake = FakeChatBackend()
        ..respondGone410()
        ..reply('never dispatched');
      final session = makeSession(backend: fake, time: FakeTime());
      await session.send('hi');
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, FailureCause.upstream);
      expect(
        capturedRequestsOf(fake),
        hasLength(1),
        reason: 'no fresh key is minted silently',
      );
      expect(session.snapshot.messages.single.status, MessageStatus.failed);
    });

    test(
      '409/410 inside a silent retry of an explicit command is terminal',
      () async {
        for (final script in [
          (FakeChatBackend fake) => fake.respondConflict409(),
          (FakeChatBackend fake) => fake.respondGone410(),
        ]) {
          final fake = FakeChatBackend()..failWith(FailureCause.network);
          script(fake);
          fake.reply('never dispatched');
          final session = makeSession(
            backend: fake,
            time: FakeTime(),
            history: Conversation(
              messages: [
                userMessage('u-1', 'hi', status: MessageStatus.failed),
              ],
            ),
          );
          await session.resend('u-1'); // explicit, fallback armed…
          final failed =
              await waitForState(session, (s) => s is Failed) as Failed;
          // …but the network retry disarmed it: a silent retry never gets a
          // fresh-key fallback.
          expect(failed.cause, FailureCause.upstream);
          expect(capturedRequestsOf(fake), hasLength(2));
          expect(
            capturedRequestsOf(fake).last.idempotencyKey,
            'key-u-1',
            reason: 'the silent retry stayed on the persisted key',
          );
        }
      },
    );
  });
}
