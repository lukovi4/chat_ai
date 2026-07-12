// State machine, the private command gate, the no-op matrix and the
// package-internal command dispositions (V1_SPEC §4, test contract §12.1/.2).
import 'dart:async';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

void main() {
  test(
    'happy path: Idle → Sending → Streaming → Done, statuses tracked',
    () async {
      final fake = FakeChatBackend()..reply('Hello world');
      final uuid = SequentialUuid();
      final session = makeSession(backend: fake, uuid: uuid);
      final states = <ConversationState>[];
      session.states.listen(states.add);

      await session.send('hi');
      await pumpEventQueue();

      expect(states, const [
        ConversationState.sending(),
        ConversationState.streaming(),
        ConversationState.done(
          usage: Usage(
            inputTokens: 1,
            outputTokens: 2,
            usageRaw: {'fake': 'raw'},
          ),
        ),
      ]);
      final messages = session.snapshot.messages;
      expect(messages, hasLength(2));
      expect(messages[0].role, MessageRole.user);
      expect(messages[0].status, MessageStatus.sent);
      expect(messages[0].attemptKey, isNotNull);
      expect(messages[1].role, MessageRole.assistant);
      expect(messages[1].status, MessageStatus.complete);
      expect(visibleText(messages[1]), 'Hello world');
      expect(
        messages[1].attemptKey,
        messages[0].attemptKey,
        reason: 'first leg: the assistant carries the leg key of the send',
      );
      // The dispatched request rode under the user Message's attemptKey.
      expect(
        capturedRequestsOf(fake).single.idempotencyKey,
        messages[0].attemptKey,
      );
    },
  );

  test(
    'the command Future never waits for the terminal backend event',
    () async {
      final fake = FakeChatBackend()
        ..reply('slow reply', tokenDelay: const Duration(milliseconds: 50));
      final session = makeSession(backend: fake);

      await session.send('hi'); // completes at the dispatch decision
      expect(session.state, const ConversationState.sending());

      await waitForState(session, (s) => s is Done);
      await session.dispose();
    },
  );

  test('Accepted flips the user Message to sent before any token', () async {
    final backend = ManualBackend();
    final session = makeSession(backend: backend);
    await session.send('hi');
    expect(session.snapshot.messages.single.status, MessageStatus.sending);

    backend.emit(const BackendEvent.accepted());
    await pumpEventQueue();
    expect(session.snapshot.messages.single.status, MessageStatus.sent);
    expect(session.state, const ConversationState.sending());
    await session.dispose();
  });

  group('no-op matrix (wrong phase / busy gate — dropped, never queued)', () {
    test('send during an in-flight reply is a no-op', () async {
      final backend = ManualBackend();
      final session = makeSession(backend: backend);
      await session.send('first');
      backend.emit(const BackendEvent.accepted());
      backend.emit(const BackendEvent.delta('x'));
      await pumpEventQueue();
      expect(session.state, const ConversationState.streaming());

      expect(
        await sendWithDisposition(session, 'second'),
        ChatCommandDisposition.noOp,
      );
      await session.regenerate();
      await session.resend('whatever');
      await session.editAndResend('whatever', 'text');
      await pumpEventQueue();

      expect(backend.requests, hasLength(1), reason: 'nothing was queued');
      expect(session.snapshot.messages, hasLength(2));
      await session.dispose();
    });

    test('empty text and no images is a no-op everywhere', () async {
      final fake = FakeChatBackend();
      final session = makeSession(backend: fake);
      expect(
        await sendWithDisposition(session, ''),
        ChatCommandDisposition.noOp,
      );
      expect(session.state, const ConversationState.idle());
      expect(capturedRequestsOf(fake), isEmpty);
    });

    test(
      'regenerate/resend/editAndResend on wrong targets are no-ops',
      () async {
        final fake = FakeChatBackend();
        final session = makeSession(
          backend: fake,
          history: Conversation(
            messages: [
              systemMessage('s-1', 'be terse'),
              userMessage('u-1', 'hi'),
              assistantMessage('a-1', 'hello'),
              userMessage('u-2', 'ok'),
            ],
          ),
        );
        // resend of a non-failed user Message → no-op.
        await session.resend('u-1');
        // resend of an assistant / unknown id → no-op.
        await session.resend('a-1');
        await session.resend('ghost');
        // editAndResend of an assistant / system / unknown id → no-op.
        await session.editAndResend('a-1', 'x');
        await session.editAndResend('s-1', 'x');
        await session.editAndResend('ghost', 'x');
        // editAndResend with empty text and no kept images → no-op.
        await session.editAndResend('u-1', '');
        await pumpEventQueue();
        expect(capturedRequestsOf(fake), isEmpty);
        expect(session.state, const ConversationState.idle());
      },
    );

    test(
      'regenerate with a system Message last / empty history is a no-op',
      () async {
        final fake = FakeChatBackend();
        final empty = makeSession(backend: fake);
        await empty.regenerate();
        final systemLast = makeSession(
          backend: fake,
          history: Conversation(messages: [systemMessage('s-1', 'x')]),
        );
        await systemLast.regenerate();
        await pumpEventQueue();
        expect(capturedRequestsOf(fake), isEmpty);
      },
    );

    test(
      'cancel is a no-op in Idle and after a terminal (Done wins)',
      () async {
        final fake = FakeChatBackend()..reply('fast');
        final session = makeSession(backend: fake);
        session.cancel(); // Idle → no-op
        expect(session.state, const ConversationState.idle());

        await session.send('hi');
        await waitForState(session, (s) => s is Done);
        session.cancel(); // after Done → no-op, Done wins
        expect(session.state, isA<Done>());
      },
    );
  });

  test('two sends racing an async resize: one preprocessing job, one Message, '
      'one backend call', () async {
    final fake = FakeChatBackend()..reply('ok');
    final gate = Completer<void>();
    var jobs = 0;
    final session = makeSession(
      backend: fake,
      processImage: (raw, options) async {
        jobs++;
        await gate.future;
        return raw;
      },
    );

    final first = sendWithDisposition(
      session,
      'with image',
      images: [
        Uint8List.fromList([1, 2, 3]),
      ],
    );
    final second = sendWithDisposition(
      session,
      'racer',
      images: [
        Uint8List.fromList([4, 5, 6]),
      ],
    );
    expect(
      await second,
      ChatCommandDisposition.noOp,
      reason: 'the gate is held from the synchronous command start',
    );
    gate.complete();
    expect(await first, ChatCommandDisposition.accepted);
    await waitForState(session, (s) => s is Done);

    expect(jobs, 1);
    expect(capturedRequestsOf(fake), hasLength(1));
    expect(
      session.snapshot.messages.whereType<Message>().where(
        (m) => m.role == MessageRole.user,
      ),
      hasLength(1),
    );
  });

  test(
    'resend of an older failed user Message with later history is a '
    'FULL no-op: no truncation, no state, no key, no checkpoint/backend',
    () async {
      final fake = FakeChatBackend()..reply('never dispatched');
      final uuid = SequentialUuid();
      var checkpoints = 0;
      final session = makeSession(
        backend: fake,
        uuid: uuid,
        checkpoint: (snapshot) async => checkpoints++,
        history: Conversation(
          messages: [
            userMessage('u-old', 'lost turn', status: MessageStatus.failed),
            userMessage('u-2', 'moved on'),
            assistantMessage('a-2', 'replied'),
          ],
        ),
      );
      final before = session.snapshot;

      await session.resend('u-old');
      await pumpEventQueue();

      expect(
        session.state,
        const ConversationState.idle(),
        reason: 'no state change',
      );
      expect(
        session.snapshot,
        before,
        reason: 'nothing truncated, nothing restatused',
      );
      expect(session.snapshot.messages, hasLength(3));
      expect(capturedRequestsOf(fake), isEmpty, reason: 'no backend call');
      expect(checkpoints, 0, reason: 'no checkpoint');
      expect(uuid.minted, isEmpty, reason: 'no new UUID was created');

      // The rule is positional, not historical: the same Message resends
      // normally once it IS the last one (other paths untouched).
      final lastFailed = makeSession(
        backend: fake,
        history: Conversation(
          messages: [
            userMessage('u-old', 'lost turn', status: MessageStatus.failed),
          ],
        ),
      );
      await lastFailed.resend('u-old');
      await waitForState(lastFailed, (s) => s is Done);
      expect(capturedRequestsOf(fake).single.idempotencyKey, 'key-u-old');
    },
  );

  test('the Bot Profile and the deadline clock are snapshotted at the '
      'command, BEFORE image preprocessing', () async {
    final fake = FakeChatBackend()
      ..reply('first')
      ..reply('second');
    final gate = Completer<void>();
    final session = makeSession(
      backend: fake,
      processImage: (raw, options) async {
        await gate.future;
        return raw;
      },
    );
    final pending = session.send(
      'pic',
      images: [
        Uint8List.fromList([1]),
      ],
    );
    // The profile switch lands DURING the resize: it may only affect the
    // next command — the in-flight one runs under the frozen snapshot.
    session.botProfile = const BotProfile(
      id: 'free',
      systemPrompt: 'be terse',
      tools: [],
    );
    gate.complete();
    await pending;
    await waitForState(session, (s) => s is Done);
    expect(capturedRequestsOf(fake).single.botId, 'premium');
    expect(capturedRequestsOf(fake).single.system, 'be kind');

    await session.send('next');
    await waitForState(session, (s) => s is Done);
    expect(capturedRequestsOf(fake).last.botId, 'free');
  });

  test('image preprocessing time counts against the retry deadline', () async {
    final fake = FakeChatBackend()
      ..failWith(FailureCause.network)
      ..reply('never dispatched');
    final time = FakeTime();
    final session = makeSession(
      backend: fake,
      time: time,
      retryDeadline: const Duration(seconds: 1),
      processImage: (raw, options) async {
        // The resize alone eats the whole wall-clock budget.
        time.current = time.current.add(const Duration(seconds: 2));
        return raw;
      },
    );
    await session.send(
      'slow pic',
      images: [
        Uint8List.fromList([1]),
      ],
    );
    final failed = await waitForState(session, (s) => s is Failed) as Failed;
    expect(failed.cause, FailureCause.network);
    expect(time.delays, isEmpty, reason: 'no backoff wait fits');
    expect(
      capturedRequestsOf(fake),
      hasLength(1),
      reason: 'the elapsed deadline is seen at the first retry decision',
    );
  });

  test('the gate is private: no public phase during preprocessing', () async {
    final fake = FakeChatBackend()..reply('ok');
    final gate = Completer<void>();
    final session = makeSession(
      backend: fake,
      processImage: (raw, options) async {
        await gate.future;
        return raw;
      },
    );
    final pending = session.send(
      'x',
      images: [
        Uint8List.fromList([1]),
      ],
    );
    expect(
      session.state,
      const ConversationState.idle(),
      reason: 'preprocessing is not a public phase',
    );
    session.cancel(); // not yet active — no-op, the send continues
    gate.complete();
    await pending;
    await waitForState(session, (s) => s is Done);
    expect(session.snapshot.messages, hasLength(2));
  });

  group('disposal and reentrancy (the loud StateError exceptions)', () {
    test('commands after dispose throw; repeated dispose is a no-op', () async {
      final session = makeSession(backend: FakeChatBackend());
      await session.dispose();
      await session.dispose(); // idempotent

      expect(() => session.send('x'), throwsStateError);
      expect(() => session.regenerate(), throwsStateError);
      expect(() => session.resend('id'), throwsStateError);
      expect(() => session.editAndResend('id', 'x'), throwsStateError);
      expect(() => session.cancel(), throwsStateError);
    });

    test('dispose frees the streams: states/tokens complete', () async {
      final session = makeSession(backend: FakeChatBackend());
      final statesDone = session.states.toList();
      final tokensDone = session.tokens.toList();
      await session.dispose();
      expect(await statesDone, isEmpty);
      expect(await tokensDone, isEmpty);
    });

    test(
      'checkpoint reentrancy on the same session throws StateError',
      () async {
        final fake = FakeChatBackend()..reply('ok');
        Object? caught;
        late final ChatSession session;
        session = makeSession(
          backend: fake,
          checkpoint: (snapshot) async {
            try {
              await session.send('reentrant');
            } catch (error) {
              caught = error;
            }
          },
        );
        await session.send('hi');
        await waitForState(session, (s) => s is Done);
        expect(caught, isA<StateError>());
        // The command itself still dispatched (the callback swallowed the
        // error, so the checkpoint succeeded).
        expect(capturedRequestsOf(fake), hasLength(1));
      },
    );

    test(
      'a session in another checkpoint is untouched (identity check)',
      () async {
        final other = makeSession(
          backend: FakeChatBackend()..reply('other ok'),
        );
        final fake = FakeChatBackend()..reply('ok');
        ChatCommandDisposition? nested;
        final session = makeSession(
          backend: fake,
          checkpoint: (snapshot) async {
            nested = await sendWithDisposition(other, 'cross-session');
          },
        );
        await session.send('hi');
        await waitForState(session, (s) => s is Done);
        expect(nested, ChatCommandDisposition.accepted);
        await waitForState(other, (s) => s is Done);
      },
    );
  });

  test('snapshot is an immutable value; mutating it throws', () async {
    final session = makeSession(
      backend: FakeChatBackend(),
      history: Conversation(messages: [userMessage('u-1', 'hi')]),
    );
    final snapshot = session.snapshot;
    expect(() => snapshot.messages.clear(), throwsUnsupportedError);
  });
}
