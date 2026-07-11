// The backend boundary as pure value contracts (V1_SPEC §8): ChatRequest,
// the BackendEvent union, and the ChatBackend interface — no transport, no
// retry logic, no FakeChatBackend (that ships in a later increment).
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal in-test double proving [ChatBackend] is implementable with plain
/// streams. NOT the scriptable `FakeChatBackend` of V1_SPEC §10.
class _ScriptedBackend implements ChatBackend {
  _ScriptedBackend(this.events);

  final List<BackendEvent> events;
  ChatRequest? lastRequest;

  @override
  Stream<BackendEvent> send(ChatRequest request) {
    lastRequest = request;
    return Stream.fromIterable(events);
  }
}

void main() {
  final message = Message(
    id: 'u-1',
    role: MessageRole.user,
    parts: const [ContentPart.text('hi')],
    status: MessageStatus.sent,
    attemptKey: 'k-1',
    createdAt: DateTime.utc(2026, 7, 10, 9, 15),
  );

  group('ChatRequest', () {
    test('wireVersion defaults to 1 (V1_SPEC §6)', () {
      final request = ChatRequest(
        botId: 'premium',
        system: 'be kind',
        messages: [message],
        tools: const [],
        idempotencyKey: 'key-1',
      );
      expect(request.wireVersion, 1);
    });

    test('is a value object: equality and copyWith', () {
      ChatRequest build() => ChatRequest(
        botId: 'premium',
        system: 'be kind',
        messages: [message],
        tools: const [
          Tool(name: 'searchNotes', description: 'd', parameters: {}),
        ],
        idempotencyKey: 'key-1',
      );
      expect(build(), build());
      final fresh = build().copyWith(idempotencyKey: 'key-2');
      expect(fresh.idempotencyKey, 'key-2');
      expect(fresh.botId, 'premium');
      expect(fresh, isNot(build()));
    });
  });

  group('BackendEvent union', () {
    test('all eight cases construct and compare by value', () {
      expect(const BackendEvent.accepted(), const BackendEvent.accepted());
      expect(const BackendEvent.delta('a'), const BackendEvent.delta('a'));
      expect(
        const BackendEvent.delta('a'),
        isNot(const BackendEvent.delta('b')),
      );
      expect(
        BackendEvent.providerState(
          ProviderOpaquePart('openai', Uint8List.fromList([1])),
        ),
        BackendEvent.providerState(
          ProviderOpaquePart('openai', Uint8List.fromList([1])),
        ),
      );
      expect(
        const BackendEvent.toolCall(
          ToolCall(id: 'c1', name: 'n', args: {}),
          usage: Usage(inputTokens: 1, outputTokens: 2),
        ),
        const BackendEvent.toolCall(
          ToolCall(id: 'c1', name: 'n', args: {}),
          usage: Usage(inputTokens: 1, outputTokens: 2),
        ),
      );
      expect(
        const BackendEvent.done(usage: Usage(inputTokens: 1, outputTokens: 2)),
        const BackendEvent.done(usage: Usage(inputTokens: 1, outputTokens: 2)),
      );
      expect(
        const BackendEvent.error(
          FailureCause.rate,
          detail: '429',
          retryAfter: Duration(milliseconds: 1200),
        ),
        const BackendEvent.error(
          FailureCause.rate,
          detail: '429',
          retryAfter: Duration(milliseconds: 1200),
        ),
      );
      expect(const BackendEvent.conflict(), const BackendEvent.conflict());
      expect(const BackendEvent.gone(), const BackendEvent.gone());
    });

    test('optional payloads default to null (usage / detail / retryAfter)', () {
      const done = DoneEvent();
      expect(done.usage, isNull);
      const toolCall = ToolCallEvent(ToolCall(id: 'c1', name: 'n', args: {}));
      expect(toolCall.usage, isNull);
      const error = ErrorEvent(FailureCause.upstream);
      expect(error.detail, isNull);
      expect(error.usage, isNull);
      expect(error.retryAfter, isNull);
    });

    test('an exhaustive switch covers all eight events', () {
      String label(BackendEvent event) => switch (event) {
        Accepted() => 'accepted',
        Delta(:final text) => 'delta:$text',
        ProviderStateEvent(:final part) => 'providerState:${part.provider}',
        ToolCallEvent(:final call) => 'toolCall:${call.id}',
        DoneEvent(:final usage) => 'done:${usage?.outputTokens}',
        ErrorEvent(:final cause, :final retryAfter) =>
          'error:${cause.name}:${retryAfter?.inMilliseconds}',
        ConflictEvent() => 'conflict',
        GoneEvent() => 'gone',
      };

      expect(label(const BackendEvent.accepted()), 'accepted');
      expect(label(const BackendEvent.delta('x')), 'delta:x');
      expect(
        label(
          BackendEvent.providerState(
            ProviderOpaquePart('anthropic', Uint8List(0)),
          ),
        ),
        'providerState:anthropic',
      );
      expect(
        label(
          const BackendEvent.toolCall(ToolCall(id: 'c1', name: 'n', args: {})),
        ),
        'toolCall:c1',
      );
      expect(
        label(
          const BackendEvent.done(
            usage: Usage(inputTokens: 1, outputTokens: 5),
          ),
        ),
        'done:5',
      );
      expect(
        label(
          const BackendEvent.error(
            FailureCause.rate,
            retryAfter: Duration(milliseconds: 1200),
          ),
        ),
        'error:rate:1200',
      );
      expect(label(const BackendEvent.conflict()), 'conflict');
      expect(label(const BackendEvent.gone()), 'gone');
    });
  });

  group('ChatBackend interface', () {
    test('is implementable with a plain event stream — no transport', () async {
      final backend = _ScriptedBackend(const [
        BackendEvent.accepted(),
        BackendEvent.delta('Hel'),
        BackendEvent.delta('lo'),
        BackendEvent.done(usage: Usage(inputTokens: 3, outputTokens: 2)),
      ]);
      final request = ChatRequest(
        botId: 'premium',
        system: 'be kind',
        messages: [message],
        tools: const [],
        idempotencyKey: 'key-1',
      );

      final events = await backend.send(request).toList();

      expect(backend.lastRequest, request);
      expect(events, const [
        BackendEvent.accepted(),
        BackendEvent.delta('Hel'),
        BackendEvent.delta('lo'),
        BackendEvent.done(usage: Usage(inputTokens: 3, outputTokens: 2)),
      ]);
    });

    test(
      'failures ride the stream as events, the stream itself completes',
      () async {
        final backend = _ScriptedBackend(const [
          BackendEvent.error(FailureCause.network, detail: 'socket closed'),
        ]);
        final events = await backend
            .send(
              ChatRequest(
                botId: 'premium',
                system: '',
                messages: const [],
                tools: const [],
                idempotencyKey: 'key-1',
              ),
            )
            .toList(); // toList() would throw if the stream carried an error
        expect(events.single, isA<ErrorEvent>());
      },
    );
  });
}
