// Cancel/dispose races (V1_SPEC §4, test contract §12.4): cancel from public
// Sending / Streaming / AwaitingTool, Done wins, and no late
// preprocessing/checkpoint/tool completion may dispatch or mutate a
// terminal/disposed session.
import 'dart:async';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

void main() {
  test(
    'cancel in public Sending: user stays sent, no assistant is created',
    () async {
      final backend = ManualBackend();
      final session = makeSession(backend: backend);
      await session.send('hi');
      expect(session.state, const ConversationState.sending());

      session.cancel();
      expect(session.state, const ConversationState.cancelled());
      final user = session.snapshot.messages.single;
      expect(
        user.status,
        MessageStatus.sent,
        reason: 'the user gave up on the reply, not on the send',
      );
      expect(backend.cancelledSubscriptions, 1, reason: 'wire-cancel');
      await session.dispose();
    },
  );

  test(
    'cancel during a pending checkpoint: sent user, no late dispatch',
    () async {
      final backend = ManualBackend();
      final checkpointGate = Completer<void>();
      final session = makeSession(
        backend: backend,
        checkpoint: (snapshot) => checkpointGate.future,
      );
      final pending = session.send('hi');
      await pumpEventQueue();
      expect(
        session.state,
        const ConversationState.sending(),
        reason: 'cancel is active from step 4, checkpoint included',
      );

      session.cancel();
      expect(session.state, const ConversationState.cancelled());
      expect(session.snapshot.messages.single.status, MessageStatus.sent);

      checkpointGate.complete(); // the late success may not resurrect dispatch
      await pending;
      await pumpEventQueue();
      expect(backend.requests, isEmpty);
    },
  );

  test('cancel in Streaming keeps the FULL accumulator, not the last '
      'throttled emission', () async {
    final backend = ManualBackend();
    final session = makeSession(backend: backend);
    final emissions = <String>[];
    session.tokens.listen(emissions.add);
    await session.send('hi');

    backend.emit(const BackendEvent.accepted());
    backend.emit(const BackendEvent.delta('one '));
    await pumpEventQueue();
    // These two land inside the 66 ms throttle window — not yet emitted.
    backend.emit(const BackendEvent.delta('two '));
    backend.emit(const BackendEvent.delta('three'));
    await pumpEventQueue();
    expect(session.state, const ConversationState.streaming());
    expect(emissions.first, 'one ');

    session.cancel();
    expect(session.state, const ConversationState.cancelled());
    final assistant = session.snapshot.messages.last;
    expect(assistant.status, MessageStatus.interrupted);
    expect(
      visibleText(assistant),
      'one two three',
      reason: 'the internal accumulator is always complete',
    );
    await pumpEventQueue();
    expect(
      emissions.last,
      'one two three',
      reason: 'the terminal flushes the complete text',
    );
    await session.dispose();
  });

  test('cancel in Sending after only provider_state: the technical '
      'opaque-only assistant is removed, late events mutate nothing', () async {
    final backend = ManualBackend();
    final session = makeSession(backend: backend);
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    backend.emit(
      BackendEvent.providerState(
        ProviderOpaquePart('openai', Uint8List.fromList([1, 2])),
      ),
    );
    await pumpEventQueue();
    expect(
      session.state,
      const ConversationState.sending(),
      reason: 'no Delta yet — still the pre-token side',
    );

    session.cancel();
    expect(session.state, const ConversationState.cancelled());
    final messages = session.snapshot.messages;
    expect(
      messages.single.role,
      MessageRole.user,
      reason: 'no bot Message survives — the user never saw a reply',
    );
    expect(messages.single.status, MessageStatus.sent);
    expect(backend.cancelledSubscriptions, 1, reason: 'wire-cancel fired');

    final frozen = session.snapshot;
    backend.emit(const BackendEvent.delta('late'));
    backend.emit(const BackendEvent.done());
    await pumpEventQueue();
    expect(session.snapshot, frozen);
    expect(session.state, const ConversationState.cancelled());
    await session.dispose();
  });

  test('cancel during a recovery keeps the pre-existing interrupted partial '
      'untouched', () async {
    final backend = ManualBackend();
    final session = makeSession(
      backend: backend,
      history: Conversation(
        messages: [
          userMessage('u-1', 'hi'),
          assistantMessage(
            'a-1',
            'half an ans',
            status: MessageStatus.interrupted,
            parts: const [
              ContentPart.text('half an ans'),
              ContentPart.toolCall('c1', 'searchNotes', {}),
              ContentPart.toolResult('c1', 'r1', false),
            ],
          ),
        ],
      ),
    );
    await session.regenerate();
    expect(session.state, const ConversationState.sending());

    session.cancel();
    expect(session.state, const ConversationState.cancelled());
    final assistant = session.snapshot.messages.last;
    expect(
      assistant.id,
      'a-1',
      reason:
          'the recovery partial is never '
          'removed as technical',
    );
    expect(assistant.status, MessageStatus.interrupted);
    expect(
      assistant.parts,
      hasLength(3),
      reason: 'visible text and the completed tool exchange are kept',
    );
    await session.dispose();
  });

  test(
    'dispose after Done waits out a wire-cancel the terminal already '
    'started (asynchronous transport onCancel), cancelling exactly once',
    () async {
      final wireCancelGate = Completer<void>();
      final backend = ManualBackend(onCancelAsync: () => wireCancelGate.future);
      final session = makeSession(backend: backend);
      await session.send('hi');
      backend.emit(const BackendEvent.accepted());
      backend.emit(const BackendEvent.delta('full'));
      backend.emit(const BackendEvent.done());
      await pumpEventQueue();
      expect(session.state, isA<Done>());
      expect(
        backend.cancelledSubscriptions,
        1,
        reason: 'the terminal already initiated the wire-cancel',
      );

      var torndown = false;
      final teardown = session.dispose().whenComplete(() => torndown = true);
      await pumpEventQueue();
      expect(
        torndown,
        isFalse,
        reason:
            'that earlier cancellation is still pending — dispose must '
            'wait for it even though no subscription is active anymore',
      );

      wireCancelGate.complete();
      await teardown;
      expect(backend.cancelledSubscriptions, 1, reason: 'cancelled once');
    },
  );

  test('Done wins the race with cancel', () async {
    final backend = ManualBackend();
    final session = makeSession(backend: backend);
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    backend.emit(const BackendEvent.delta('full answer'));
    backend.emit(const BackendEvent.done());
    await pumpEventQueue();

    session.cancel(); // nothing left to wait for
    expect(session.state, const ConversationState.done());
    expect(session.snapshot.messages.last.status, MessageStatus.complete);
    await session.dispose();
  });

  test('late backend events after cancel cannot mutate the session', () async {
    final backend = ManualBackend();
    final session = makeSession(backend: backend);
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    backend.emit(const BackendEvent.delta('par'));
    await pumpEventQueue();

    session.cancel();
    final frozen = session.snapshot;
    backend.emit(const BackendEvent.delta('tial'));
    backend.emit(const BackendEvent.done());
    await pumpEventQueue();
    expect(session.snapshot, frozen);
    expect(session.state, const ConversationState.cancelled());
    await session.dispose();
  });

  test('dispose mid-stream tears down without a state transition', () async {
    final backend = ManualBackend();
    final session = makeSession(backend: backend);
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    backend.emit(const BackendEvent.delta('par'));
    await pumpEventQueue();

    await session.dispose();
    expect(backend.cancelledSubscriptions, 1, reason: 'wire-cancel on dispose');
    // The snapshot still reads; the next open would normalise the stale
    // streaming status.
    expect(session.snapshot.messages.last.status, MessageStatus.streaming);
  });

  test('dispose during preprocessing completes only after the job settles '
      'and its stale result never dispatches', () async {
    final backend = ManualBackend();
    final gate = Completer<void>();
    final session = makeSession(
      backend: backend,
      processImage: (raw, options) async {
        await gate.future;
        return raw;
      },
    );
    final pending = sendWithDisposition(
      session,
      'img',
      images: [
        Uint8List.fromList([1]),
      ],
    );
    await pumpEventQueue();

    var torndown = false;
    final teardown = session.dispose().whenComplete(() => torndown = true);
    // A command after the (synchronous) invalidation already throws…
    expect(() => session.send('late'), throwsStateError);
    await pumpEventQueue();
    // …but the teardown Future waits for the in-flight job to settle.
    expect(
      torndown,
      isFalse,
      reason: 'dispose completes only after the preprocessing settlement',
    );

    gate.complete();
    await teardown;
    expect(await pending, ChatCommandDisposition.rejected);
    await pumpEventQueue();
    expect(backend.requests, isEmpty);
    expect(session.snapshot.messages, isEmpty);
  });

  test('dispose during a pending checkpoint waits for its settlement and '
      'prevents the dispatch', () async {
    final backend = ManualBackend();
    final gate = Completer<void>();
    final session = makeSession(
      backend: backend,
      checkpoint: (snapshot) => gate.future,
    );
    final pending = session.send('hi');
    await pumpEventQueue();

    var torndown = false;
    final teardown = session.dispose().whenComplete(() => torndown = true);
    await pumpEventQueue();
    expect(
      torndown,
      isFalse,
      reason: 'dispose completes only after the checkpoint settlement',
    );
    gate.complete();
    await teardown;
    await pending;
    await pumpEventQueue();
    expect(backend.requests, isEmpty);
  });

  test(
    'dispose awaits an asynchronous transport onCancel before reporting '
    'the session freed; a repeated dispose awaits the SAME teardown',
    () async {
      final wireCancelGate = Completer<void>();
      final backend = ManualBackend(onCancelAsync: () => wireCancelGate.future);
      final session = makeSession(backend: backend);
      await session.send('hi');
      backend.emit(const BackendEvent.accepted());
      backend.emit(const BackendEvent.delta('par'));
      await pumpEventQueue();

      var firstDone = false;
      var secondDone = false;
      final first = session.dispose().whenComplete(() => firstDone = true);
      final second = session.dispose().whenComplete(() => secondDone = true);
      await pumpEventQueue();
      expect(backend.cancelledSubscriptions, 1, reason: 'wire-cancel started');
      expect(
        firstDone,
        isFalse,
        reason: 'teardown waits for the transport cancellation',
      );
      expect(
        secondDone,
        isFalse,
        reason:
            'the second call awaits the same '
            'teardown, it never runs a second one',
      );

      wireCancelGate.complete();
      await first;
      await second;
      expect(backend.cancelledSubscriptions, 1);
    },
  );

  test('cancel in AwaitingTool keeps the partial and ignores the late '
      'resolver result', () async {
    final backend = ManualBackend();
    final resolverGate = Completer<ToolResult>();
    late final ChatSession session;
    session = makeSession(
      backend: backend,
      botProfile: const BotProfile(
        id: 'p',
        systemPrompt: 's',
        tools: [
          Tool(
            name: 'searchNotes',
            description: 'd',
            parameters: {
              'type': 'object',
              'properties': <String, dynamic>{},
              'required': <String>[],
              'additionalProperties': false,
            },
          ),
        ],
      ),
      onToolCall: (call) => resolverGate.future,
    );
    await session.send('hi');
    backend.emit(const BackendEvent.accepted());
    backend.emit(const BackendEvent.delta('checking… '));
    backend.emit(
      const BackendEvent.toolCall(
        ToolCall(id: 'c1', name: 'searchNotes', args: {}),
      ),
    );
    await pumpEventQueue();
    expect(session.state, isA<AwaitingTool>());

    session.cancel();
    expect(session.state, const ConversationState.cancelled());
    final assistant = session.snapshot.messages.last;
    expect(assistant.status, MessageStatus.interrupted);
    expect(visibleText(assistant), 'checking… ');
    expect(
      assistant.parts.last,
      isA<ToolCallPart>(),
      reason: 'the trailing unmatched toolCall is legal on interrupted',
    );

    // The app's tool finishes late: result-only ignore — no result part, no
    // new leg.
    resolverGate.complete(const ToolResult(content: '3 notes', isError: false));
    await pumpEventQueue();
    expect(
      session.snapshot.messages.last.parts.whereType<ToolResultPart>(),
      isEmpty,
    );
    expect(backend.requests, hasLength(1));
    await session.dispose();
  });
}
