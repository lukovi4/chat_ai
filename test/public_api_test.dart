// Public-API compile test: it imports ONLY the public entry point — no `src/`
// imports — and references every type this foundation increment exports. If a
// public type stops being exported (or an internal one leaks in), this file
// fails to compile. Also pins the export boundary: the testing-only entry
// stays empty for now and is never re-exported from the main barrel.
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 10, 9, 15);

  test('persisted models are public', () {
    final conversation = Conversation(
      messages: [
        Message(
          id: 'u-1',
          role: MessageRole.user,
          parts: [
            const ContentPart.text('hi'),
            ContentPart.image(Uint8List.fromList([1])),
          ],
          status: MessageStatus.sent,
          attemptKey: 'k-1',
          createdAt: createdAt,
        ),
      ],
    );
    expect(conversation.schemaVersion, 1);
    // The five sealed cases are addressable as public types, and both
    // spellings construct them (union constructor + case-class constructor).
    expect(const ContentPart.text('t'), isA<TextPart>());
    expect(ImagePart(Uint8List(0)), isA<ContentPart>());
    expect(const ToolCallPart('c', 'n', {}), isA<ContentPart>());
    expect(const ToolResultPart('c', 'ok', false), isA<ContentPart>());
    expect(ProviderOpaquePart('openai', Uint8List(0)), isA<ContentPart>());
    // JSON is on the public surface (Conversation is the read boundary).
    expect(Conversation.fromJson(conversation.toJson()), conversation);
    // Enums are public with their full catalogues.
    expect(MessageRole.values, hasLength(3));
    expect(MessageStatus.values, hasLength(6));
  });

  test('ephemeral state and failure catalogue are public', () {
    const states = <ConversationState>[
      ConversationState.idle(),
      ConversationState.sending(),
      ConversationState.awaitingTool(ToolCall(id: 'c', name: 'n', args: {})),
      ConversationState.streaming(),
      ConversationState.done(usage: Usage(inputTokens: 1, outputTokens: 2)),
      ConversationState.failed(FailureCause.network, FailurePhase.sending),
      ConversationState.cancelled(),
    ];
    expect(states[0], isA<Idle>());
    expect(states[1], isA<Sending>());
    expect(states[2], isA<AwaitingTool>());
    expect(states[3], isA<Streaming>());
    expect(states[4], isA<Done>());
    expect(states[5], isA<Failed>());
    expect(states[6], isA<Cancelled>());
    expect(FailureCause.values, hasLength(10));
    expect(FailurePhase.values, hasLength(2));
  });

  test('configuration values are public', () {
    const profile = BotProfile(
      id: 'premium',
      systemPrompt: 'be kind',
      tools: [Tool(name: 'searchNotes', description: 'd', parameters: {})],
    );
    expect(profile.tools.single.name, 'searchNotes');
    const ToolCall(id: 'c1', name: 'searchNotes', args: {'q': 'x'});
    const ToolResult(content: '3 notes', isError: false);
    const options = ImageSendOptions();
    expect(options.maxImagesPerMessage, 4);
  });

  test(
    'OnToolCall typedef is public with the exact V1_SPEC §5 signature',
    () async {
      // A function with the exact shape is assignable to the typedef…
      Future<ToolResult> resolver(ToolCall call) async =>
          ToolResult(content: 'ran ${call.name}', isError: false);
      final OnToolCall onToolCall = resolver;
      expect(onToolCall, isA<OnToolCall>());
      expect(onToolCall, isA<Future<ToolResult> Function(ToolCall)>());

      // …and invoking it returns a working Future<ToolResult>.
      final Future<ToolResult> pending = onToolCall(
        const ToolCall(id: 'c1', name: 'searchNotes', args: {'q': 'x'}),
      );
      expect(
        await pending,
        const ToolResult(content: 'ran searchNotes', isError: false),
      );
    },
  );

  test('backend boundary types are public', () {
    final request = ChatRequest(
      botId: 'premium',
      system: 'be kind',
      messages: const [],
      tools: const [],
      idempotencyKey: 'key-1',
    );
    expect(request.wireVersion, 1);
    const events = <BackendEvent>[
      BackendEvent.accepted(),
      BackendEvent.delta('t'),
      BackendEvent.toolCall(ToolCall(id: 'c', name: 'n', args: {})),
      BackendEvent.done(),
      BackendEvent.error(FailureCause.upstream),
      BackendEvent.conflict(),
      BackendEvent.gone(),
    ];
    expect(events[0], isA<Accepted>());
    expect(events[1], isA<Delta>());
    expect(events[2], isA<ToolCallEvent>());
    expect(events[3], isA<DoneEvent>());
    expect(events[4], isA<ErrorEvent>());
    expect(events[5], isA<ConflictEvent>());
    expect(events[6], isA<GoneEvent>());
    expect(
      BackendEvent.providerState(ProviderOpaquePart('openai', Uint8List(0))),
      isA<ProviderStateEvent>(),
    );
    // The production transport is public and assignable to the interface.
    // Constructing it touches no Firebase/network — tokens are pulled per
    // send, which this test never calls — and the URL constructor is the
    // whole public configuration surface (V1_SPEC §8).
    final ChatBackend backend = FirebaseChatBackend(
      'https://example.invalid/chat',
    );
    expect(backend, isA<FirebaseChatBackend>());
  });

  test('the export boundary keeps internals and testing surface out', () {
    final barrel = File('lib/chat_ai.dart').readAsStringSync();
    // No testing-only surface in the production barrel.
    expect(barrel.contains("export 'testing.dart'"), isFalse);
    expect(barrel.contains('src/testing'), isFalse);
    // Internal helpers stay internal.
    expect(barrel.contains('conversation_invariants'), isFalse);
    expect(barrel.contains('utc_date_time_converter'), isFalse);
    // The transport file is exported selectively: the class only — the
    // internal test seam never reaches the public surface.
    expect(barrel.contains('show FirebaseChatBackend'), isTrue);
    expect(barrel.contains('firebaseChatBackendForTesting'), isFalse);

    // The testing entry exists but intentionally exports nothing yet:
    // FakeChatBackend is not part of the foundation increment.
    final testing = File('lib/testing.dart').readAsStringSync();
    expect(testing.contains('export '), isFalse);
  });
}
