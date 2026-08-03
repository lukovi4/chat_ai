// The durable reply lifecycle (long-running operation): stable `replyId`
// before the first dispatch, detach vs explicit remote cancel, and recovery of
// a reply that is still running remotely. Only the real risks of the durable
// extension — the v1 paths are covered by the existing Core suites.
import 'dart:async';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

/// A fully manual durable transport: every call is observable and every stream
/// is pushed by hand, so detach/cancel races are exact (the durable twin of
/// [ManualBackend]).
class ManualDurableBackend implements DurableChatBackend {
  final List<ChatRequest> requests = [];
  final List<String> startedReplyIds = [];
  final List<String> attachedReplyIds = [];
  final List<String> cancelledReplyIds = [];
  final List<StreamController<BackendEvent>> _controllers = [];
  int cancelledSubscriptions = 0;

  /// Scripted answer of the next [attachReply]; `null` means "proven absent".
  Stream<BackendEvent>? Function(String replyId)? onAttach;

  StreamController<BackendEvent> get current => _controllers.last;

  void emit(BackendEvent event) => current.add(event);

  Stream<BackendEvent> _open() {
    late final StreamController<BackendEvent> controller;
    controller = StreamController<BackendEvent>(
      onCancel: () {
        cancelledSubscriptions++;
      },
    );
    _controllers.add(controller);
    return controller.stream;
  }

  @override
  Stream<BackendEvent> send(ChatRequest request) {
    throw StateError('the durable path must never call send()');
  }

  @override
  Stream<BackendEvent> startReply(String replyId, ChatRequest request) {
    startedReplyIds.add(replyId);
    requests.add(request);
    return _open();
  }

  @override
  Future<Stream<BackendEvent>?> attachReply(String replyId) async {
    attachedReplyIds.add(replyId);
    return onAttach?.call(replyId);
  }

  @override
  Future<void> cancelReply(String replyId) async {
    cancelledReplyIds.add(replyId);
  }
}

/// A fully manual SERVER-MANAGED transport — deliberately a SEPARATE minimal
/// double, never a subclass of [ManualDurableBackend]: the two durable modes
/// are distinct contracts and a double must declare exactly one of them (this
/// one is provably not a [DurableChatBackend], so no `startReply` exists on
/// it at all).
///
/// The server owns the whole logical reply: this session admits it once,
/// observes, re-attaches and cancels it.
class ManualServerManagedBackend implements ServerManagedDurableChatBackend {
  final List<String> admittedReplyIds = [];
  final List<ChatRequest> requests = [];
  final List<Conversation> snapshots = [];
  final List<String> attachedReplyIds = [];
  final List<String> cancelledReplyIds = [];
  final List<StreamController<BackendEvent>> _controllers = [];
  int cancelledSubscriptions = 0;
  int sendCalls = 0;

  /// Scripted answer of the next [attachReply]; `null` means "proven absent".
  Stream<BackendEvent>? Function(String replyId)? onAttach;

  StreamController<BackendEvent> get current => _controllers.last;

  void emit(BackendEvent event) => current.add(event);

  /// A fresh hand-pushed observation stream (also the scriptable answer of
  /// [attachReply]).
  Stream<BackendEvent> open() {
    late final StreamController<BackendEvent> controller;
    controller = StreamController<BackendEvent>(
      onCancel: () {
        cancelledSubscriptions++;
      },
    );
    _controllers.add(controller);
    return controller.stream;
  }

  @override
  Stream<BackendEvent> send(ChatRequest request) {
    sendCalls++;
    throw StateError('the server-managed path must never call send()');
  }

  @override
  Stream<BackendEvent> admitReply(
    String replyId,
    ChatRequest request,
    Conversation snapshot,
  ) {
    admittedReplyIds.add(replyId);
    requests.add(request);
    snapshots.add(snapshot);
    return open();
  }

  @override
  Future<Stream<BackendEvent>?> attachReply(String replyId) async {
    attachedReplyIds.add(replyId);
    return onAttach?.call(replyId);
  }

  @override
  Future<void> cancelReply(String replyId) async {
    cancelledReplyIds.add(replyId);
  }
}

/// A tools profile whose resolver is deliberately absent: legal only because
/// the tool loop belongs to the server.
const BotProfile serverToolProfile = BotProfile(
  id: 'premium',
  systemPrompt: 'be kind',
  tools: [
    Tool(
      name: 'search',
      description: 'd',
      parameters: {
        'type': 'object',
        'properties': <String, Object?>{},
        'required': <String>[],
        'additionalProperties': false,
      },
    ),
  ],
);

Conversation historyWithRunningReply({
  MessageStatus userStatus = MessageStatus.sending,
  List<ContentPart> assistantParts = const [ContentPart.text('partial')],
}) => Conversation(
  messages: [
    userMessage('u-1', 'hi', status: userStatus),
    assistantMessage(
      'a-1',
      '',
      status: MessageStatus.streaming,
      parts: assistantParts,
    ),
  ],
);

void main() {
  group('legacy backend is untouched', () {
    test(
      'a plain ChatBackend keeps send() and the wire-cancel on cancel()',
      () async {
        final backend = ManualBackend();
        final session = makeSession(backend: backend);
        addTearDown(session.dispose);

        await session.send('hi');
        backend.emit(const BackendEvent.accepted());
        backend.emit(const BackendEvent.delta('par'));
        await waitForState(session, (state) => state is Streaming);

        session.cancel();
        await Future<void>.delayed(Duration.zero);

        // Exactly v1: one send, the subscription cancelled = wire-cancel.
        expect(backend.requests, hasLength(1));
        expect(backend.cancelledSubscriptions, 1);
        expect(session.state, isA<Cancelled>());
      },
    );

    test('ChatSession.open over a legacy backend is the constructor', () async {
      final backend = FakeChatBackend()..reply('hello');
      final session = await ChatSession.open(
        backend: backend,
        botProfile: plainProfile,
        history: historyWithRunningReply(),
      );
      addTearDown(session.dispose);

      // The legacy restart normalisation, unchanged.
      expect(session.state, isA<Idle>());
      expect(session.snapshot.messages.first.status, MessageStatus.failed);
      expect(session.snapshot.messages.last.status, MessageStatus.interrupted);
    });
  });

  group('ChatSession.open validates locally before touching the backend', () {
    test('invalid configuration throws before attachReply', () async {
      final backend = FakeDurableChatBackend()..attachReplays();

      await expectLater(
        ChatSession.open(
          backend: backend,
          // Tools without a resolver: the constructor's ArgumentError.
          botProfile: const BotProfile(
            id: 'b',
            systemPrompt: 's',
            tools: [Tool(name: 'search', description: 'd', parameters: {})],
          ),
          history: historyWithRunningReply(),
        ),
        throwsArgumentError,
      );
      expect(backend.attachedReplyIds, isEmpty);
    });

    test('invalid history throws before attachReply', () async {
      final backend = FakeDurableChatBackend()..attachReplays();

      await expectLater(
        ChatSession.open(
          backend: backend,
          botProfile: plainProfile,
          history: Conversation(
            messages: [
              userMessage('u-1', 'hi'),
              // An assistant Message without an attemptKey violates §5.
              Message(
                id: 'a-1',
                role: MessageRole.assistant,
                parts: const [],
                status: MessageStatus.streaming,
                createdAt: DateTime.utc(2026, 7, 10, 9, 1),
              ),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(backend.attachedReplyIds, isEmpty);
    });
  });

  group('reply identity before the first dispatch', () {
    test(
      'the assistant Message (replyId) is checkpointed before startReply',
      () async {
        final backend = FakeDurableChatBackend()..reply('hello');
        final checkpoints = <Conversation>[];
        final startedAtCheckpoint = <int>[];
        final session = makeSession(
          backend: backend,
          checkpoint: (snapshot) async {
            checkpoints.add(snapshot);
            startedAtCheckpoint.add(backend.startedReplyIds.length);
          },
        );
        addTearDown(session.dispose);

        await session.send('hi');
        await waitForState(session, (state) => state is Done);

        // One checkpoint before the billable dispatch, and it already carries the
        // reply identity: an empty `streaming` assistant with this leg's key.
        expect(checkpoints, hasLength(1));
        expect(startedAtCheckpoint, [0]);
        final persisted = checkpoints.single.messages.last;
        expect(persisted.role, MessageRole.assistant);
        expect(persisted.status, MessageStatus.streaming);
        expect(persisted.parts, isEmpty);
        expect(persisted.attemptKey, isNotNull);

        // That id IS the replyId handed to the backend, and the reply kept it.
        expect(backend.startedReplyIds, [persisted.id]);
        expect(session.snapshot.messages.last.id, persisted.id);
        expect(
          persisted.attemptKey,
          capturedRequestsOf(backend).single.idempotencyKey,
        );
      },
    );

    test(
      'the first provider-effective request excludes the early assistant',
      () async {
        final durable = FakeDurableChatBackend()..reply('hello');
        final legacy = FakeChatBackend()..reply('hello');
        final durableSession = makeSession(backend: durable);
        final legacySession = makeSession(backend: legacy);
        addTearDown(durableSession.dispose);
        addTearDown(legacySession.dispose);

        await durableSession.send('hi');
        await legacySession.send('hi');
        await waitForState(durableSession, (state) => state is Done);
        await waitForState(legacySession, (state) => state is Done);

        final durableRequest = capturedRequestsOf(durable).first;
        expect(
          durableRequest.messages.where(
            (message) => message.role == MessageRole.assistant,
          ),
          isEmpty,
        );
        // Byte-for-byte the legacy v1 first leg.
        expect(
          providerEffective(durableRequest),
          providerEffective(capturedRequestsOf(legacy).first),
        );
        // …while the snapshot does hold the early assistant.
        expect(
          durableSession.snapshot.messages.last.role,
          MessageRole.assistant,
        );
      },
    );
  });

  group('detach and explicit remote cancel', () {
    test('dispose() detaches and never calls cancelReply', () async {
      final backend = ManualDurableBackend();
      final session = makeSession(backend: backend);

      await session.send('hi');
      backend.emit(const BackendEvent.accepted());
      backend.emit(const BackendEvent.delta('par'));
      await waitForState(session, (state) => state is Streaming);

      await session.dispose();

      expect(backend.cancelledSubscriptions, 1); // detach
      expect(backend.cancelledReplyIds, isEmpty); // no remote cancel
    });

    test('cancel() calls cancelReply exactly once, then detaches', () async {
      final backend = ManualDurableBackend();
      final session = makeSession(backend: backend);

      await session.send('hi');
      backend.emit(const BackendEvent.accepted());
      backend.emit(const BackendEvent.delta('par'));
      await waitForState(session, (state) => state is Streaming);

      session.cancel();
      session.cancel(); // a second cancel is a no-op
      await Future<void>.delayed(Duration.zero);

      expect(session.state, isA<Cancelled>());
      expect(backend.cancelledReplyIds, [backend.startedReplyIds.single]);
      expect(backend.cancelledSubscriptions, 1);
      // The partial survives the cancel.
      expect(visibleText(session.snapshot.messages.last), 'par');

      await session.dispose();
      expect(backend.cancelledReplyIds, hasLength(1));
    });

    test('cancel before any startReply performs no remote cancel', () async {
      final backend = ManualDurableBackend();
      final gate = Completer<void>();
      final session = makeSession(
        backend: backend,
        checkpoint: (_) => gate.future,
      );
      addTearDown(session.dispose);

      unawaited(session.send('hi'));
      await waitForState(session, (state) => state is Sending);
      session.cancel();
      gate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(session.state, isA<Cancelled>());
      expect(backend.startedReplyIds, isEmpty);
      expect(backend.cancelledReplyIds, isEmpty);
    });

    test('the remote cancel is once per reply, not once per session', () async {
      final backend = ManualDurableBackend();
      final session = makeSession(backend: backend);
      addTearDown(session.dispose);

      for (final text in ['one', 'two']) {
        await session.send(text);
        backend.emit(const BackendEvent.accepted());
        backend.emit(const BackendEvent.delta('par'));
        await waitForState(session, (state) => state is Streaming);
        session.cancel();
        session.cancel(); // a repeated cancel of the same reply adds nothing
        await Future<void>.delayed(Duration.zero);
        expect(session.state, isA<Cancelled>());
      }

      // Two distinct logical replies, each remotely cancelled exactly once:
      // cancelling the first never mutes the cancel of the second.
      expect(backend.startedReplyIds, hasLength(2));
      expect(
        backend.startedReplyIds.first,
        isNot(backend.startedReplyIds.last),
      );
      expect(backend.cancelledReplyIds, backend.startedReplyIds);
    });
  });

  group('recovery through attachReply', () {
    test('an attached reply replays its leg without send/startReply', () async {
      final backend = FakeDurableChatBackend()
        ..attachReplays()
        ..reply('fresh');
      final session = await ChatSession.open(
        backend: backend,
        botProfile: plainProfile,
        history: historyWithRunningReply(),
      );
      addTearDown(session.dispose);

      expect(backend.attachedReplyIds, ['a-1']);
      expect(session.state, isA<Sending>());
      // The persisted in-flight statuses are kept/repaired, not normalised.
      expect(session.snapshot.messages.first.status, MessageStatus.sent);
      expect(session.snapshot.messages.last.status, MessageStatus.streaming);

      await waitForState(session, (state) => state is Done);

      // No new provider call: neither a legacy send nor a durable start.
      expect(backend.startedReplyIds, isEmpty);
      expect(capturedRequestsOf(backend), isEmpty);
      expect(session.snapshot.messages.last.status, MessageStatus.complete);
    });

    test(
      'the replayed leg replaces the partial only at the first content event',
      () async {
        final backend = FakeDurableChatBackend()
          ..attachReplays()
          ..reply('fresh');
        final session = await ChatSession.open(
          backend: backend,
          botProfile: plainProfile,
          history: historyWithRunningReply(),
        );
        addTearDown(session.dispose);

        // Before any event of the replayed leg the partial is untouched.
        expect(visibleText(session.snapshot.messages.last), 'partial');

        await waitForState(session, (state) => state is Done);
        expect(visibleText(session.snapshot.messages.last), 'fresh');
      },
    );

    test(
      'a proven-absent reply falls back to the legacy normalisation',
      () async {
        final backend =
            FakeDurableChatBackend(); // attach not scripted = absent
        final session = await ChatSession.open(
          backend: backend,
          botProfile: plainProfile,
          history: historyWithRunningReply(),
        );
        addTearDown(session.dispose);

        expect(backend.attachedReplyIds, ['a-1']);
        expect(session.state, isA<Idle>());
        expect(session.snapshot.messages.first.status, MessageStatus.failed);
        expect(
          session.snapshot.messages.last.status,
          MessageStatus.interrupted,
        );
        expect(backend.startedReplyIds, isEmpty);
        expect(capturedRequestsOf(backend), isEmpty);
      },
    );

    test(
      'an undetermined attach status propagates without any dispatch',
      () async {
        final backend = FakeDurableChatBackend()..attachFails('status-unknown');

        await expectLater(
          ChatSession.open(
            backend: backend,
            botProfile: plainProfile,
            history: historyWithRunningReply(),
          ),
          throwsA('status-unknown'),
        );
        expect(backend.startedReplyIds, isEmpty);
        expect(capturedRequestsOf(backend), isEmpty);
      },
    );

    test(
      'a retryable outcome of the attached leg is terminal — no new call',
      () async {
        final backend = FakeDurableChatBackend()
          ..attachReplays()
          ..failWith(FailureCause.rate);
        final session = await ChatSession.open(
          backend: backend,
          botProfile: plainProfile,
          history: historyWithRunningReply(),
        );
        addTearDown(session.dispose);

        final state = await waitForState(session, (state) => state is Failed);
        expect((state as Failed).cause, FailureCause.rate);
        // No silent retry, no re-attach, no dispatch — and the partial is kept.
        expect(backend.attachedReplyIds, hasLength(1));
        expect(backend.startedReplyIds, isEmpty);
        expect(capturedRequestsOf(backend), isEmpty);
        expect(
          session.snapshot.messages.last.status,
          MessageStatus.interrupted,
        );
        expect(visibleText(session.snapshot.messages.last), 'partial');
      },
    );
  });

  group('keys of a durable reply', () {
    test('the fresh-key fallback keeps the key on the user Message', () async {
      // A failed last user Message: resend arms the one fresh-key fallback.
      final history = Conversation(
        messages: [
          userMessage(
            'u-1',
            'hi',
            status: MessageStatus.failed,
            attemptKey: 'persisted-key',
          ),
        ],
      );
      final backend = FakeDurableChatBackend()
        ..respondGone410()
        ..failWith(FailureCause.upstream);
      final checkpoints = <Conversation>[];
      final session = makeSession(
        backend: backend,
        history: history,
        checkpoint: (snapshot) async => checkpoints.add(snapshot),
      );
      addTearDown(session.dispose);

      await session.resend('u-1');
      await waitForState(session, (state) => state is Failed);

      final requests = capturedRequestsOf(backend);
      expect(requests, hasLength(2));
      expect(requests.first.idempotencyKey, 'persisted-key');
      final freshKey = requests[1].idempotencyKey;
      expect(freshKey, isNot('persisted-key'));

      // The checkpoint before the re-dispatch persisted the fresh key on BOTH
      // anchors: the early assistant and the user Message.
      final beforeRedispatch = checkpoints[1];
      expect(
        beforeRedispatch.messages
            .where((message) => message.attemptKey == freshKey)
            .map((message) => message.role),
        [MessageRole.user, MessageRole.assistant],
      );

      // The empty technical assistant is gone; the user keeps the fresh key,
      // so the existing resend/recovery path stays usable.
      final messages = session.snapshot.messages;
      expect(messages, hasLength(1));
      expect(messages.single.role, MessageRole.user);
      expect(messages.single.status, MessageStatus.failed);
      expect(messages.single.attemptKey, freshKey);
    });

    test(
      'the next tool leg reuses the replyId with a new checkpointed key',
      () async {
        final backend = FakeDurableChatBackend()
          ..requestTool('search')
          ..reply('done');
        final checkpoints = <Conversation>[];
        final session = makeSession(
          backend: backend,
          botProfile: const BotProfile(
            id: 'premium',
            systemPrompt: 'be kind',
            tools: [
              Tool(
                name: 'search',
                description: 'd',
                parameters: {
                  'type': 'object',
                  'properties': <String, Object?>{},
                  'required': <String>[],
                  'additionalProperties': false,
                },
              ),
            ],
          ),
          onToolCall: (call) async =>
              const ToolResult(content: '3 notes', isError: false),
          checkpoint: (snapshot) async => checkpoints.add(snapshot),
        );
        addTearDown(session.dispose);

        await session.send('hi');
        await waitForState(session, (state) => state is Done);

        final replyId = session.snapshot.messages.last.id;
        // Same logical reply, two billable legs, two distinct keys.
        expect(backend.startedReplyIds, [replyId, replyId]);
        final requests = capturedRequestsOf(backend);
        expect(requests, hasLength(2));
        expect(requests[0].idempotencyKey, isNot(requests[1].idempotencyKey));
        // The second leg's key was checkpointed before its dispatch.
        expect(checkpoints, hasLength(2));
        expect(
          checkpoints[1].messages.last.attemptKey,
          requests[1].idempotencyKey,
        );
      },
    );
  });

  group('server-managed durable reply', () {
    test(
      'one send is ONE admitReply carrying the exact replyId, frozen request '
      'and snapshot',
      () async {
        final backend = ManualServerManagedBackend();
        // Tools without onToolCall: legal ONLY because the loop is the
        // server's — and it makes a client resolver call structurally
        // impossible for this reply.
        final session = makeSession(
          backend: backend,
          botProfile: serverToolProfile,
        );
        addTearDown(session.dispose);

        await session.send('hi');

        // ONE admission for the whole logical reply, and no other dispatch is
        // even reachable: the contract is not a DurableChatBackend (no
        // `startReply` exists on it) and `send` was never called.
        expect(backend.admittedReplyIds, hasLength(1));
        expect(backend.requests, hasLength(1));
        expect(backend.snapshots, hasLength(1));
        expect(backend.sendCalls, 0);
        expect(backend, isNot(isA<DurableChatBackend>()));

        final replyId = backend.admittedReplyIds.single;
        final request = backend.requests.single;
        final admitted = backend.snapshots.single;

        // The admitted snapshot is the COMMITTED, persistence-ready value:
        // this turn's user Message plus the EMPTY `streaming` assistant whose
        // id IS the replyId.
        expect(admitted.messages, hasLength(2));
        final user = admitted.messages.first;
        final assistant = admitted.messages.last;
        expect(user.role, MessageRole.user);
        expect(assistant.role, MessageRole.assistant);
        expect(assistant.id, replyId);
        expect(assistant.status, MessageStatus.streaming);
        expect(assistant.parts, isEmpty);
        expect(session.snapshot.messages.last.id, replyId);

        // The ONE intentional difference from the local snapshot: the anchor
        // user Message is already `sent` in the value the server persists —
        // the status it holds once the admission is committed — while locally
        // it is still `sending`, because `accepted` has not arrived yet.
        final localUser = session.snapshot.messages.first;
        expect(localUser.status, MessageStatus.sending);
        expect(user.status, MessageStatus.sent);
        // …and it IS the same Message, field for field.
        expect(user.id, localUser.id);
        expect(visibleText(user), 'hi');
        expect(visibleText(user), visibleText(localUser));
        expect(user.parts, localUser.parts);
        expect(user.attemptKey, localUser.attemptKey);
        expect(user.role, localUser.role);
        expect(user.createdAt, localUser.createdAt);
        expect(admitted.schemaVersion, session.snapshot.schemaVersion);

        // ONE first-leg attemptKey: the frozen request and both anchors of the
        // admitted snapshot carry the same key…
        expect(request.idempotencyKey, isNotNull);
        expect(user.attemptKey, request.idempotencyKey);
        expect(assistant.attemptKey, request.idempotencyKey);

        // …while the provider-effective request excludes that assistant.
        expect(
          request.messages.where(
            (message) => message.role == MessageRole.assistant,
          ),
          isEmpty,
        );

        // The admitted snapshot is FROZEN: the reply's own deltas and its
        // terminal never leak into the value the server was handed.
        backend.emit(const BackendEvent.accepted());
        backend.emit(const BackendEvent.delta('server did the tools'));
        backend.emit(const BackendEvent.done());
        await waitForState(session, (state) => state is Done);

        expect(backend.admittedReplyIds, hasLength(1));
        expect(admitted.messages.last.parts, isEmpty);
        expect(admitted.messages.last.status, MessageStatus.streaming);
        expect(admitted.messages.first.status, MessageStatus.sent);
        expect(admitted.messages.first.id, localUser.id);
        // The local user Message reached `sent` only through `accepted`.
        expect(session.snapshot.messages.first.status, MessageStatus.sent);
        expect(
          visibleText(session.snapshot.messages.last),
          'server did the tools',
        );
      },
    );

    test(
      'an immediate cancel before the admission dispatches nothing',
      () async {
        final backend = ManualServerManagedBackend();
        final session = makeSession(backend: backend);
        addTearDown(session.dispose);

        // The race the fence guards: `send` is NOT awaited, so the cancel lands
        // between the command's synchronous prefix and the resumption that
        // would dispatch the admission.
        final sendFuture = session.send('hi');
        session.cancel();
        session.cancel(); // a repeated cancel adds nothing
        await sendFuture;
        await Future<void>.delayed(Duration.zero);

        expect(session.state, isA<Cancelled>());
        // The admission never left the client: no Job of this reply exists…
        expect(backend.admittedReplyIds, isEmpty);
        expect(backend.requests, isEmpty);
        expect(backend.snapshots, isEmpty);
        expect(backend.sendCalls, 0);
        // …so there is nothing to cancel remotely either.
        expect(backend.cancelledReplyIds, isEmpty);
        expect(backend.cancelledSubscriptions, 0);
      },
    );

    test('an immediate dispose before the admission creates no Job', () async {
      final backend = ManualServerManagedBackend();
      final session = makeSession(backend: backend);

      // Same race, resolved by dispose: the reply is invalidated before the
      // resumption that would admit it.
      final sendFuture = session.send('hi');
      final disposeFuture = session.dispose();
      await Future.wait([sendFuture, disposeFuture]);
      await Future<void>.delayed(Duration.zero);

      // A disposed session admits nothing: no server-side Job is created after
      // the session was closed…
      expect(backend.admittedReplyIds, isEmpty);
      expect(backend.requests, isEmpty);
      expect(backend.snapshots, isEmpty);
      expect(backend.sendCalls, 0);
      // …and dispose never remote-cancels.
      expect(backend.cancelledReplyIds, isEmpty);
      expect(backend.cancelledSubscriptions, 0);
    });

    test('a non-null checkpoint is a configuration error', () async {
      final backend = ManualServerManagedBackend();
      var checkpoints = 0;
      Future<void> checkpoint(Conversation snapshot) async {
        checkpoints++;
      }

      // The ordinary constructor rejects the pair synchronously…
      expect(
        () => makeSession(backend: backend, checkpoint: checkpoint),
        throwsArgumentError,
      );

      // …and so does ChatSession.open, which must stop BEFORE its one
      // attachReply (scripted here, so a reached attach would be visible).
      backend.onAttach = (_) => backend.open();
      await expectLater(
        ChatSession.open(
          backend: backend,
          botProfile: plainProfile,
          history: historyWithRunningReply(),
          checkpoint: checkpoint,
        ),
        throwsArgumentError,
      );

      expect(checkpoints, 0);
      expect(backend.attachedReplyIds, isEmpty);
      expect(backend.admittedReplyIds, isEmpty);
      expect(backend.sendCalls, 0);
    });

    test(
      'an unexpected toolCall resolves nothing and admits nothing more',
      () async {
        final backend = ManualServerManagedBackend();
        var resolverCalls = 0;
        final session = makeSession(
          backend: backend,
          botProfile: serverToolProfile,
          onToolCall: (call) async {
            resolverCalls++;
            return const ToolResult(content: '3 notes', isError: false);
          },
        );
        addTearDown(session.dispose);

        await session.send('hi');
        backend.emit(const BackendEvent.accepted());
        backend.emit(
          const BackendEvent.toolCall(
            ToolCall(id: 'call_1', name: 'search', args: {}),
          ),
        );
        final state = await waitForState(session, (state) => state is Failed);

        // A backend-contract violation ends the observed reply as one upstream
        // failure: no resolver call, no second admission.
        expect((state as Failed).cause, FailureCause.upstream);
        expect(resolverCalls, 0);
        expect(backend.admittedReplyIds, hasLength(1));
        expect(backend.requests, hasLength(1));
        expect(backend.sendCalls, 0);
      },
    );

    test('a confirmed failure before accepted is one local Failed, never a '
        'second admission', () async {
      final backend = ManualServerManagedBackend();
      final session = makeSession(backend: backend);
      addTearDown(session.dispose);
      final failures = <ConversationState>[];
      session.states.where((state) => state is Failed).listen(failures.add);

      await session.send('hi');
      expect(backend.admittedReplyIds, hasLength(1));

      // The committed snapshot handed over carries the anchor user as `sent`,
      // while locally that Message is still only `sending`.
      final admittedUser = backend.snapshots.single.messages.first;
      expect(admittedUser.role, MessageRole.user);
      expect(admittedUser.status, MessageStatus.sent);
      expect(session.snapshot.messages.first.id, admittedUser.id);
      expect(session.snapshot.messages.first.status, MessageStatus.sending);

      // A PROVEN admission refusal, with a cause that would be silently
      // retried in every other mode.
      backend.emit(const BackendEvent.error(FailureCause.network));
      final state = await waitForState(session, (state) => state is Failed);
      await Future<void>.delayed(Duration.zero);

      expect((state as Failed).cause, FailureCause.network);
      expect(state.phase, FailurePhase.sending);
      expect(failures, hasLength(1));
      // No silent retry, no re-admission, no other dispatch.
      expect(backend.admittedReplyIds, hasLength(1));
      expect(backend.requests, hasLength(1));
      expect(backend.sendCalls, 0);

      // A PROVEN refusal means no Job ran, so the turn is undone: the empty
      // assistant is gone and the anchor user Message is `failed` — the
      // same-key resend path, unchanged.
      final afterFailure = session.snapshot.messages;
      expect(afterFailure, hasLength(1));
      expect(afterFailure.single.role, MessageRole.user);
      // Forming the committed snapshot never promoted the LOCAL Message: only
      // `accepted` does that, and it never arrived.
      expect(afterFailure.single.status, MessageStatus.failed);
      expect(afterFailure.single.id, admittedUser.id);
      // The frozen admission value is untouched by that local failure.
      expect(admittedUser.status, MessageStatus.sent);
      final persistedKey = afterFailure.single.attemptKey;
      final firstReplyId = backend.admittedReplyIds.single;

      // …and that resend reuses the never-spent persisted key while admitting
      // a NEW replyId (a replyId is admitted at most once).
      await session.resend(afterFailure.single.id);

      expect(backend.admittedReplyIds, hasLength(2));
      expect(backend.requests[1].idempotencyKey, persistedKey);
      expect(backend.admittedReplyIds[1], isNot(firstReplyId));
      expect(backend.admittedReplyIds.toSet(), hasLength(2));
      expect(session.snapshot.messages.last.id, backend.admittedReplyIds[1]);
      expect(backend.sendCalls, 0);
    });

    test(
      'a COMMITTED admission that fails before any delta keeps the user sent '
      'and regenerates a NEW logical reply',
      () async {
        final backend = ManualServerManagedBackend();
        final session = makeSession(backend: backend);
        addTearDown(session.dispose);

        await session.send('hi');
        final firstReplyId = backend.admittedReplyIds.single;
        final firstKey = backend.requests.single.idempotencyKey;

        // The admission COMMITS (Messages + Job), then the server-owned reply
        // fails without producing anything visible.
        backend.emit(const BackendEvent.accepted());
        backend.emit(const BackendEvent.error(FailureCause.upstream));
        final failed = await waitForState(session, (state) => state is Failed);

        // The turn provably ran, so it is NOT undone: the user Message keeps
        // the `sent` it earned at `accepted`, the empty assistant is removed
        // and the phase is still `sending` (nothing streamed).
        expect((failed as Failed).phase, FailurePhase.sending);
        final afterFailure = session.snapshot.messages;
        expect(afterFailure, hasLength(1));
        expect(afterFailure.single.role, MessageRole.user);
        expect(afterFailure.single.status, MessageStatus.sent);

        // Explicit regenerate = exactly ONE more admission, of a NEW logical
        // reply: fresh attemptKey, fresh replyId, and the old replyId is never
        // re-admitted (a repeat of it would mean "join the same Job").
        await session.regenerate();

        expect(backend.admittedReplyIds, hasLength(2));
        expect(backend.admittedReplyIds[1], isNot(firstReplyId));
        expect(backend.admittedReplyIds.toSet(), hasLength(2));
        expect(backend.requests[1].idempotencyKey, isNot(firstKey));
        final messages = session.snapshot.messages;
        expect(messages.last.id, backend.admittedReplyIds[1]);
        expect(messages.first.attemptKey, backend.requests[1].idempotencyKey);
        expect(messages.last.attemptKey, backend.requests[1].idempotencyKey);
        expect(backend.sendCalls, 0);
      },
    );

    test(
      'a partial server-managed reply stays interrupted and regenerates a NEW '
      'logical reply',
      () async {
        final backend = ManualServerManagedBackend();
        var resolverCalls = 0;
        final session = makeSession(
          backend: backend,
          botProfile: serverToolProfile,
          onToolCall: (call) async {
            resolverCalls++;
            return const ToolResult(content: '3 notes', isError: false);
          },
        );
        addTearDown(session.dispose);

        await session.send('hi');
        final firstReplyId = backend.admittedReplyIds.single;
        final firstKey = backend.requests.single.idempotencyKey;

        backend.emit(const BackendEvent.accepted());
        backend.emit(const BackendEvent.delta('partial'));
        await waitForState(session, (state) => state is Streaming);
        backend.emit(const BackendEvent.error(FailureCause.upstream));
        final failed = await waitForState(session, (state) => state is Failed);

        // Past the first delta the partial is kept, exactly as in every other
        // mode: the assistant becomes `interrupted`, phase `streaming`.
        expect((failed as Failed).phase, FailurePhase.streaming);
        final interrupted = session.snapshot.messages.last;
        expect(interrupted.id, firstReplyId);
        expect(interrupted.status, MessageStatus.interrupted);
        expect(visibleText(interrupted), 'partial');

        await session.regenerate();

        // The interrupted reply left the active branch, and the regenerate is
        // ONE new admission of a NEW logical reply.
        final messages = session.snapshot.messages;
        expect(
          messages.map((message) => message.id),
          isNot(contains(firstReplyId)),
        );
        expect(messages, hasLength(2));
        expect(messages.first.role, MessageRole.user);
        expect(messages.last.role, MessageRole.assistant);
        expect(messages.last.status, MessageStatus.streaming);
        expect(messages.last.parts, isEmpty);

        // Two admissions, two distinct replyIds, each admitted exactly once…
        expect(backend.admittedReplyIds, hasLength(2));
        expect(backend.admittedReplyIds.toSet(), hasLength(2));
        expect(backend.admittedReplyIds[1], messages.last.id);
        // …under a new attemptKey carried by both anchors.
        expect(backend.requests[1].idempotencyKey, isNot(firstKey));
        expect(messages.first.attemptKey, backend.requests[1].idempotencyKey);
        expect(messages.last.attemptKey, backend.requests[1].idempotencyKey);

        // Nothing else ran: no send, no startReply (the contract has none) and
        // no client resolver.
        expect(backend.sendCalls, 0);
        expect(resolverCalls, 0);
        expect(backend, isNot(isA<DurableChatBackend>()));
      },
    );

    test('an empty user anchor is a full no-op: no admission at all', () async {
      final backend = ManualServerManagedBackend();
      final session = makeSession(
        backend: backend,
        uuid: SequentialUuid(),
        history: Conversation(
          messages: [
            // Storage/UI-only: no provider-effective content, so the
            // server-managed regenerate (which takes the fresh-admission
            // path for an interrupted reply too) never admits anything.
            userMessage('u-empty', '', parts: const []),
            assistantMessage(
              'a-1',
              'partial',
              status: MessageStatus.interrupted,
            ),
          ],
        ),
      );
      addTearDown(session.dispose);
      final before = session.snapshot.toJson();

      await session.regenerate();
      await Future<void>.delayed(Duration.zero);

      expect(backend.admittedReplyIds, isEmpty);
      expect(backend.requests, isEmpty);
      expect(backend.snapshots, isEmpty);
      expect(backend.sendCalls, 0);
      expect(backend.attachedReplyIds, isEmpty);
      expect(session.snapshot.toJson(), before);
      expect(session.state, isA<Idle>());
    });

    test(
      'dispose only detaches; cancel remotely cancels at most once',
      () async {
        final detached = ManualServerManagedBackend();
        final detaching = makeSession(backend: detached);
        await detaching.send('hi');
        detached.emit(const BackendEvent.accepted());
        detached.emit(const BackendEvent.delta('par'));
        await waitForState(detaching, (state) => state is Streaming);

        await detaching.dispose();
        expect(detached.cancelledSubscriptions, 1); // detach
        expect(detached.cancelledReplyIds, isEmpty); // never a remote cancel

        final backend = ManualServerManagedBackend();
        final session = makeSession(backend: backend);
        await session.send('hi');
        backend.emit(const BackendEvent.accepted());
        backend.emit(const BackendEvent.delta('par'));
        await waitForState(session, (state) => state is Streaming);

        session.cancel();
        session.cancel(); // a second cancel is a no-op
        await Future<void>.delayed(Duration.zero);
        expect(session.state, isA<Cancelled>());
        expect(backend.cancelledReplyIds, [backend.admittedReplyIds.single]);

        await session.dispose();
        expect(backend.cancelledReplyIds, hasLength(1));
      },
    );

    test('cancel between admitReply and accepted still cancels once', () async {
      final backend = ManualServerManagedBackend();
      final session = makeSession(backend: backend);
      addTearDown(session.dispose);

      await session.send('hi');
      final replyId = backend.admittedReplyIds.single;
      // The admission has left the client, but nothing came back yet.
      expect(session.state, isA<Sending>());

      session.cancel();
      session.cancel(); // a repeated cancel adds nothing
      await Future<void>.delayed(Duration.zero);

      expect(session.state, isA<Cancelled>());
      expect(backend.cancelledReplyIds, [replyId]);
      expect(backend.admittedReplyIds, hasLength(1));
    });

    test(
      'a reopened reply only attaches — the replay replaces the partial as a '
      'whole and dispatches nothing',
      () async {
        final backend = ManualServerManagedBackend();
        backend.onAttach = (_) => backend.open();
        final session = await ChatSession.open(
          backend: backend,
          botProfile: plainProfile,
          history: historyWithRunningReply(),
        );
        addTearDown(session.dispose);

        expect(backend.attachedReplyIds, ['a-1']);
        // Before the first replayed event the persisted partial is untouched.
        expect(visibleText(session.snapshot.messages.last), 'partial');

        backend.emit(const BackendEvent.delta('the whole reply'));
        await waitForState(session, (state) => state is Streaming);
        expect(visibleText(session.snapshot.messages.last), 'the whole reply');

        backend.emit(const BackendEvent.done());
        await waitForState(session, (state) => state is Done);

        // The replay continued the EXISTING reply — same Message id, no new
        // one — and the successful attach dispatched nothing: no admission, no
        // request, no send (which would have thrown), and attachReply once.
        expect(session.snapshot.messages.last.id, 'a-1');
        expect(session.snapshot.messages.last.status, MessageStatus.complete);
        expect(backend.attachedReplyIds, hasLength(1));
        expect(backend.admittedReplyIds, isEmpty);
        expect(backend.requests, isEmpty);
        expect(backend.sendCalls, 0);
      },
    );
  });
}
