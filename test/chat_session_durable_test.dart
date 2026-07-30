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
}
